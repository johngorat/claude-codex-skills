#!/usr/bin/env bash
# round-report.sh — per-round scoreboard + convergence signals for a debate
# run dir. READ-ONLY over the artifacts review-round.sh already keeps
# (rotation preserves events.rN.jsonl / verdict.rN.json per round precisely
# so this data survives).
#
# Usage: round-report.sh <run_dir>
#
# stdout: a short human table (one row per completed round), then EXACTLY one
# machine-readable line:
#   round-report: rounds=<n> latest_verdict=<APPROVED|REVISE|pending>
#     latest_new=<b>:<M>:<m>:<n> recurring=<k>/<total>
#     tokens_in=<n> tokens_out=<n> model=<slug|unknown> auth=<mode|unknown>
#     trend=<approved|insufficient|converging|flat> drift=<yes|no>
# Exit 0 always when the report was produced; exit 2 on usage/no data.
#
# Mechanical signal definitions (plan AUTH-SCOREBOARD-WATCHDOG, cosmetic
# defaults — the debate SKILL.md owns what to DO about them):
#   weight(r)   = count of blocker+major findings in round r's verdict.
#   approved    — the latest completed verdict is APPROVED.
#   insufficient— fewer than 2 completed REVISE rounds: no slope to judge.
#   converging  — weight strictly decreased on the last transition, or is 0.
#   flat        — weight did not decrease on the LAST TWO transitions.
#   drift=yes   — ≥half of the latest round's findings sit on a (file,line)
#     site already flagged in an EARLIER round: a re-flagged exact site after
#     a claimed fix is the non-convergence smell (review-asymptotes rule),
#     reported separately from the count trend so a gate that keeps finding
#     NEW sites is never mislabeled as drifting.
# Rotation naming (review-round.sh): events.rK/verdict.rK = round K;
# unsuffixed events.jsonl/verdict.json = the latest round (verdict may not
# exist yet while it runs -> latest_verdict=pending).
set -u

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 not found — run env-probe.sh and follow its remedy" >&2
  exit 2
}
[ $# -eq 1 ] || { echo "usage: round-report.sh <run_dir>" >&2; exit 2; }
[ -d "$1" ] || { echo "ERROR: not a run dir: $1" >&2; exit 2; }
# cd + relative paths: a native-Windows python3 cannot read MSYS /tmp/...
# paths, and this script must stay path-dialect-agnostic.
cd "$1" || exit 2

export PYTHONIOENCODING=utf-8
exec python3 - <<'REPORT_PY'
import json, os, re, sys

def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError, UnicodeError):
        return None

def read_line(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line:
                    return line
    except (OSError, UnicodeError):
        pass
    return None

def tokens(events_path):
    """(fresh+cached input, output) summed over turn.completed events."""
    tin = tout = 0
    try:
        with open(events_path, encoding="utf-8") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("type") == "turn.completed":
                    u = e.get("usage", {}) or {}
                    tin += (u.get("input_tokens", 0) or 0) + \
                           (u.get("cached_input_tokens", 0) or 0)
                    tout += u.get("output_tokens", 0) or 0
    except (OSError, UnicodeError):
        pass
    return tin, tout

# ---- collect rounds in rotation order ---------------------------------------
nums = sorted(int(m.group(1)) for fn in os.listdir(".")
              for m in [re.fullmatch(r"events\.r(\d+)\.jsonl", fn)] if m)
rounds = []   # (label, verdict-dict-or-None, events-path)
for k in nums:
    rounds.append((k, read_json("verdict.r%d.json" % k), "events.r%d.jsonl" % k))
if os.path.exists("events.jsonl"):
    rounds.append((len(nums) + 1, read_json("verdict.json"), "events.jsonl"))
if not rounds:
    print("ERROR: no events logs here — not a review-round run dir", file=sys.stderr)
    sys.exit(2)

SEV = ("blocker", "major", "minor", "nit")
def sev_counts(verdict):
    c = dict.fromkeys(SEV, 0)
    for f in (verdict or {}).get("findings", []) or []:
        s = f.get("severity")
        if s in c:
            c[s] += 1
    return c

def sites(verdict):
    return set((f.get("file"), f.get("line"))
               for f in (verdict or {}).get("findings", []) or [])

# ---- table -------------------------------------------------------------------
total_in = total_out = 0
weights = []          # blocker+major per COMPLETED round, in order
prior_sites = set()
recurring = latest_total = 0
latest_counts = dict.fromkeys(SEV, 0)
latest_verdict = "pending"
print("round  verdict   new b/M/m/n  recur  tokens_in  tokens_out")
for k, verdict, events_path in rounds:
    tin, tout = tokens(events_path)
    total_in += tin; total_out += tout
    if verdict is None:
        print("%5d  %-8s  %-11s  %5s  %9d  %10d"
              % (k, "pending", "-", "-", tin, tout))
        continue
    c = sev_counts(verdict)
    s = sites(verdict)
    rec = sum(1 for x in s if x in prior_sites)
    print("%5d  %-8s  %d/%d/%d/%d      %5d  %9d  %10d"
          % (k, verdict.get("verdict", "?"), c["blocker"], c["major"],
             c["minor"], c["nit"], rec, tin, tout))
    weights.append(c["blocker"] + c["major"])
    latest_counts, latest_total, recurring = c, len(s), rec
    latest_verdict = verdict.get("verdict", "unknown")
    prior_sites |= s

# ---- signals -------------------------------------------------------------------
if latest_verdict == "APPROVED":
    trend = "approved"
elif len(weights) < 2:
    trend = "insufficient"
elif len(weights) >= 3 and weights[-1] >= weights[-2] >= weights[-3]:
    trend = "flat"
elif weights[-1] < weights[-2] or weights[-1] == 0:
    trend = "converging"
elif len(weights) == 2:
    trend = "insufficient"   # one non-decreasing transition alone: no slope yet
else:
    trend = "converging"
drift = "yes" if latest_total and recurring * 2 >= latest_total else "no"

model = read_line("model") or "unknown"
auth = read_line("auth") or "unknown"
print("round-report: rounds=%d latest_verdict=%s latest_new=%d:%d:%d:%d "
      "recurring=%d/%d tokens_in=%d tokens_out=%d model=%s auth=%s "
      "trend=%s drift=%s"
      % (len(rounds), latest_verdict, latest_counts["blocker"],
         latest_counts["major"], latest_counts["minor"], latest_counts["nit"],
         recurring, latest_total, total_in, total_out, model, auth,
         trend, drift))
REPORT_PY
