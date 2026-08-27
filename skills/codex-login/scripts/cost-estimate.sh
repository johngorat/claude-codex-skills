#!/usr/bin/env bash
# cost-estimate.sh — pre-launch cost estimate for a review round on the
# API (pay-per-token) channel. Advisory arithmetic, no codex invocation.
#
# Usage: cost-estimate.sh <round.input> <model-slug> [rounds]
#   rounds defaults to 1; pass the remaining round budget for a whole-gate
#   worst case.
#
# stdout contract: EXACTLY one line, one of
#   cost-estimate: model=<slug> rounds=<n> est_in_tokens=<n> est_out_tokens=<n> est_usd=<x.xx> cap_usd=<x.xx|none> cap=<ok|EXCEEDED>
#   cost-estimate: model=<slug> NO-PRICE — seed <prices-file> via /codex-login (line: "<slug> <usd-per-1M-in> <usd-per-1M-out>")
# Exit 0 = estimate printed (cap=ok or NO-PRICE — advisory either way);
# exit 1 = cap EXCEEDED (the caller must stop and ask the USER);
# exit 2 = usage/unreadable input.
#
# Model (measured, AUTH-CHANNEL-findings Stage 0):
#   in_tokens  ≈ bytes(round.input)/4 + 12,000 fixed per-turn overhead
#              (11,699 measured on an empty prompt, rounded up)
#   out_tokens ≈ 25,000 per xhigh round (S031 measured 119K over 5 rounds)
# Estimates are WORST CASE: the cached-input discount (repeat rounds in one
# thread) is deliberately ignored — a guard that under-estimates is worse
# than one that over-estimates.
#
# Price table + cap are MACHINE-LOCAL, USER-MAINTAINED files (prices change;
# they are seeded via /codex-login on explicit confirmation, never shipped):
#   ${CLAUDE_SKILLS_PIN_DIR:-~/.claude/codex-skills-pins}/api-prices.txt
#     one model per line: "<slug> <usd-per-1M-input> <usd-per-1M-output>"
#   ${CLAUDE_SKILLS_PIN_DIR:-~/.claude/codex-skills-pins}/cap-usd.txt
#     one number: the per-gate hard cap; absent file = no cap (cap_usd=none).
set -u

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 not found — run env-probe.sh and follow its remedy" >&2
  exit 2
}
[ $# -ge 2 ] && [ $# -le 3 ] || {
  echo "usage: cost-estimate.sh <round.input> <model-slug> [rounds]" >&2
  exit 2
}
[ -f "$1" ] || { echo "ERROR: round input not found: $1" >&2; exit 2; }

export PYTHONIOENCODING=utf-8
exec python3 - "$1" "$2" "${3:-1}" <<'COST_PY'
import os, re, sys

input_file, slug, rounds_arg = sys.argv[1], sys.argv[2], sys.argv[3]
if not re.fullmatch(r"[0-9]{1,3}", rounds_arg) or int(rounds_arg) < 1:
    print("ERROR: rounds must be a small positive integer, got %r" % rounds_arg,
          file=sys.stderr)
    sys.exit(2)
rounds = int(rounds_arg)

pin_dir = (os.environ.get("CLAUDE_SKILLS_PIN_DIR")
           or os.path.join(os.path.expanduser("~"), ".claude",
                           "codex-skills-pins"))
prices_file = os.path.join(pin_dir, "api-prices.txt")
cap_file = os.path.join(pin_dir, "cap-usd.txt")

OVERHEAD_TOKENS = 12000   # measured 11,699 on an empty prompt, rounded up
OUT_PER_ROUND = 25000     # S031: 119K output over 5 xhigh rounds

def read_prices():
    """{slug: (in_usd_per_1M, out_usd_per_1M)}; unreadable file -> {} (the
    NO-PRICE branch names the remedy — a broken table must not crash)."""
    table = {}
    try:
        with open(prices_file, encoding="utf-8-sig") as f:
            for line in f:
                parts = line.split()
                if len(parts) != 3 or line.lstrip().startswith("#"):
                    continue
                try:
                    table[parts[0]] = (float(parts[1]), float(parts[2]))
                except ValueError:
                    continue
    except (OSError, UnicodeError):
        pass
    return table

def read_cap():
    """float cap or None. A present-but-broken cap is treated as 0.0 —
    a corrupt EXPLICIT cap must fail closed (refuse), never fail open."""
    try:
        with open(cap_file, encoding="utf-8-sig") as f:
            text = f.read().strip()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError):
        return 0.0
    try:
        return float(text)
    except ValueError:
        return 0.0

prices = read_prices()
if slug not in prices:
    print("cost-estimate: model=%s NO-PRICE — seed %s via /codex-login "
          "(line: \"%s <usd-per-1M-in> <usd-per-1M-out>\")"
          % (slug, prices_file, slug))
    sys.exit(0)

in_price, out_price = prices[slug]
in_tokens = (os.path.getsize(input_file) // 4 + OVERHEAD_TOKENS) * rounds
out_tokens = OUT_PER_ROUND * rounds
usd = in_tokens / 1e6 * in_price + out_tokens / 1e6 * out_price
cap = read_cap()
cap_str = "none" if cap is None else "%.2f" % cap
exceeded = cap is not None and usd > cap
print("cost-estimate: model=%s rounds=%d est_in_tokens=%d est_out_tokens=%d "
      "est_usd=%.2f cap_usd=%s cap=%s"
      % (slug, rounds, in_tokens, out_tokens, usd, cap_str,
         "EXCEEDED" if exceeded else "ok"))
sys.exit(1 if exceeded else 0)
COST_PY
