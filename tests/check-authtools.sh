#!/usr/bin/env bash
# Acceptance tests for the auth-channel / scoreboard toolset:
#   auth-status.sh (channel detection), cost-estimate.sh (API cost guard),
#   round-report.sh (scoreboard + convergence signals), and review-round.sh's
#   one-channel-per-run record. Codex is NEVER invoked: auth-status runs
#   against a CODEX_BIN stub; everything else is offline fixtures.
# Bash 3.2 compatible; no GNU-only flags.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
SRC="$ROOT/skills/codex-debate/scripts"

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }

command -v python3 >/dev/null 2>&1 || { printf 'FAIL: python3 missing\n'; exit 1; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export CLAUDE_SKILLS_PIN_DIR="$T/pins"   # hermeticity: never the real pins
mkdir -p "$T/pins"

# ---- 0. per-skill copies byte-identical (the duplication law) -----------------
for s in auth-status.sh cost-estimate.sh; do
  for other in codex-check codex-login; do
    if cmp -s "$SRC/$s" "$ROOT/skills/$other/scripts/$s"; then ok
    else bad "$other copy of $s differs"; fi
  done
done
if cmp -s "$SRC/round-report.sh" "$ROOT/skills/codex-check/scripts/round-report.sh"; then ok
else bad "codex-check copy of round-report.sh differs"; fi

# ---- 1. auth-status: classification via the AUTH_STATUS_FIXTURE seam ----------
# (the seam replaces the status SOURCE — a bash stub binary cannot be exec'd
# by a native-Windows python, and the classifier is the unit under test)
export AUTH_STATUS_FIXTURE="$T/status.txt"

astatus() { # astatus <canned-status-text> -> $out
  printf '%s\n' "$1" > "$T/status.txt"
  out=$(bash "$SRC/auth-status.sh" 2>"$T/stderr"); got=$?
}
# the three wordings measured live on this bench (2026-08-28), plus unknown
astatus "Logged in using an API key - sk-proj-***abcd"
[ "$got" -eq 0 ] && ok || bad "apikey status exit $got"
case $out in "auth-status: mode=apikey env_key="*) ok ;; *) bad "apikey line: '$out'" ;; esac
case $out in *sk-proj*) bad "masked key leaked into the apikey line" ;; *) ok ;; esac
astatus "Logged in using ChatGPT"
case $out in "auth-status: mode=chatgpt env_key="*) ok ;; *) bad "chatgpt line: '$out'" ;; esac
astatus "Not logged in"
case $out in "auth-status: mode=none env_key="*) ok ;; *) bad "none line: '$out'" ;; esac
astatus "Session token refreshed (build 999)"
case $out in "auth-status: mode=unknown env_key="*detail=\"Session\ token*) ok ;;
  *) bad "unknown line lacks verbatim detail: '$out'" ;; esac
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] && ok || bad "auth-status printed more than one line"
# env_key reflects the env var, not the login state
printf 'Not logged in\n' > "$T/status.txt"
out=$(OPENAI_API_KEY="sk-test-x" bash "$SRC/auth-status.sh" 2>/dev/null)
case $out in *"env_key=yes"*) ok ;; *) bad "env_key=yes not reported: '$out'" ;; esac
out=$(env -u OPENAI_API_KEY bash "$SRC/auth-status.sh" 2>/dev/null)
case $out in *"env_key=no"*) ok ;; *) bad "env_key=no not reported: '$out'" ;; esac

# ---- 2. cost-estimate: NO-PRICE, math, cap semantics ---------------------------
IN="$T/round.input"
dd if=/dev/zero of="$IN" bs=1000 count=40 2>/dev/null
[ "$(wc -c < "$IN" | tr -d ' ')" = "40000" ] || { printf 'FAIL: fixture input size\n'; exit 1; }
run_ce() { out=$(bash "$SRC/cost-estimate.sh" "$@" 2>"$T/stderr"); got=$?; }
run_ce "$IN" gpt-x-test
[ "$got" -eq 0 ] && ok || bad "NO-PRICE exit $got"
case $out in "cost-estimate: model=gpt-x-test NO-PRICE"*codex-login*) ok ;; *) bad "NO-PRICE line: '$out'" ;; esac
# 40000 bytes -> 10000 + 12000 overhead = 22000 in; 25000 out
# at 5/30 per 1M: 0.11 + 0.75 = 0.86
printf 'gpt-x-test 5 30\n' > "$T/pins/api-prices.txt"
run_ce "$IN" gpt-x-test
[ "$out" = "cost-estimate: model=gpt-x-test rounds=1 est_in_tokens=22000 est_out_tokens=25000 est_usd=0.86 cap_usd=none cap=ok" ] \
  && ok || bad "estimate line: '$out'"
run_ce "$IN" gpt-x-test 5
case $out in *"rounds=5 est_in_tokens=110000 est_out_tokens=125000 est_usd=4.30"*) ok ;; *) bad "5-round line: '$out'" ;; esac
printf '5.00\n' > "$T/pins/cap-usd.txt"
run_ce "$IN" gpt-x-test 5
[ "$got" -eq 0 ] && ok || bad "under-cap exit $got"
printf '0.50\n' > "$T/pins/cap-usd.txt"
run_ce "$IN" gpt-x-test
[ "$got" -eq 1 ] && ok || bad "over-cap exit $got (wanted 1)"
case $out in *"cap=EXCEEDED"*) ok ;; *) bad "over-cap line: '$out'" ;; esac
# a present-but-broken cap fails CLOSED (treated as 0 -> EXCEEDED)
printf 'not-a-number\n' > "$T/pins/cap-usd.txt"
run_ce "$IN" gpt-x-test
[ "$got" -eq 1 ] && ok || bad "broken cap failed open: exit $got"
rm -f "$T/pins/cap-usd.txt"
run_ce "$IN" gpt-x-test banana
[ "$got" -eq 2 ] && ok || bad "garbage rounds exit $got (wanted 2)"

# ---- 3. round-report: fixtures for every trend class ---------------------------
mk_events() { # mk_events <path> <in> <cached> <out>
  printf '{"type":"turn.completed","usage":{"input_tokens":%d,"cached_input_tokens":%d,"output_tokens":%d}}\n' \
    "$2" "$3" "$4" > "$1"
}
mk_verdict() { # mk_verdict <path> <verdict> <findings-json-array>
  printf '{"verdict":"%s","summary":"s","findings":%s}\n' "$2" "$3" > "$1"
}
F_MAJ='{"file":"a.sh","line":1,"severity":"major","issue":"i","suggestion":null,"confidence":0.9}'
run_rr() { out=$(bash "$SRC/round-report.sh" "$1" 2>"$T/stderr"); got=$?; line=$(printf '%s\n' "$out" | tail -1); }

# approved: weights 2 -> 0, APPROVED final
rd="$T/rr-approved"; mkdir -p "$rd"
mk_events "$rd/events.r1.jsonl" 100000 0 5000
mk_verdict "$rd/verdict.r1.json" REVISE "[$F_MAJ,$F_MAJ]"
mk_events "$rd/events.jsonl" 50000 150000 4000
mk_verdict "$rd/verdict.json" APPROVED "[]"
printf 'gpt-t\n' > "$rd/model"; printf 'chatgpt\n' > "$rd/auth"
run_rr "$rd"
[ "$got" -eq 0 ] && ok || bad "approved fixture exit $got: $(cat "$T/stderr")"
[ "$line" = "round-report: rounds=2 latest_verdict=APPROVED latest_new=0:0:0:0 recurring=0/0 tokens_in=300000 tokens_out=9000 model=gpt-t auth=chatgpt trend=approved drift=no" ] \
  && ok || bad "approved line: '$line'"

# flat: three REVISE rounds, weight 1 each, all-new sites -> flat, drift=no
rd="$T/rr-flat"; mkdir -p "$rd"
i=1
for f in '{"file":"f1","line":1,"severity":"major","issue":"i","suggestion":null,"confidence":1}' \
         '{"file":"f2","line":2,"severity":"major","issue":"i","suggestion":null,"confidence":1}'; do
  mk_events "$rd/events.r$i.jsonl" 1000 0 100
  mk_verdict "$rd/verdict.r$i.json" REVISE "[$f]"
  i=$((i + 1))
done
mk_events "$rd/events.jsonl" 1000 0 100
mk_verdict "$rd/verdict.json" REVISE '[{"file":"f3","line":3,"severity":"major","issue":"i","suggestion":null,"confidence":1}]'
run_rr "$rd"
case $line in *"trend=flat drift=no") ok ;; *) bad "flat line: '$line'" ;; esac

# drifting: latest round re-flags a site from round 1 -> drift=yes
rd="$T/rr-drift"; mkdir -p "$rd"
mk_events "$rd/events.r1.jsonl" 1000 0 100
mk_verdict "$rd/verdict.r1.json" REVISE '[{"file":"same.sh","line":7,"severity":"major","issue":"i","suggestion":null,"confidence":1}]'
mk_events "$rd/events.jsonl" 1000 0 100
mk_verdict "$rd/verdict.json" REVISE '[{"file":"same.sh","line":7,"severity":"major","issue":"again","suggestion":null,"confidence":1}]'
run_rr "$rd"
case $line in *"recurring=1/1"*"drift=yes") ok ;; *) bad "drift line: '$line'" ;; esac

# pending + insufficient: one running round, no verdict yet
rd="$T/rr-pending"; mkdir -p "$rd"
mk_events "$rd/events.jsonl" 500 0 0
run_rr "$rd"
case $line in *"latest_verdict=pending"*"trend=insufficient"*) ok ;; *) bad "pending line: '$line'" ;; esac

# not a run dir -> exit 2
rd="$T/rr-empty"; mkdir -p "$rd"
run_rr "$rd"
[ "$got" -eq 2 ] && ok || bad "empty dir exit $got (wanted 2)"

# ---- 4. review-round: one auth channel per run ---------------------------------
RR="$SRC/review-round.sh"
rr_ref() { # rr_ref <desc> <stderr-substr> [args...]
  desc=$1; want=$2; shift 2
  bash "$RR" "$rd" gpt-a medium "$rd/schema.json" "$@" >/dev/null 2>"$T/stderr"; got=$?
  [ "$got" -eq 2 ] && ok || bad "$desc: exit $got, wanted 2"
  case $(cat "$T/stderr") in *"$want"*) ok ;; *) bad "$desc wording: $(cat "$T/stderr")" ;; esac
  [ ! -f "$rd/pid" ] && ok || bad "$desc still launched codex"
}
rd="$T/rr-auth"; mkdir -p "$rd"
printf 'x\n' > "$rd/round.input"; printf '{}\n' > "$rd/schema.json"; printf 'gpt-a\n' > "$rd/model"
# not logged in -> refuse BEFORE any launch; the launch marker must be RELEASED
# (AUTH_STATUS_FIXTURE is still exported — review-round's auth read follows it)
printf 'Not logged in\n' > "$T/status.txt"
rr_ref "logged-out launch" "not logged in"
[ ! -e "$rd/launched" ] && ok || bad "logged-out refusal kept the launch marker"
# channel switch mid-run -> refuse (record says apikey, status says chatgpt)
printf 'Logged in using ChatGPT\n' > "$T/status.txt"
printf 'apikey\n' > "$rd/auth"
rr_ref "mid-run channel switch" "one channel per run"
# corrupt (empty) channel record -> refuse, never overwritten
: > "$rd/auth"
rr_ref "empty channel record" "never overwritten"
[ ! -s "$rd/auth" ] && ok || bad "empty channel record was overwritten"

printf 'check-authtools: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
