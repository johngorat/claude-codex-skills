#!/usr/bin/env bash
# Acceptance tests for preflight-model.sh (staleness / update awareness):
# ALWAYS exits 0; SILENT when fresh; exactly ONE machine-readable line per
# anomalous state, each class carrying its exact remedy (R11 / P4 / D3).
# Bash 3.2 compatible; no GNU-only flags. Isolated via the CODEX_HOME seam.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# Per-skill copies must be byte-identical (the duplication law).
if cmp -s "$ROOT/skills/codex-debate/scripts/preflight-model.sh" \
          "$ROOT/skills/codex-check/scripts/preflight-model.sh"; then ok
else bad "skill copies of preflight-model.sh differ"; fi

mkdir -p "$T/skill/scripts"
cp "$ROOT/skills/codex-debate/scripts/preflight-model.sh" "$T/skill/scripts/"
P="$T/skill/scripts/preflight-model.sh"
PIN="$T/skill/model.txt"
export CODEX_HOME="$T/codex"
mkdir -p "$CODEX_HOME"

run_pf() { out=$(bash "$P" 2>"$T/perr"); got=$?; }

# ---- 1. map missing: ONE line, class named, remedy present, exit STILL 0 -----
run_pf
[ "$got" -eq 0 ] && ok || bad "exit $got on map-missing (must ALWAYS be 0)"
case $out in preflight-model:*stale=map-missing*"remedy:"*reinstall*) ok ;;
  *) bad "map-missing line malformed: '$out'" ;; esac
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] && ok \
  || bad "anomaly output is not exactly one line"

# ---- 2. healthy (map present, no pin, no standalone): SILENT + 0 -------------
mkdir -p "$CODEX_HOME/skills/.system/openai-docs/references"
cat > "$CODEX_HOME/skills/.system/openai-docs/references/latest-model.md" <<'EOF'
| Model ID | Use for |
| --- | --- |
| `gpt-9.9-p1` | Flagship test tier |
EOF
run_pf
if [ "$got" -eq 0 ] && [ -z "$out" ]; then ok
else bad "healthy machine not silent/zero: exit=$got '$out'"; fi

# ---- 3. pin the map knows: still silent ---------------------------------------
printf 'gpt-9.9-p1\n' > "$PIN"
run_pf
[ -z "$out" ] && ok || bad "known pin broke the silence: '$out'"

# ---- 4. pin the map does NOT know: stale line with the re-pin remedy ----------
printf 'gpt-9.9-retired\n' > "$PIN"
run_pf
[ "$got" -eq 0 ] && ok || bad "exit $got on pin-unknown (must ALWAYS be 0)"
case $out in *stale=*pin-unknown-to-map*--propose*) ok ;;
  *) bad "pin-unknown line malformed: '$out'" ;; esac
rm -f "$PIN"

# ---- 4b. malformed pin: sentinel in the line, structure stays parseable -------
printf 'bad; remedy: arbitrary\n' > "$PIN"
run_pf
case $out in *"pin=<invalid>"*) ok ;; *) bad "malformed pin leaked raw into the line: '$out'" ;; esac
case $out in *"pin=bad"*) bad "raw pin bytes forged the machine-readable fields" ;; *) ok ;; esac
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] && ok \
  || bad "malformed-pin output is not exactly one line"
rm -f "$PIN"

# ---- 4c. codex absent: env-probe's problem — preflight is SILENT, exit 0 ------
NOCODEX=""
oldIFS=$IFS; IFS=:
for d in $PATH; do
  if [ -n "$d" ] && [ ! -x "$d/codex" ]; then NOCODEX="$NOCODEX$d:"; fi
done
IFS=$oldIFS
mkdir -p "$T/nocodex_home"
out=$(CODEX_HOME="$T/nocodex_home" PATH="${NOCODEX%:}" bash "$P" 2>/dev/null); got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ]; then ok
else bad "preflight not silent/zero without codex: exit=$got '$out'"; fi

# ---- 5. standalone channel anomalies -------------------------------------------
# 5a: releases downloaded but NO usable current at all -> update-not-active
mkdir -p "$CODEX_HOME/packages/standalone/releases/0.1.0-testtarget" \
         "$CODEX_HOME/packages/standalone/releases/0.2.0-testtarget"
run_pf
[ "$got" -eq 0 ] && ok || bad "exit $got on missing current (must be 0)"
case $out in *update-not-active*"nothing usable"*) ok ;;
  *) bad "missing-current line malformed: '$out'" ;; esac
# 5b: current points at an OLDER release than the newest downloaded
ln -s "releases/0.1.0-testtarget" "$CODEX_HOME/packages/standalone/current" 2>/dev/null
if [ -L "$CODEX_HOME/packages/standalone/current" ]; then
  run_pf
  [ "$got" -eq 0 ] && ok || bad "exit $got on update-not-active (must be 0)"
  case $out in *update-not-active*"never runs it"*) ok ;;
    *) bad "update-not-active line malformed: '$out'" ;; esac
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] && ok \
    || bad "multi-anomaly output is not exactly one line"
else
  printf 'note: symlinks unavailable here — standalone 5b skipped (3 checks)\n'
  ok; ok; ok
fi

printf '%s\n' "check-preflight: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
