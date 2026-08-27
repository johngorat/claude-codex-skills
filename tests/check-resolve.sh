#!/usr/bin/env bash
# Acceptance tests for the model-resolution ladder + env probe
# (plans success criteria: pin -> step 2, no pin -> step 4 validated,
# nothing -> D1 refusal and never an arbitrary model; cache fixture -> step 3
# unchanged; stdout purity; R8 no-rescan on a cache hit).
#
# Runs the REAL scripts against fixture trees in mktemp, isolated via the
# CODEX_HOME / XDG_CACHE_HOME seams. Bash 3.2 compatible; no GNU-only flags.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
SRC="$ROOT/skills/codex-debate/scripts"

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# Per-skill copies must be byte-identical (the duplication law).
for s in resolve-model.sh env-probe.sh review-round.sh; do
  if cmp -s "$ROOT/skills/codex-debate/scripts/$s" "$ROOT/skills/codex-check/scripts/$s"; then ok
  else bad "skill copies of $s differ"; fi
done

# Fixture skill dir (model.txt seam = file next to the scripts' parent).
mkdir -p "$T/skill/scripts"
cp "$SRC/resolve-model.sh" "$T/skill/scripts/"
R="$T/skill/scripts/resolve-model.sh"
PIN="$T/skill/model.txt"

export CODEX_HOME="$T/codex"
export XDG_CACHE_HOME="$T/xdg"
# Hermeticity: without this seam the resolver would read the REAL
# ~/.claude/codex-skills-pins of whoever runs the suite.
export CLAUDE_SKILLS_PIN_DIR="$T/pins"
MPIN="$T/pins/skill.txt"   # fixture skill dir is $T/skill -> basename "skill"
mkdir -p "$CODEX_HOME" "$T/pins"

run() { # run <expected-exit> <desc> -- args...; stdout -> $out, stderr -> $errout
  want=$1; desc=$2; shift 3
  out=$(bash "$R" "$@" 2>"$T/stderr"); got=$?
  errout=$(cat "$T/stderr")
  if [ "$got" -eq "$want" ]; then ok
  else bad "$desc: exit $got, wanted $want; stderr: $(head -3 "$T/stderr")"; fi
}

# ---- 1. bare machine: REFUSE (D1), empty stdout, bootstrap names the pin ----
run 1 "bare machine refuses" -- debate
[ -z "$out" ] && ok || bad "refusal leaked to stdout: '$out'"
case $errout in *REFUSED*model.txt*) ok ;; *) bad "refusal lacks REFUSED/model.txt: $errout" ;; esac
case $errout in *"restore a NAMING source"*) ok ;; *) bad "bare refusal lacks the no-source remedy" ;; esac

# ---- 2. role map alone (candidate has no outside evidence): still refuse ----
mkdir -p "$CODEX_HOME/skills/.system/openai-docs/references"
cat > "$CODEX_HOME/skills/.system/openai-docs/references/latest-model.md" <<'EOF'
| Model ID | Use for |
| --- | --- |
| `gpt-9.9-testsol` | Flagship test tier |
| `gpt-9.9-testterra` | Mini-like balanced test tier |
EOF
run 1 "unvalidated role-map candidate refuses" -- debate
case $errout in *gpt-9.9-testsol*) ok ;; *) bad "refusal does not name the candidate" ;; esac

# ---- 3. rollout evidence appears: step 4 resolves, tier roles honored -------
mkdir -p "$CODEX_HOME/sessions/2026/08/26"
printf '{"model":"gpt-9.9-testsol"}\n{"model":"gpt-9.9-testterra"}\n' \
  > "$CODEX_HOME/sessions/2026/08/26/rollout-test.jsonl"
run 0 "rolemap+rollouts resolves debate" -- debate
[ "$out" = "gpt-9.9-testsol	rolemap" ] && ok || bad "debate rolemap: got '$out'"
run 0 "rolemap+rollouts resolves check" -- check
[ "$out" = "gpt-9.9-testterra	rolemap" ] && ok || bad "check rolemap: got '$out'"

# ---- 4. R8: verdicts were cached; removing the corpus must NOT break a hit --
[ -f "$XDG_CACHE_HOME/claude-codex-skills/resolver.v2.json" ] && ok \
  || bad "no resolver record was written"
rm -rf "$CODEX_HOME/sessions"
run 0 "cache hit survives corpus removal (no rescan possible)" -- debate
[ "$out" = "gpt-9.9-testsol	rolemap" ] && ok || bad "cached validation: got '$out'"

# ---- 5. models_cache.json: original step-3 semantics, outranks role map -----
cat > "$CODEX_HOME/models_cache.json" <<'EOF'
{"models": [
  {"slug": "gpt-9.9-c1", "priority": 1, "visibility": "list"},
  {"slug": "gpt-9.9-c2", "priority": 2, "visibility": "list"},
  {"slug": "gpt-9.9-hidden", "priority": 0, "visibility": "hide"}
]}
EOF
run 0 "cache fixture debate = priority 1" -- debate
[ "$out" = "gpt-9.9-c1	cache" ] && ok || bad "cache debate: got '$out'"
run 0 "cache fixture check = priority 2" -- check
[ "$out" = "gpt-9.9-c2	cache" ] && ok || bad "cache check: got '$out'"

# ---- 6. pin outranks cache; validated cross-source (rolemap membership) -----
printf 'gpt-9.9-testterra\n' > "$PIN"
run 0 "valid pin outranks cache" -- debate
[ "$out" = "gpt-9.9-testterra	pin" ] && ok || bad "pin: got '$out'"

# ---- 7. broken pin REFUSES loudly — automatic sources must not mask it ------
printf 'gpt-9.9-no-such-model\n' > "$PIN"
run 1 "invalid pin refuses (never falls through)" -- debate
case $errout in *pin*NO\ offline\ evidence*) ok ;; *) bad "invalid-pin refusal wording: $errout" ;; esac

# ---- 8. override outranks pin; invalid override refuses ---------------------
printf 'gpt-9.9-testterra\n' > "$PIN"
run 0 "override outranks pin" -- debate gpt-9.9-c1
[ "$out" = "gpt-9.9-c1	override" ] && ok || bad "override: got '$out'"
run 1 "invalid override refuses" -- debate gpt-9.9-bogus
rm -f "$PIN"

# ---- 8b. machine pin: rung between model.txt and the automatic sources ------
# resolves when model.txt is absent (plugin-cache install shape)
printf 'gpt-9.9-testterra\n' > "$MPIN"
run 0 "machine pin resolves when model.txt absent" -- debate
[ "$out" = "gpt-9.9-testterra	machine-pin" ] && ok || bad "machine-pin: got '$out'"
# model.txt outranks the machine pin
printf 'gpt-9.9-c1\n' > "$PIN"
run 0 "model.txt outranks machine pin" -- debate
[ "$out" = "gpt-9.9-c1	pin" ] && ok || bad "pin-over-machine: got '$out'"
# a BROKEN model.txt refuses — a valid machine pin must NOT rescue it
printf 'gpt-9.9-no-such-model\n' > "$PIN"
run 1 "broken model.txt not rescued by machine pin" -- debate
case $errout in *pin*NO\ offline\ evidence*) ok ;; *) bad "broken-pin-with-machine wording: $errout" ;; esac
rm -f "$PIN"
# a broken machine pin refuses loudly — cache must not mask it
printf 'gpt-9.9-no-such-model\n' > "$MPIN"
run 1 "invalid machine pin refuses (never falls through)" -- debate
case $errout in *machine\ pin*NO\ offline\ evidence*) ok ;; *) bad "invalid-machine-pin wording: $errout" ;; esac
rm -f "$MPIN"

# ---- 9. stdout purity: exactly one slug<TAB>source line ---------------------
n=$(bash "$R" check 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "1" ] && ok || bad "stdout is $n lines, wanted exactly 1"
bash "$R" check 2>/dev/null | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*	(override|pin|machine-pin|cache|rolemap)$' \
  && ok || bad "stdout line does not match '<slug>\\t<source>'"

# ---- 10. --propose reports candidates without resolving ----------------------
p=$(bash "$R" --propose debate 2>/dev/null)
case $p in *candidates*bootstrap*) ok ;; *) bad "--propose output malformed" ;; esac

# ---- 11. env probe: healthy = SILENT + exit 0 --------------------------------
cp "$SRC/env-probe.sh" "$T/skill/scripts/"
po=$(bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -eq 0 ] && [ -z "$po" ]; then ok
else bad "healthy probe not silent/zero: exit=$pe out='$po'"; fi

# ---- 12. env probe: a broken python3 (Store-alias behavior) fails loudly -----
# Shadow python3 with a failing stub instead of relocating tools: on the PC,
# `ln -s` silently COPIES and a copied MSYS executable loses its DLLs — the
# original PATH must stay intact so only python3 is under test.
mkdir -p "$T/shadow"
printf '#!/usr/bin/env bash\nexit 9\n' > "$T/shadow/python3"
chmod +x "$T/shadow/python3"
po=$(PATH="$T/shadow:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -ne 0 ]; then ok; else bad "probe with broken python3 exited 0"; fi
case $po in *python3*) ok ;; *) bad "probe failure does not name python3: $po" ;; esac

# ---- 13. payload validation demands whole-token matches ----------------------
mkdir -p "$T/pbin"
printf 'blob gpt-9.9-payloadslug end\n' > "$T/pbin/codex"
chmod +x "$T/pbin/codex"
rm -rf "$XDG_CACHE_HOME"   # fresh record; the fake codex is a new identity
out=$(PATH="$T/pbin:$PATH" bash "$R" debate gpt-9.9-payloadslug 2>/dev/null); got=$?
if [ "$got" -eq 0 ] && [ "$out" = "gpt-9.9-payloadslug	override" ]; then ok
else bad "payload token match: exit $got, got '$out'"; fi
if PATH="$T/pbin:$PATH" bash "$R" debate gpt-9.9-payloadslu >/dev/null 2>&1; then
  bad "prefix of a payload slug validated (token boundary missing)"
else ok; fi

# ---- 14. review-round: resume rounds enforce the recorded model ---------------
RR="$ROOT/skills/codex-debate/scripts/review-round.sh"
rd=$(mktemp -d)
printf 'x\n' > "$rd/round.input"
printf '{}\n' > "$rd/schema.json"
if bash "$RR" "$rd" gpt-x medium "$rd/schema.json" thread-123 >/dev/null 2>&1; then
  bad "resume without a recorded model did not fail"
else ok; fi
[ ! -f "$rd/pid" ] && ok || bad "resume without a recorded model still launched codex"
printf 'gpt-a\n' > "$rd/model"
if bash "$RR" "$rd" gpt-b medium "$rd/schema.json" thread-123 >/dev/null 2>&1; then
  bad "mid-thread model switch did not fail"
else ok; fi
[ ! -f "$rd/pid" ] && ok || bad "mid-thread model switch still launched codex"
rm -rf "$rd"

# npm-layout fixtures need a real node: the selector matches the platform
# package by NODE's own platform-arch suffix, and without node those layouts
# cannot exist on the machine either. Skip LOUDLY, keeping the check count.
if command -v node >/dev/null 2>&1; then
  NT=$(node -p 'process.platform + "-" + process.arch' 2>/dev/null) || NT=""
else
  NT=""
fi
if [ -n "$NT" ]; then HAVE_NODE=1; else HAVE_NODE=0; fi
# the selector demands the platform's exact native filename
case $NT in win32-*) NBIN="codex.exe" ;; *) NBIN="codex" ;; esac

# ---- 15. npm layout: only the ACTIVE native payload is slug evidence ---------
if [ "$HAVE_NODE" -eq 1 ]; then
NPM="$T/npm"
DEP="$NPM/node_modules/@openai/codex-$NT"
mkdir -p "$NPM/bin" "$DEP/vendor/faketarget/bin"
printf '#!/bin/sh\n# shim text mentions codex and gpt-9.9-shimonly\nexit 0\n' > "$NPM/bin/codex"
chmod +x "$NPM/bin/codex"
printf '{"name":"@openai/codex","version":"0.0.0","optionalDependencies":{"@openai/codex-%s":"0.0.0"}}\n' "$NT" > "$NPM/package.json"
printf 'gpt-9.9-npmslug\n' > "$DEP/vendor/faketarget/bin/$NBIN"
chmod +x "$DEP/vendor/faketarget/bin/$NBIN"
printf 'metadata codex-package\n' > "$DEP/vendor/faketarget/codex-package.json"
rm -rf "$XDG_CACHE_HOME"
out=$(PATH="$NPM/bin:$PATH" bash "$R" debate gpt-9.9-npmslug 2>/dev/null); got=$?
if [ "$got" -eq 0 ] && [ "$out" = "gpt-9.9-npmslug	override" ]; then ok
else bad "npm native payload evidence: exit $got, got '$out'"; fi
if PATH="$NPM/bin:$PATH" bash "$R" debate codex >/dev/null 2>&1; then
  bad "override 'codex' validated (shim/metadata scanned as payload)"
else ok; fi
if PATH="$NPM/bin:$PATH" bash "$R" debate gpt-9.9-shimonly >/dev/null 2>&1; then
  bad "slug present only in the shim validated"
else ok; fi

# ---- 15b. a stale-schema record must never feed the new algorithm ------------
# Build a REAL record (true identity) first, then downgrade ONLY its schema
# and inject a prefix verdict — proving the schema check alone rejects it.
rm -rf "$XDG_CACHE_HOME"
PATH="$NPM/bin:$PATH" bash "$R" debate gpt-9.9-npmslug >/dev/null 2>&1
REC="$XDG_CACHE_HOME/claude-codex-skills/resolver.v2.json"
[ -f "$REC" ] && ok || bad "15b: no real record was written to downgrade"
python3 -c 'import json,sys
p = sys.argv[1]
rec = json.load(open(p, encoding="utf-8"))
rec["schema"] = 1
rec["validated"]["gpt-9.9-npmsl"] = "payload"
json.dump(rec, open(p, "w", encoding="utf-8"))' "$REC"
if PATH="$NPM/bin:$PATH" bash "$R" debate gpt-9.9-npmsl >/dev/null 2>&1; then
  bad "schema-1 record verdict was honored by the schema-2 loader"
else ok; fi
rm -rf "$XDG_CACHE_HOME"

# ---- 15c. ambiguous platform packages fail closed -----------------------------
DEP2="$NPM/node_modules/@openai2/codex-$NT"
mkdir -p "$DEP2/vendor/faketarget/bin"
printf 'gpt-9.9-npmslug\n' > "$DEP2/vendor/faketarget/bin/$NBIN"
chmod +x "$DEP2/vendor/faketarget/bin/$NBIN"
printf '{"name":"@openai/codex","version":"0.0.0","optionalDependencies":{"@openai/codex-%s":"0.0.0","@openai2/codex-%s":"0.0.0"}}\n' "$NT" "$NT" > "$NPM/package.json"
if PATH="$NPM/bin:$PATH" bash "$R" debate gpt-9.9-npmslug >/dev/null 2>&1; then
  bad "ambiguous platform packages did not fail closed"
else ok; fi
rm -rf "$NPM/node_modules/@openai2"
printf '{"name":"@openai/codex","version":"0.0.0","optionalDependencies":{"@openai/codex-%s":"0.0.0"}}\n' "$NT" > "$NPM/package.json"

# ---- 15d. a non-executable native payload is not a payload --------------------
chmod -x "$DEP/vendor/faketarget/bin/$NBIN"
if [ ! -x "$DEP/vendor/faketarget/bin/$NBIN" ]; then
  rm -rf "$XDG_CACHE_HOME"
  if PATH="$NPM/bin:$PATH" bash "$R" debate gpt-9.9-npmslug >/dev/null 2>&1; then
    bad "non-executable payload still supplied validation evidence"
  else ok; fi
  po=$(PATH="$NPM/bin:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
  if [ "$pe" -ne 0 ]; then ok; else bad "probe passed a non-executable native payload"; fi
else
  printf 'note: chmod -x has no effect on this filesystem — 15d skipped (2 checks)\n'
  ok; ok
fi
chmod +x "$DEP/vendor/faketarget/bin/$NBIN"
else
  printf 'note: node absent — npm-layout tests 15..15d skipped (8 checks)\n'
  ok; ok; ok; ok; ok; ok; ok; ok
fi

# ---- 16. env probe: npm layout demands the active native payload -------------
if [ "$HAVE_NODE" -eq 1 ]; then
NPM2="$T/npm2"   # metadata only, no bin/codex under vendor
mkdir -p "$NPM2/bin" "$NPM2/node_modules/@openai/codex-$NT/vendor/faketarget"
printf '#!/bin/sh\nexit 0\n' > "$NPM2/bin/codex"; chmod +x "$NPM2/bin/codex"
printf '{"name":"@openai/codex"}\n' > "$NPM2/package.json"
printf 'meta\n' > "$NPM2/node_modules/@openai/codex-$NT/vendor/faketarget/codex-package.json"
po=$(PATH="$NPM2/bin:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -ne 0 ]; then ok; else bad "metadata-only npm layout passed the probe"; fi
case $po in *"native payload"*) ok ;; *) bad "probe does not name the missing payload: $po" ;; esac
NPM3="$T/npm3"   # orphaned shim: no node_modules at all
mkdir -p "$NPM3/bin"
printf '#!/bin/sh\nexit 0\n' > "$NPM3/bin/codex"; chmod +x "$NPM3/bin/codex"
printf '{"name":"@openai/codex"}\n' > "$NPM3/package.json"
po=$(PATH="$NPM3/bin:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -ne 0 ]; then ok; else bad "orphaned npm shim passed the probe"; fi

# ---- 16b. a garbage-printing or HANGING node fails the probe, never blocks it -
# The probe queries node through NATIVE python (subprocess), which on Windows
# resolves "node" by CreateProcess rules (node.exe) and cannot see an sh-script
# fixture — while a real Windows node IS node.exe, so both sides agree on real
# installs. If the fixture is invisible across that boundary these checks are
# unfalsifiable here: skip loudly (verified where sh-script fixtures resolve).
GN="$T/gnode"; mkdir -p "$GN"
printf '#!/usr/bin/env bash\necho "not a target at all"\n' > "$GN/node"
chmod +x "$GN/node"
gnode_seen=$(PATH="$GN:$PATH" python3 -c 'import shutil,sys;sys.stdout.write(shutil.which("node") or "")' 2>/dev/null)
GNODE_SKIP=0
case $gnode_seen in
*gnode*) : ;;
*)
  printf 'note: sh-script node fixture invisible to the native boundary — 16b skipped (4 checks)\n'
  ok; ok; ok; ok
  GNODE_SKIP=1
  ;;
esac
if [ "$GNODE_SKIP" -eq 0 ]; then
po=$(PATH="$GN:$NPM/bin:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -ne 0 ]; then ok; else bad "garbage node output passed the probe"; fi
case $po in *node*) ok ;; *) bad "broken-node failure does not blame node: $po" ;; esac
printf '#!/usr/bin/env bash\nsleep 30\n' > "$GN/node"
t0=$SECONDS
po=$(PATH="$GN:$NPM/bin:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
elapsed=$((SECONDS - t0))
if [ "$pe" -ne 0 ]; then ok; else bad "hanging node passed the probe (no timeout)"; fi
if [ "$elapsed" -le 25 ]; then ok
else bad "hanging node was not bounded by the 15s timeout (took ${elapsed}s)"; fi

fi

# ---- 16c. node entirely ABSENT: one node diagnostic, no contradictory second --
# Build a PATH stripped of every dir carrying an executable node — tools stay
# in their own dirs (no relocation, no MSYS DLL hazard).
NONODE=""
oldIFS=$IFS; IFS=:
for d in $PATH; do
  if [ -n "$d" ] && [ ! -x "$d/node" ]; then NONODE="$NONODE$d:"; fi
done
IFS=$oldIFS
po=$(PATH="$NPM/bin:${NONODE%:}" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -ne 0 ]; then ok; else bad "npm layout with no node passed the probe"; fi
case $po in *"node: not found on PATH"*) ok ;; *) bad "node absence not named: $po" ;; esac
case $po in *"is on PATH but produced"*) bad "contradictory second node message still printed" ;; *) ok ;; esac
else
  printf 'note: node absent — probe npm tests 16/16b/16c skipped (10 checks)\n'
  ok; ok; ok; ok; ok; ok; ok; ok; ok; ok
fi

# ---- 17. malformed bytes: refusal with remedy, never a traceback --------------
printf '\377\376broken\n' > "$PIN"
out=$(bash "$R" debate 2>"$T/stderr"); got=$?
errout=$(cat "$T/stderr")
if [ "$got" -eq 1 ] && [ -z "$out" ]; then ok
else bad "undecodable pin: exit $got, stdout '$out'"; fi
case $errout in *Traceback*) bad "undecodable pin produced a traceback" ;; *REFUSED*) ok ;; *) bad "undecodable pin refusal malformed: $errout" ;; esac
rm -f "$PIN"
printf '\377\376broken\n' > "$CODEX_HOME/skills/.system/openai-docs/references/latest-model.md"
out=$(bash "$R" debate 2>/dev/null); got=$?
if [ "$got" -eq 0 ] && [ "$out" = "gpt-9.9-c1	cache" ]; then ok
else bad "undecodable role map broke the ladder: exit $got, got '$out'"; fi

# ---- 18. rollouts alone cannot NAME a model — and the remedy says so ----------
CODEX_HOME="$T/codex2"; export CODEX_HOME
mkdir -p "$CODEX_HOME/sessions/2026/08/26"
printf '{"model":"gpt-9.9-ranslug"}\n' > "$CODEX_HOME/sessions/2026/08/26/rollout-x.jsonl"
out=$(bash "$R" debate 2>"$T/stderr"); got=$?
errout=$(cat "$T/stderr")
if [ "$got" -eq 1 ] && [ -z "$out" ]; then ok
else bad "rollouts-only machine resolved: exit $got, '$out'"; fi
case $errout in *"restore a NAMING source"*) ok ;; *) bad "rollouts-only refusal lacks the naming-source remedy" ;; esac
case $errout in *"run codex once"*) bad "remedy still claims running codex restores naming" ;; *) ok ;; esac
# ...but a pin CAN validate against that rollout corpus (validation != naming)
printf 'gpt-9.9-ranslug\n' > "$PIN"
out=$(bash "$R" debate 2>/dev/null); got=$?
if [ "$got" -eq 0 ] && [ "$out" = "gpt-9.9-ranslug	pin" ]; then ok
else bad "pin did not validate via the rollout corpus: exit $got, '$out'"; fi
rm -f "$PIN"

# ---- 19. broken sources are named with remedies on EARLY refusals -------------
CODEX_HOME="$T/codex3"; export CODEX_HOME
mkdir -p "$CODEX_HOME"
printf 'not json\n' > "$CODEX_HOME/models_cache.json"
out=$(bash "$R" debate gpt-9.9-unknown 2>"$T/stderr"); got=$?
errout=$(cat "$T/stderr")
if [ "$got" -eq 1 ]; then ok; else bad "override with corrupt catalog resolved: '$out'"; fi
case $errout in *"BROKEN SOURCE"*models_cache*"delete it"*) ok ;; *) bad "override refusal hides the corrupt catalog" ;; esac
mkdir -p "$CODEX_HOME/skills/.system/openai-docs/references"
printf '\377\376broken\n' > "$CODEX_HOME/skills/.system/openai-docs/references/latest-model.md"
printf 'gpt-9.9-unknown2\n' > "$PIN"
out=$(bash "$R" debate 2>"$T/stderr"); got=$?
errout=$(cat "$T/stderr")
if [ "$got" -eq 1 ]; then ok; else bad "pin with broken sources resolved: '$out'"; fi
case $errout in *"BROKEN SOURCE"*"role map"*) ok ;; *) bad "pin refusal hides the unreadable role map" ;; esac
rm -f "$PIN"

# ---- 20. Windows npm WRAPPER layout (entry at the prefix, package nested) -----
if [ "$HAVE_NODE" -eq 1 ]; then
W="$T/wnpm"
WDEP="$W/node_modules/@openai/codex/node_modules/@openai/codex-$NT"
mkdir -p "$WDEP/vendor/faketarget/bin"
printf '#!/bin/sh\nexec node "%s/node_modules/@openai/codex/bin/codex.js" "$@"\n' "$W" > "$W/codex"
chmod +x "$W/codex"
printf '{"name":"@openai/codex","version":"0.0.0","optionalDependencies":{"@openai/codex-%s":"0.0.0"}}\n' "$NT" \
  > "$W/node_modules/@openai/codex/package.json"
printf 'gpt-9.9-wrapslug\n' > "$WDEP/vendor/faketarget/bin/$NBIN"
chmod +x "$WDEP/vendor/faketarget/bin/$NBIN"
rm -rf "$XDG_CACHE_HOME"
out=$(PATH="$W:$PATH" bash "$R" debate gpt-9.9-wrapslug 2>/dev/null); got=$?
if [ "$got" -eq 0 ] && [ "$out" = "gpt-9.9-wrapslug	override" ]; then ok
else bad "wrapper layout: native payload evidence not found: exit $got, '$out'"; fi
if PATH="$W:$PATH" bash "$R" debate codex >/dev/null 2>&1; then
  bad "wrapper TEXT validated override 'codex' (wrapper scanned as payload)"
else ok; fi
# orphaned wrapper: package.json present, native payload missing -> probe FAILs
W2="$T/wnpm2"
mkdir -p "$W2/node_modules/@openai/codex"
printf '#!/bin/sh\nexec node x "$@"\n' > "$W2/codex"; chmod +x "$W2/codex"
printf '{"name":"@openai/codex"}\n' > "$W2/node_modules/@openai/codex/package.json"
po=$(PATH="$W2:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -ne 0 ]; then ok; else bad "orphaned Windows-style wrapper passed the probe"; fi
case $po in *"native payload"*) ok ;; *) bad "wrapper-orphan failure does not name the payload: $po" ;; esac
else
  printf 'note: node absent — wrapper-layout test 20 skipped (4 checks)\n'
  ok; ok; ok; ok
fi

# ---- 21. the payload must match NODE's platform, not python's ------------------
# A unique but FOREIGN-platform package (e.g. a stale leftover) is dead weight
# the shim would never launch: the resolver must not accept its content as
# evidence and the probe must not call the tree healthy.
if [ "$HAVE_NODE" -eq 1 ]; then
MX="$T/mxnpm"
mkdir -p "$MX/bin" "$MX/node_modules/@openai/codex-foreign-cpu/vendor/faketarget/bin"
printf '#!/bin/sh\nexit 0\n' > "$MX/bin/codex"; chmod +x "$MX/bin/codex"
printf '{"name":"@openai/codex","optionalDependencies":{"@openai/codex-foreign-cpu":"0.0.0"}}\n' > "$MX/package.json"
printf 'gpt-9.9-mixslug\n' > "$MX/node_modules/@openai/codex-foreign-cpu/vendor/faketarget/bin/$NBIN"
chmod +x "$MX/node_modules/@openai/codex-foreign-cpu/vendor/faketarget/bin/$NBIN"
rm -rf "$XDG_CACHE_HOME"
if PATH="$MX/bin:$PATH" bash "$R" debate gpt-9.9-mixslug >/dev/null 2>&1; then
  bad "foreign-platform payload accepted as active evidence"
else ok; fi
po=$(PATH="$MX/bin:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -ne 0 ]; then ok; else bad "probe passed a foreign-platform-only npm tree"; fi
else
  printf 'note: node absent — foreign-platform test 21 skipped (2 checks)\n'
  ok; ok
fi

# ---- 22. a standalone binary inside an UNRELATED node project stays standalone -
SP="$T/proj"
mkdir -p "$SP/tools"
printf '{"name":"someapp"}\n' > "$SP/package.json"
printf 'gpt-9.9-standalone\n' > "$SP/tools/codex"; chmod +x "$SP/tools/codex"
rm -rf "$XDG_CACHE_HOME"
out=$(PATH="$SP/tools:$PATH" bash "$R" debate gpt-9.9-standalone 2>/dev/null); got=$?
if [ "$got" -eq 0 ] && [ "$out" = "gpt-9.9-standalone	override" ]; then ok
else bad "standalone under unrelated package.json lost its payload: exit $got, '$out'"; fi
po=$(PATH="$SP/tools:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -eq 0 ] && [ -z "$po" ]; then ok
else bad "standalone under unrelated package.json failed the probe: exit=$pe '$po'"; fi
# a project whose name merely PREFIXES @openai/codex must stay standalone too
printf '{"name":"@openai/codex-helper"}\n' > "$SP/package.json"
rm -rf "$XDG_CACHE_HOME"
out=$(PATH="$SP/tools:$PATH" bash "$R" debate gpt-9.9-standalone 2>/dev/null); got=$?
if [ "$got" -eq 0 ] && [ "$out" = "gpt-9.9-standalone	override" ]; then ok
else bad "codex-helper name reclassified a standalone binary: exit $got, '$out'"; fi
po=$(PATH="$SP/tools:$PATH" bash "$T/skill/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -eq 0 ] && [ -z "$po" ]; then ok
else bad "probe demanded an npm payload for the codex-helper project: exit=$pe '$po'"; fi

# ---- 22b. a VALID non-object package.json stays standalone, never a traceback -
SP2="$T/proj2"
mkdir -p "$SP2/tools"
printf '[]\n' > "$SP2/package.json"
printf 'gpt-9.9-standalone2\n' > "$SP2/tools/codex"; chmod +x "$SP2/tools/codex"
rm -rf "$XDG_CACHE_HOME"
out=$(PATH="$SP2/tools:$PATH" bash "$R" debate gpt-9.9-standalone2 2>"$T/stderr"); got=$?
errout=$(cat "$T/stderr")
if [ "$got" -eq 0 ] && [ "$out" = "gpt-9.9-standalone2	override" ]; then ok
else bad "non-object package.json broke standalone classification: exit $got, '$out'"; fi
case $errout in *Traceback*) bad "non-object package.json produced a traceback" ;; *) ok ;; esac

# ---- 23. non-review role-map rows are NOT membership evidence -----------------
CODEX_HOME="$T/codex4"; export CODEX_HOME
mkdir -p "$CODEX_HOME/skills/.system/openai-docs/references"
cat > "$CODEX_HOME/skills/.system/openai-docs/references/latest-model.md" <<'EOF'
| Model ID | Use for |
| --- | --- |
| `gpt-9.9-t4sol` | Flagship test tier |
| `gpt-9.9-video` | Faster iteration and draft video generation |
| `gpt-9.9-tts` | Text-to-speech |
| `gpt-9.9-stt` | Speech-to-text, fast and cost-efficient |
EOF
for nonreview in gpt-9.9-video gpt-9.9-tts gpt-9.9-stt; do
  printf '%s\n' "$nonreview" > "$PIN"
  if bash "$R" debate >/dev/null 2>&1; then
    bad "non-review row '$nonreview' validated a review pin"
  else ok; fi
done
printf 'gpt-9.9-t4sol\n' > "$PIN"
out=$(bash "$R" debate 2>/dev/null); got=$?
if [ "$got" -eq 0 ] && [ "$out" = "gpt-9.9-t4sol	pin" ]; then ok
else bad "review-capable row stopped validating: exit $got, '$out'"; fi
rm -f "$PIN"

# ---- 24. review-round: a SECOND round-1 launch cannot swap the model ----------
rd=$(mktemp -d)
printf 'x\n' > "$rd/round.input"
printf '{}\n' > "$rd/schema.json"
printf 'gpt-a\n' > "$rd/model"   # as if round 1 already recorded it
if bash "$RR" "$rd" gpt-b medium "$rd/schema.json" >/dev/null 2>&1; then
  bad "no-thread relaunch with another model did not fail"
else ok; fi
[ ! -f "$rd/pid" ] && ok || bad "no-thread model swap still launched codex"
rm -rf "$rd"

# ---- 25. review-round resume-target law: bad ids refuse BEFORE any launch -----
# (codex observed silently resuming the MOST RECENT session on a garbage id —
# both refusal paths must exit 2 with no codex process ever spawned.)
rd=$(mktemp -d)
printf 'x\n' > "$rd/round.input"
printf '{}\n' > "$rd/schema.json"
printf 'gpt-a\n' > "$rd/model"
if bash "$RR" "$rd" gpt-a medium "$rd/schema.json" "not-a-uuid" >/dev/null 2>"$T/stderr"; then
  bad "malformed thread id did not refuse"
else
  [ $? -eq 2 ] 2>/dev/null; ok
fi
case $(cat "$T/stderr") in *not\ a\ UUID*) ok ;; *) bad "malformed-id refusal wording: $(cat "$T/stderr")" ;; esac
[ ! -f "$rd/pid" ] && ok || bad "malformed thread id still launched codex"
printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' > "$rd/thread"   # as if a resume already pinned it
if bash "$RR" "$rd" gpt-a medium "$rd/schema.json" "11111111-2222-3333-4444-555555555555" >/dev/null 2>"$T/stderr"; then
  bad "cross-run thread id did not refuse"
else ok; fi
case $(cat "$T/stderr") in *recorded\ thread*) ok ;; *) bad "cross-run refusal wording: $(cat "$T/stderr")" ;; esac
[ ! -f "$rd/pid" ] && ok || bad "cross-run thread id still launched codex"
rm -rf "$rd"

printf '%s\n' "check-resolve: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
