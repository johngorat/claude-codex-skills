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
import math, os, re, stat, sys

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

def _usd(text):
    """Parse a price/cap number FAIL-CLOSED: only a finite, non-negative
    float counts. float() alone accepts 'nan' — and `usd > nan` is False,
    which would silently turn a corrupt cap into cap=ok."""
    try:
        v = float(text)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(v) or v < 0:
        return None
    return v

def _read_regular(path):
    """('absent'|'broken', None) or ('ok', text) for a SMALL config file
    that must be a plain regular file — the same law as every other record
    in this family. NEVER blocks: a FIFO (or a symlink to one) would hang a
    plain open() until a writer appears, so the path is lstat-gated first
    and the descriptor is opened non-blocking (no-op flag on Windows, where
    FIFOs cannot occur at these paths) and fstat-verified BEFORE reading —
    the pre-check alone would race a swap."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return "absent", None
    except OSError:
        return "broken", None
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        return "broken", None
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return "broken", None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return "broken", None
        data = os.read(fd, 1 << 16)
    except OSError:
        return "broken", None
    finally:
        os.close(fd)
    try:
        return "ok", data.decode("utf-8-sig")
    except UnicodeError:
        return "broken", None

def read_prices():
    """{slug: (in_usd_per_1M, out_usd_per_1M)}; a missing/broken table or an
    invalid entry -> the slug lands on the NO-PRICE branch and its remedy
    (a broken table must never invent an estimate — and never block)."""
    status, text = _read_regular(prices_file)
    table = {}
    if status != "ok":
        return table
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 3 or line.lstrip().startswith("#"):
            continue
        pin, pout = _usd(parts[1]), _usd(parts[2])
        if pin is None or pout is None:
            continue
        table[parts[0]] = (pin, pout)
    return table

def read_cap():
    """float cap or None (no cap). EVERY present-but-broken shape fails
    closed as 0.0 (=> EXCEEDED): unparseable text, non-finite or negative
    values, unreadable files, dangling or ANY symlink, and non-regular
    files (FIFO included — see _read_regular; an explicit cap must never
    be silently ignored, and a cap check must never hang a gate)."""
    status, text = _read_regular(cap_file)
    if status == "absent":
        return None
    if status != "ok":
        return 0.0
    v = _usd(text.strip())
    return 0.0 if v is None else v

prices = read_prices()
if slug not in prices:
    print("cost-estimate: model=%s NO-PRICE — seed %s via /codex-login "
          "(line: \"%s <usd-per-1M-in> <usd-per-1M-out>\")"
          % (slug, prices_file, slug))
    sys.exit(0)

in_price, out_price = prices[slug]
# ceiling division: a worst-case estimate never rounds DOWN past a cap
in_tokens = ((os.path.getsize(input_file) + 3) // 4 + OVERHEAD_TOKENS) * rounds
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
