#!/usr/bin/env bash
# Acceptance tests for install.sh (Stage-3 success criteria): fresh copy
# install with NO privileges; real-link validation; upstream deletions
# removed on refresh; a staged-verification failure rolls back cleanly;
# model.txt survives every refresh; staleness/corruption caught by --verify
# AND by env-probe at entry; moved source fails closed; mode-120000 text
# placeholders are refused. Every case uses a fresh mktemp dest, so an
# already-installed tree can never satisfy a check by accident.
# Bash 3.2 compatible; no GNU-only flags.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# Fixture SOURCE = a private copy of the real tree (tests mutate it freely;
# the real checkout is never touched).
SRCC="$T/srccopy"
mkdir -p "$SRCC/skills"
cp "$ROOT/install.sh" "$SRCC/"
cp -R "$ROOT/skills/codex-check" "$SRCC/skills/codex-check"
# machine-local state must not leak into the fixture: a real checkout may
# carry a model.txt pin (gitignored), and tests 30/45 assume its absence
rm -f "$SRCC/skills/codex-check/model.txt"
D="$T/dest"
export XDG_STATE_HOME="$T/state"
# real link capability of THIS filesystem (some later tests must not key off
# the mutable state of earlier ones)
ln -s "$T" "$T/.linkprobe" 2>/dev/null
if [ -L "$T/.linkprobe" ]; then LINKS_OK=1; else LINKS_OK=0; fi
rm -f "$T/.linkprobe"

# ---- 1. fresh COPY install: no privileges needed, record written --------------
out=$(bash "$SRCC/install.sh" --dest "$D" --mode copy codex-check 2>&1); got=$?
[ "$got" -eq 0 ] && ok || bad "fresh copy install failed: $out"
[ -f "$D/codex-check/SKILL.md" ] && ok || bad "SKILL.md not installed"
cmp -s "$D/codex-check/scripts/resolve-model.sh" \
       "$SRCC/skills/codex-check/scripts/resolve-model.sh" \
  && ok || bad "installed bytes differ from the source"
if ls "$T/state/claude-codex-skills"/install.codex-check.*.v1.json >/dev/null 2>&1; then ok
else bad "no installation record was written"; fi
[ -x "$D/codex-check/scripts/env-probe.sh" ] && ok || bad "exec bit lost in copy"

# ---- 2. --verify on a fresh install: silent, exit 0 ----------------------------
vo=$(bash "$SRCC/install.sh" --verify codex-check 2>&1); ve=$?
if [ "$ve" -eq 0 ] && [ -z "$vo" ]; then ok
else bad "fresh verify not silent/zero: exit=$ve '$vo'"; fi

# ---- 3. env-probe at entry on a fresh install: silent ---------------------------
po=$(bash "$D/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
if [ "$pe" -eq 0 ] && [ -z "$po" ]; then ok
else bad "probe on a fresh install not silent/zero: exit=$pe '$po'"; fi

# ---- 4. STALENESS: the source moves on -> verify AND probe fail with remedy -----
printf '# upstream change\n' >> "$SRCC/skills/codex-check/SKILL.md"
bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>"$T/e"; ve=$?
[ "$ve" -ne 0 ] && ok || bad "stale copy passed --verify"
grep -q "stale" "$T/e" && ok || bad "staleness not named by --verify"
po=$(bash "$D/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
[ "$pe" -ne 0 ] && ok || bad "probe did not block a stale install"
case $po in *STALE*--refresh*) ok ;; *) bad "probe staleness message: $po" ;; esac

# ---- 5. --refresh: updates, removes upstream-deleted files, keeps model.txt -----
printf 'gpt-9.9-keepme\n' > "$D/codex-check/model.txt"
rm "$SRCC/skills/codex-check/review-schema.json"
bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1; ge=$?
[ "$ge" -eq 0 ] && ok || bad "refresh failed"
grep -q "upstream change" "$D/codex-check/SKILL.md" && ok \
  || bad "refresh did not deliver the upstream change"
[ ! -e "$D/codex-check/review-schema.json" ] && ok \
  || bad "a file deleted upstream survived the refresh"
[ "$(cat "$D/codex-check/model.txt")" = "gpt-9.9-keepme" ] && ok \
  || bad "model.txt did not survive the refresh"
bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>&1 && ok \
  || bad "verify after refresh failed"

# ---- 6. CORRUPTION of the installed copy is detected -----------------------------
printf 'x' >> "$D/codex-check/scripts/env-probe.sh"
bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>"$T/e"; ve=$?
[ "$ve" -ne 0 ] && ok || bad "corrupted install passed --verify"
grep -q "corrupt" "$T/e" && ok || bad "corruption not named"
bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1 && ok \
  || bad "refresh after corruption failed"

# ---- 7. a staged-verification failure ROLLS BACK cleanly -------------------------
printf '# second change\n' >> "$SRCC/skills/codex-check/SKILL.md"
CLAUDE_SKILLS_INSTALL_TEST_FAIL=stage-verify \
  bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1; ge=$?
[ "$ge" -ne 0 ] && ok || bad "injected staging failure did not fail"
if grep -q "second change" "$D/codex-check/SKILL.md"; then
  bad "half-installed state after a failed staging"
else ok; fi
grep -q "upstream change" "$D/codex-check/SKILL.md" && ok \
  || bad "rollback lost the previous installation"
[ "$(cat "$D/codex-check/model.txt")" = "gpt-9.9-keepme" ] && ok \
  || bad "rollback lost model.txt"
if [ -n "$(find "$D" -maxdepth 1 -name '.stage-*' 2>/dev/null)" ]; then
  bad "staging residue left behind"
else ok; fi
bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1 || true  # converge

# ---- 8. recorded source moved or disappeared -> fail closed ----------------------
mv "$SRCC" "$T/srcmoved"
bash "$T/srcmoved/install.sh" --verify codex-check >/dev/null 2>"$T/e"; ve=$?
[ "$ve" -ne 0 ] && ok || bad "moved source passed --verify"
grep -q "moved or disappeared" "$T/e" && ok || bad "moved source not named"
mv "$T/srcmoved" "$SRCC"

# ---- 9. symlink mode: a REAL link validated through the consumer, or refusal -----
SL="$T/sl"
if bash "$SRCC/install.sh" --dest "$SL" --mode symlink codex-check >/dev/null 2>"$T/e"; then
  [ -L "$SL/codex-check" ] && ok || bad "symlink mode produced a non-link"
  cmp -s "$SL/codex-check/SKILL.md" "$SRCC/skills/codex-check/SKILL.md" \
    && ok || bad "content through the link differs from the source"
else
  grep -q "copy" "$T/e" && ok || bad "symlink refusal lacks the copy remedy"
  ok   # count parity with the link branch
fi

# ---- 10. a mode-120000 TEXT PLACEHOLDER is refused mechanically ------------------
G="$T/gitfix"
git init -q "$G"
mkdir -p "$G/skills/s"
printf 'hi\n' > "$G/skills/s/SKILL.md"
printf 'SKILL.md' > "$G/skills/s/alias"
blob=$(printf 'SKILL.md' | git -C "$G" hash-object -w --stdin)
git -C "$G" update-index --add --cacheinfo "120000,$blob,skills/s/alias"
git -C "$G" update-index --add skills/s/SKILL.md 2>/dev/null || true
cp "$ROOT/install.sh" "$G/"
out=$(bash "$G/install.sh" --dest "$T/d2" --mode copy s 2>&1); ge=$?
[ "$ge" -ne 0 ] && ok || bad "a text-placeholder tracked symlink was installed"
case $out in *PLACEHOLDER*) ok ;; *) bad "placeholder refusal not named: $out" ;; esac

# ---- 11. multiple destinations keep SEPARATE records ------------------------------
D3="$T/dest3"
bash "$SRCC/install.sh" --dest "$D3" --mode copy codex-check >/dev/null 2>&1 \
  && ok || bad "second-destination install failed"
n=$(ls "$T/state/claude-codex-skills" | grep -c '^install\.codex-check\.')
[ "$n" -ge 2 ] && ok || bad "second destination overwrote the first record ($n)"
printf '# third change\n' >> "$SRCC/skills/codex-check/SKILL.md"
bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>"$T/e"; ve=$?
[ "$ve" -ne 0 ] && ok || bad "stale multi-destination install passed --verify"
c=$(grep -c "stale copy" "$T/e" || true)
[ "$c" -ge 2 ] && ok || bad "only $c of 2 stale destinations were reported"
bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1 \
  && ok || bad "multi-destination refresh failed"
bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>&1 \
  && ok || bad "verify after multi-destination refresh failed"

# ---- 12. a DANGLING/moved source fails closed at verify AND at probe entry --------
mv "$SRCC" "$T/srcmoved"
if bash "$T/srcmoved/install.sh" --verify codex-check >/dev/null 2>"$T/e"; then
  bad "installs with a moved source passed --verify"
else ok; fi
grep -q "moved or disappeared" "$T/e" && ok || bad "moved source not named"
# the probe must catch it too — run it from the COPY install, whose script
# still exists while the source is gone
po=$(bash "$D/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
[ "$pe" -ne 0 ] && ok || bad "probe passed an install whose source is gone"
case $po in *"moved or disappeared"*) ok ;; *) bad "probe does not name the moved source: $po" ;; esac
mv "$T/srcmoved" "$SRCC"

# ---- 13. symlink -> copy mode switch keeps the pin ---------------------------------
if [ -L "$SL/codex-check" ]; then
  printf 'gpt-9.9-pinned\n' > "$SRCC/skills/codex-check/model.txt"
  bash "$SRCC/install.sh" --dest "$SL" --mode copy codex-check >/dev/null 2>&1 \
    && ok || bad "symlink->copy switch failed"
  [ ! -L "$SL/codex-check" ] && ok || bad "destination is still a link after the switch"
  [ "$(cat "$SL/codex-check/model.txt" 2>/dev/null)" = "gpt-9.9-pinned" ] && ok \
    || bad "the pin was lost on the symlink->copy switch"
  rm -f "$SRCC/skills/codex-check/model.txt"
else
  printf 'note: no symlinks here — test 13 skipped (3 checks)\n'
  ok; ok; ok
fi

# ---- 14. path traversal in a skill operand is refused ------------------------------
if bash "$SRCC/install.sh" --dest "$T/d4" --mode copy ../tests >/dev/null 2>&1; then
  bad "a traversal operand ('../tests') was accepted"
else ok; fi

# ---- 15. git failing INSIDE a checkout fails closed (no placeholder can ship) ------
mkdir -p "$T/badgit"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/badgit/git"
chmod +x "$T/badgit/git"
out=$(PATH="$T/badgit:$PATH" bash "$G/install.sh" --dest "$T/d5" --mode copy s 2>&1); ge=$?
[ "$ge" -ne 0 ] && ok || bad "a checkout with broken git installed anyway"
case $out in *remedy*) ok ;; *) bad "broken-git failure lacks a remedy: $out" ;; esac

# ---- 16. an internal DIRECTORY symlink is refused in copy mode ---------------------
ln -s "$T" "$SRCC/skills/codex-check/linkdir" 2>/dev/null
if [ -L "$SRCC/skills/codex-check/linkdir" ]; then
  if bash "$SRCC/install.sh" --dest "$T/d6" --mode copy codex-check >/dev/null 2>"$T/e"; then
    bad "a directory symlink in the payload was installed"
  else ok; fi
  grep -q "symlink in payload" "$T/e" && ok || bad "directory symlink not named"
  rm "$SRCC/skills/codex-check/linkdir"
else
  # MSYS ln -s without symlink privilege leaves a real (empty) DIRECTORY —
  # inside the source payload it would mutate the identity and fail every
  # later verify of earlier installs as 'stale copy'
  rm -rf "$SRCC/skills/codex-check/linkdir"
  printf 'note: no symlinks here — test 16 skipped (2 checks)\n'
  ok; ok
fi

# ---- 17. the probe record check fails CLOSED on an unreadable state dir ------------
chmod 000 "$T/state/claude-codex-skills" 2>/dev/null
if [ ! -r "$T/state/claude-codex-skills" ]; then
  po=$(bash "$D/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
  chmod 755 "$T/state/claude-codex-skills"
  [ "$pe" -ne 0 ] && ok || bad "an unreadable state dir passed the probe (fail-open)"
  case $po in *install*) ok ;; *) bad "state-dir failure not named: $po" ;; esac
else
  chmod 755 "$T/state/claude-codex-skills" 2>/dev/null
  printf 'note: chmod 000 has no effect here — test 17 skipped (2 checks)\n'
  ok; ok
fi

# ---- 18. AUTO mode picks a working mode and the result is valid --------------------
DA="$T/desta"
bash "$SRCC/install.sh" --dest "$DA" codex-check >/dev/null 2>&1 && ok \
  || bad "auto-mode install failed"
if [ -L "$DA/codex-check" ]; then
  cmp -s "$DA/codex-check/SKILL.md" "$SRCC/skills/codex-check/SKILL.md" \
    && ok || bad "auto picked symlink but content differs through the link"
else
  cmp -s "$DA/codex-check/SKILL.md" "$SRCC/skills/codex-check/SKILL.md" \
    && ok || bad "auto picked copy but bytes differ"
fi
bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>&1 && ok \
  || bad "verify after auto install failed"

# ---- 19. a failure AFTER activation (record commit) still restores the backup ------
# Isolated state + single destination: with shared records the injected
# failure could fire at a DIFFERENT destination first and every assertion
# here would pass vacuously.
D19="$T/dest19"
S19="$T/state19"
XDG_STATE_HOME="$S19" bash "$SRCC/install.sh" --dest "$D19" --mode copy codex-check >/dev/null 2>&1 \
  && ok || bad "isolated install for the rollback test failed"
printf 'gpt-9.9-keep19\n' > "$D19/codex-check/model.txt"
printf '# fourth change\n' >> "$SRCC/skills/codex-check/SKILL.md"
XDG_STATE_HOME="$S19" CLAUDE_SKILLS_INSTALL_TEST_FAIL=record-commit \
  bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1; ge=$?
[ "$ge" -ne 0 ] && ok || bad "injected record-commit failure did not fail"
if grep -q "fourth change" "$D19/codex-check/SKILL.md"; then
  bad "post-activation failure left the NEW tree active"
else ok; fi
[ "$(cat "$D19/codex-check/model.txt")" = "gpt-9.9-keep19" ] && ok \
  || bad "post-activation rollback lost model.txt"
if [ -n "$(find "$D19" -maxdepth 1 \( -name '.stage-*' -o -name '.link-*' -o -name '.old-*' \) 2>/dev/null)" ]; then
  bad "stage/link/old residue left after post-activation rollback"
else ok; fi
find "$D19" -maxdepth 1 -name '.failed-*' -exec rm -rf {} + 2>/dev/null
XDG_STATE_HOME="$S19" bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1 \
  && ok || bad "converging refresh after the rollback test failed"

# ---- 20. an unscannable source subtree must not install as complete ----------------
chmod 000 "$SRCC/skills/codex-check/scripts" 2>/dev/null
if [ ! -r "$SRCC/skills/codex-check/scripts" ]; then
  if bash "$SRCC/install.sh" --dest "$T/d7" --mode copy codex-check >/dev/null 2>"$T/e"; then
    bad "an unscannable source subtree installed as complete"
  else ok; fi
  grep -q "cannot scan" "$T/e" && ok || bad "unscannable subtree not named"
  chmod 755 "$SRCC/skills/codex-check/scripts"
else
  chmod 755 "$SRCC/skills/codex-check/scripts" 2>/dev/null
  printf 'note: chmod 000 has no effect here — test 20 skipped (2 checks)\n'
  ok; ok
fi

# ---- 21. a malformed record is a NAMED failure, never silent absence ---------------
recfile=$(ls "$T/state/claude-codex-skills"/install.codex-check.*.v1.json | head -1)
cp "$recfile" "$T/recbak"
printf '{"schema":1,"truncated' > "$recfile"
if bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>"$T/e"; then
  bad "a malformed record passed --verify silently"
else ok; fi
grep -q "record" "$T/e" && ok || bad "malformed record not named: $(cat "$T/e")"
cp "$T/recbak" "$recfile"

# ---- 22. no-operand verify covers a skill DELETED upstream -------------------------
mkdir -p "$SRCC/skills/mini"
printf 'mini skill\n' > "$SRCC/skills/mini/SKILL.md"
bash "$SRCC/install.sh" --dest "$D" --mode copy mini >/dev/null 2>&1 && ok \
  || bad "mini skill install failed"
rm -rf "$SRCC/skills/mini"
if bash "$SRCC/install.sh" --verify >/dev/null 2>"$T/e"; then
  bad "no-operand verify missed a skill deleted upstream"
else ok; fi
grep -q "mini" "$T/e" && ok || bad "the deleted skill is not named"
rm -rf "$D/mini"; rm -f "$T/state/claude-codex-skills"/install.mini.*.json

# ---- 23. a pin CONFLICT on a mode switch refuses instead of choosing ---------------
if [ -L "$SL/codex-check" ] || bash "$SRCC/install.sh" --dest "$T/slprobe" --mode symlink codex-check >/dev/null 2>&1; then
  DP="$T/destpin"
  bash "$SRCC/install.sh" --dest "$DP" --mode copy codex-check >/dev/null 2>&1
  printf 'gpt-9.9-pinA\n' > "$DP/codex-check/model.txt"
  printf 'gpt-9.9-pinB\n' > "$SRCC/skills/codex-check/model.txt"
  if bash "$SRCC/install.sh" --dest "$DP" --mode symlink codex-check >/dev/null 2>"$T/e"; then
    bad "conflicting pins were silently reconciled on a mode switch"
  else ok; fi
  grep -q "DIFFER" "$T/e" && ok || bad "pin conflict not named"
  # the refusal happens BEFORE activation: the current install must remain
  # ACTIVE at dest — not quarantined, not deleted, pin intact
  if [ -d "$DP/codex-check" ] && [ ! -L "$DP/codex-check" ]; then ok
  else bad "pin conflict displaced the existing installation"; fi
  [ "$(cat "$DP/codex-check/model.txt" 2>/dev/null)" = "gpt-9.9-pinA" ] && ok \
    || bad "pin conflict lost the destination pin"
  if [ -n "$(find "$DP" -maxdepth 1 -name '.failed-*' 2>/dev/null)" ]; then
    bad "pin conflict left quarantine residue"
  else ok; fi
  rm -f "$SRCC/skills/codex-check/model.txt"
else
  printf 'note: no symlinks here — test 23 skipped (5 checks)\n'
  ok; ok; ok; ok; ok
fi

# ---- 24. a symlink ADDED to an installed copy reads as corruption ------------------
if ln -s /tmp "$D19/codex-check/badlink" 2>/dev/null && [ -L "$D19/codex-check/badlink" ]; then
  if XDG_STATE_HOME="$S19" bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>"$T/e"; then
    bad "an added symlink in the installed copy passed --verify"
  else ok; fi
  grep -q "corrupt" "$T/e" && ok || bad "added-symlink corruption not named"
  po=$(XDG_STATE_HOME="$S19" bash "$D19/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
  [ "$pe" -ne 0 ] && ok || bad "probe passed an installed copy with an added symlink"
  case $po in *"differs from its record"*) ok ;; *) bad "probe does not name the drift: $po" ;; esac
  rm -f "$D19/codex-check/badlink"
else
  rm -rf "$D19/codex-check/badlink"   # MSYS ln -s residue (real dir)
  printf 'note: no symlinks here — test 24 skipped (4 checks)\n'
  ok; ok; ok; ok
fi

# ---- 25. a NESTED model.txt is payload, not local state ----------------------------
mkdir -p "$SRCC/skills/codex-check/fixtures"
printf 'nested payload\n' > "$SRCC/skills/codex-check/fixtures/model.txt"
D25="$T/dest25"
XDG_STATE_HOME="$T/state25" bash "$SRCC/install.sh" --dest "$D25" --mode copy codex-check >/dev/null 2>&1 \
  && ok || bad "install with a nested model.txt failed"
[ "$(cat "$D25/codex-check/fixtures/model.txt" 2>/dev/null)" = "nested payload" ] \
  && ok || bad "the nested model.txt payload was silently dropped"
rm -rf "$SRCC/skills/codex-check/fixtures"

# ---- 26. a source with no SKILL.md refuses to symlink-install ----------------------
if [ "$LINKS_OK" -eq 1 ]; then
  mv "$SRCC/skills/codex-check/SKILL.md" "$T/skillmd.bak"
  if bash "$SRCC/install.sh" --dest "$T/d26" --mode symlink codex-check >/dev/null 2>"$T/e"; then
    bad "an entrypoint-less source symlink-installed"
  else ok; fi
  grep -q "SKILL.md" "$T/e" && ok || bad "missing SKILL.md not named"
  mv "$T/skillmd.bak" "$SRCC/skills/codex-check/SKILL.md"
else
  printf 'note: no symlinks here — test 26 skipped (2 checks)\n'
  ok; ok
fi

# ---- 27. a FAILED copy->symlink switch does not leak the pin into the source -------
if [ "$LINKS_OK" -eq 1 ]; then
  D27="$T/dest27"
  S27="$T/state27"
  XDG_STATE_HOME="$S27" bash "$SRCC/install.sh" --dest "$D27" --mode copy codex-check >/dev/null 2>&1
  printf 'gpt-9.9-pin27\n' > "$D27/codex-check/model.txt"
  rm -f "$SRCC/skills/codex-check/model.txt"
  if XDG_STATE_HOME="$S27" CLAUDE_SKILLS_INSTALL_TEST_FAIL=record-commit \
      bash "$SRCC/install.sh" --dest "$D27" --mode symlink codex-check >/dev/null 2>&1; then
    bad "injected symlink record-commit failure did not fail"
  else ok; fi
  [ ! -e "$SRCC/skills/codex-check/model.txt" ] && ok \
    || bad "the failed switch leaked the pin into the source checkout"
  [ "$(cat "$D27/codex-check/model.txt" 2>/dev/null)" = "gpt-9.9-pin27" ] && ok \
    || bad "the failed switch lost the previous copy install or its pin"
  find "$D27" -maxdepth 1 -name '.failed-*' -exec rm -rf {} + 2>/dev/null
else
  printf 'note: no symlinks here — test 27 skipped (3 checks)\n'
  ok; ok; ok
fi

# ---- 28. a SYMLINK at the skill root is never followed by discovery ----------------
if [ "$LINKS_OK" -eq 1 ]; then
  ln -s "$T" "$SRCC/skills/evil"
  if bash "$SRCC/install.sh" --dest "$T/d28" --mode copy >/dev/null 2>"$T/e"; then
    bad "no-operand discovery followed a skill-root symlink"
  else ok; fi
  grep -q "SYMLINK at the skill root" "$T/e" && ok || bad "root symlink not named"
  rm "$SRCC/skills/evil"
else
  printf 'note: no symlinks here — test 28 skipped (2 checks)\n'
  ok; ok
fi

# ---- 29. a failed record COMMIT strands no anonymous temp in the state dir ---------
D29="$T/dest29"
S29="$T/state29"
XDG_STATE_HOME="$S29" bash "$SRCC/install.sh" --dest "$D29" --mode copy codex-check >/dev/null 2>&1
printf '# fifth change\n' >> "$SRCC/skills/codex-check/SKILL.md"
if XDG_STATE_HOME="$S29" CLAUDE_SKILLS_INSTALL_TEST_FAIL=record-replace \
    bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1; then
  bad "injected record-replace failure did not fail"
else ok; fi
if grep -q "fifth change" "$D29/codex-check/SKILL.md"; then
  bad "record-replace failure left the NEW tree active"
else ok; fi
stray=$(find "$S29/claude-codex-skills" -maxdepth 1 -type f \
  ! -name 'install.*.json' ! -name 'install.lock' 2>/dev/null)
[ -z "$stray" ] && ok || bad "anonymous temp left in the state dir: $stray"
find "$D29" -maxdepth 1 -name '.failed-*' -exec rm -rf {} + 2>/dev/null

# ---- 30. an INTERRUPT during record commit rolls back like any failure -------------
D30="$T/dest30"
S30="$T/state30"
XDG_STATE_HOME="$S30" bash "$SRCC/install.sh" --dest "$D30" --mode copy codex-check >/dev/null 2>&1
printf 'gpt-9.9-keep30\n' > "$D30/codex-check/model.txt"
printf '# sixth change\n' >> "$SRCC/skills/codex-check/SKILL.md"
if XDG_STATE_HOME="$S30" CLAUDE_SKILLS_INSTALL_TEST_FAIL=record-interrupt \
    bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1; then
  bad "injected interrupt did not fail"
else ok; fi
if grep -q "sixth change" "$D30/codex-check/SKILL.md"; then
  bad "an interrupt during record commit left the NEW tree active"
else ok; fi
[ "$(cat "$D30/codex-check/model.txt")" = "gpt-9.9-keep30" ] && ok \
  || bad "interrupt rollback lost model.txt"
find "$D30" -maxdepth 1 -name '.failed-*' -exec rm -rf {} + 2>/dev/null

# ---- 31. a FIFO in the payload refuses instead of hanging the hash -----------------
fifo_native_ok=0
if mkfifo "$SRCC/skills/codex-check/fifo" 2>/dev/null && [ -p "$SRCC/skills/codex-check/fifo" ]; then
  # the hasher sees the payload through NATIVE python: an MSYS-emulated
  # fifo that python lstat reports as a regular file makes this test
  # unfalsifiable here — skip loudly (verified where fifos are real)
  if python3 -c 'import os,stat,sys;sys.exit(0 if stat.S_ISFIFO(os.lstat(sys.argv[1]).st_mode) else 1)' "$SRCC/skills/codex-check/fifo" 2>/dev/null; then
    fifo_native_ok=1
  fi
fi
if [ "$fifo_native_ok" -eq 1 ]; then
  if bash "$SRCC/install.sh" --dest "$T/d31" --mode copy codex-check >/dev/null 2>"$T/e"; then
    bad "a FIFO in the payload installed"
  else ok; fi
  grep -q "special file" "$T/e" && ok || bad "FIFO not named: $(cat "$T/e")"
  rm -f "$SRCC/skills/codex-check/fifo"
else
  rm -f "$SRCC/skills/codex-check/fifo"
  printf 'note: no native-visible fifo here — test 31 skipped (2 checks)\n'
  ok; ok
fi

# ---- 32. a destination inside the source checkout refuses --------------------------
if bash "$SRCC/install.sh" --dest "$SRCC/skills" --mode copy codex-check >/dev/null 2>"$T/e"; then
  bad "a destination inside the source checkout was accepted"
else ok; fi
grep -q "outside the checkout" "$T/e" && ok || bad "overlap refusal not named"
[ -f "$SRCC/skills/codex-check/SKILL.md" ] && ok \
  || bad "the overlap attempt damaged the source skill"

# ---- 33. a copy root replaced by a SYMLINK fails verify AND the probe ---------------
if [ "$LINKS_OK" -eq 1 ]; then
  D33="$T/dest33"
  S33="$T/state33"
  XDG_STATE_HOME="$S33" bash "$SRCC/install.sh" --dest "$D33" --mode copy codex-check >/dev/null 2>&1
  mv "$D33/codex-check" "$D33/.aside"
  ln -s "$D33/.aside" "$D33/codex-check"
  if XDG_STATE_HOME="$S33" bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>"$T/e"; then
    bad "a symlinked copy root passed --verify"
  else ok; fi
  grep -q "symlink" "$T/e" && ok || bad "symlinked copy root not named by --verify"
  po=$(XDG_STATE_HOME="$S33" bash "$D33/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
  [ "$pe" -ne 0 ] && ok || bad "probe passed a symlinked copy root"
  case $po in *symlink*) ok ;; *) bad "probe does not name the symlinked root: $po" ;; esac
else
  printf 'note: no symlinks here — test 33 skipped (4 checks)\n'
  ok; ok; ok; ok
fi

# ---- 34. a pin that is a SYMLINK is refused, never followed -------------------------
if [ "$LINKS_OK" -eq 1 ]; then
  D34="$T/dest34"
  S34="$T/state34"
  XDG_STATE_HOME="$S34" bash "$SRCC/install.sh" --dest "$D34" --mode copy codex-check >/dev/null 2>&1
  printf 'gpt-9.9-elsewhere\n' > "$T/elsewhere.txt"
  ln -s "$T/elsewhere.txt" "$D34/codex-check/model.txt"
  if XDG_STATE_HOME="$S34" bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>"$T/e"; then
    bad "a symlinked pin was silently followed"
  else ok; fi
  grep -q "regular file" "$T/e" && ok || bad "symlinked pin not named"
else
  printf 'note: no symlinks here — test 34 skipped (2 checks)\n'
  ok; ok
fi

# ---- 35. concurrent installs SERIALIZE: a held lock refuses with a remedy -----------
if python3 -c 'import fcntl' 2>/dev/null; then
  S35="$T/state35"
  mkdir -p "$S35/claude-codex-skills"
  rm -f "$T/lockready"
  python3 - "$S35/claude-codex-skills/install.lock" "$T/lockready" <<'PYEOF' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(20)
PYEOF
  LP=$!
  i=0; while [ ! -f "$T/lockready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  out=$(XDG_STATE_HOME="$S35" CLAUDE_SKILLS_INSTALL_TEST_LOCK_TRIES=1 \
        bash "$SRCC/install.sh" --dest "$T/d35" --mode copy codex-check 2>&1); ge=$?
  kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
  [ "$ge" -ne 0 ] && ok || bad "a concurrent install was not serialized"
  case $out in *lock*) ok ;; *) bad "lock refusal not named: $out" ;; esac
else
  printf 'note: no fcntl here — test 35 skipped (2 checks)\n'
  ok; ok
fi

# ---- 36. a stale write temporary is swept by the next locked run --------------------
S36="$T/state36"
mkdir -p "$S36/claude-codex-skills"
printf 'stale' > "$S36/claude-codex-skills/install.tmp.stale"
XDG_STATE_HOME="$S36" bash "$SRCC/install.sh" --dest "$T/d36" --mode copy codex-check >/dev/null 2>&1 \
  && ok || bad "install with a stale temp present failed"
[ ! -e "$S36/claude-codex-skills/install.tmp.stale" ] && ok \
  || bad "a stale temporary record survived the next locked run"

# ---- 37. the tree guard fails CLOSED when a blob is unreadable ----------------------
TG="$T/treeguard"
git init -q "$TG"
mkdir -p "$TG/tests"
cp "$ROOT/tests/check-tree.sh" "$TG/tests/check-tree.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$TG/probe.sh"
chmod +x "$TG/probe.sh" "$TG/tests/check-tree.sh"
git -C "$TG" add probe.sh tests/check-tree.sh
git -C "$TG" -c user.email=t@example.invalid -c user.name=t commit -qm x
blobid=$(git -C "$TG" rev-parse ":probe.sh")
rm -f "$TG/.git/objects/$(printf '%s' "$blobid" | cut -c1-2)/$(printf '%s' "$blobid" | cut -c3-)"
out=$( (cd "$TG" && bash tests/check-tree.sh) 2>&1 ); ge=$?
[ "$ge" -ne 0 ] && ok || bad "the tree guard certified a repo with an unreadable blob"
case $out in *"cannot be certified"*) ok ;; *) bad "the unreadable blob is not named: $out" ;; esac

# ---- 38. a state dir inside the DESTINATION refuses BEFORE any state mutation ------
D38="$T/dest38"
mkdir -p "$D38"
if XDG_STATE_HOME="$D38/statehome" bash "$SRCC/install.sh" --dest "$D38" --mode copy codex-check >/dev/null 2>"$T/e"; then
  bad "a state dir inside the destination was accepted"
else ok; fi
grep -q "overlaps the destination" "$T/e" && ok || bad "state/dest overlap not named"
[ ! -e "$D38/statehome" ] && ok \
  || bad "the refusal still created state (lock/sweep) inside the destination"

# ---- 39. a SOURCE pin symlink refuses even on a FRESH install -----------------------
if [ "$LINKS_OK" -eq 1 ]; then
  printf 'gpt-9.9-x\n' > "$T/pin-target.txt"
  ln -s "$T/pin-target.txt" "$SRCC/skills/codex-check/model.txt"
  if bash "$SRCC/install.sh" --dest "$T/d39" --mode copy codex-check >/dev/null 2>"$T/e"; then
    bad "a source pin symlink installed on a fresh install"
  else ok; fi
  grep -q "REGULAR" "$T/e" && ok || bad "pin symlink not named: $(cat "$T/e")"
  rm -f "$SRCC/skills/codex-check/model.txt"
else
  printf 'note: no symlinks here — test 39 skipped (2 checks)\n'
  ok; ok
fi

# ---- 40. an ANCESTOR symlink aliasing the source fails verify AND the probe ---------
if [ "$LINKS_OK" -eq 1 ]; then
  mv "$SRCC" "$T/srcreal"
  ln -s "$T/srcreal" "$SRCC"
  if bash "$T/srcreal/install.sh" --verify codex-check >/dev/null 2>"$T/e"; then
    bad "an ancestor-aliased source passed --verify"
  else ok; fi
  grep -q "canonical" "$T/e" && ok || bad "ancestor alias not named by --verify"
  po=$(bash "$D/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
  [ "$pe" -ne 0 ] && ok || bad "probe passed an ancestor-aliased source"
  case $po in *aliased*) ok ;; *) bad "probe does not name the alias: $po" ;; esac
  rm "$SRCC"
  mv "$T/srcreal" "$SRCC"
else
  printf 'note: no symlinks here — test 40 skipped (4 checks)\n'
  ok; ok; ok; ok
fi

# ---- 41. the tree guard scans the WHOLE repo even when run from a subdirectory ------
TG2="$T/treeguard2"
git init -q "$TG2"
mkdir -p "$TG2/tests"
cp "$ROOT/tests/check-tree.sh" "$TG2/tests/check-tree.sh"
printf '#!/usr/bin/env bash\r\necho hi\r\n' > "$TG2/crlf.sh"
chmod +x "$TG2/crlf.sh" "$TG2/tests/check-tree.sh"
git -C "$TG2" add crlf.sh tests/check-tree.sh
git -C "$TG2" -c user.email=t@example.invalid -c user.name=t commit -qm x
out=$( (cd "$TG2/tests" && bash check-tree.sh) 2>&1 ); ge=$?
[ "$ge" -ne 0 ] && ok \
  || bad "the tree guard run from a subdirectory missed a root-level CRLF script"
case $out in *"CR byte"*) ok ;; *) bad "root CRLF not named from a subdirectory run: $out" ;; esac

# ---- 42. a REAL SIGINT before the record commit rolls back --------------------------
if python3 -c 'import fcntl' 2>/dev/null; then
  D42="$T/dest42"; S42="$T/state42"
  XDG_STATE_HOME="$S42" bash "$SRCC/install.sh" --dest "$D42" --mode copy codex-check >/dev/null 2>&1
  printf 'gpt-9.9-keep42\n' > "$D42/codex-check/model.txt"
  printf '# seventh change\n' >> "$SRCC/skills/codex-check/SKILL.md"
  if XDG_STATE_HOME="$S42" CLAUDE_SKILLS_INSTALL_TEST_FAIL=sigint-early \
      bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1; then
    bad "a real mid-transaction SIGINT did not stop the refresh"
  else ok; fi
  if grep -q "seventh change" "$D42/codex-check/SKILL.md"; then
    bad "a real mid-transaction SIGINT left the NEW tree active"
  else ok; fi
  [ "$(cat "$D42/codex-check/model.txt")" = "gpt-9.9-keep42" ] && ok \
    || bad "real-SIGINT rollback lost model.txt"
  find "$D42" -maxdepth 1 -name '.failed-*' -exec rm -rf {} + 2>/dev/null
else
  printf 'note: no fcntl here — test 42 skipped (3 checks)\n'
  ok; ok; ok
fi

# ---- 43. a REAL SIGINT at the commit point: consistent COMMIT, honest note ----------
if python3 -c 'import fcntl' 2>/dev/null; then
  D43="$T/dest43"; S43="$T/state43"
  XDG_STATE_HOME="$S43" bash "$SRCC/install.sh" --dest "$D43" --mode copy codex-check >/dev/null 2>&1
  printf '# eighth change\n' >> "$SRCC/skills/codex-check/SKILL.md"
  out=$(XDG_STATE_HOME="$S43" CLAUDE_SKILLS_INSTALL_TEST_FAIL=sigint-commit \
        bash "$SRCC/install.sh" --refresh codex-check 2>&1); ge=$?
  [ "$ge" -ne 0 ] && ok || bad "a commit-point SIGINT was silently swallowed"
  case $out in *COMMITTED*) ok ;; *) bad "the committed note is missing: $out" ;; esac
  grep -q "eighth change" "$D43/codex-check/SKILL.md" && ok \
    || bad "the committed transaction was rolled back after all"
  XDG_STATE_HOME="$S43" bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>&1 \
    && ok || bad "state after a commit-point SIGINT is inconsistent (verify fails)"
  if [ -n "$(find "$D43" -maxdepth 1 \( -name '.old-*' -o -name '.stage-*' \) 2>/dev/null)" ]; then
    bad "backup/stage residue left after a commit-point SIGINT"
  else ok; fi
else
  printf 'note: no fcntl here — test 43 skipped (5 checks)\n'
  ok; ok; ok; ok; ok
fi

# ---- 44. a shape-valid record that does not BIND to its name/dest refuses -----------
S44="$T/state44"
mkdir -p "$S44/claude-codex-skills"
# paths go through the NATIVE boundary: python 3.13+ ntpath.isabs()
# rejects drive-less /tmp forms, which would fail SHAPE before BIND
src44=$(python3 -c 'import os,sys;sys.stdout.write(os.path.abspath(sys.argv[1]).replace(os.sep,"/"))' "$SRCC")
dst44=$(python3 -c 'import os,sys;sys.stdout.write(os.path.abspath(sys.argv[1]).replace(os.sep,"/"))' "$T/d44")
printf '{"schema":1,"skill":"codex-check","mode":"copy","source":"%s","dest":"%s/other","files":{}}' \
  "$src44" "$dst44" > "$S44/claude-codex-skills/install.codex-check.aaaaaaaaaaaa.v1.json"
if XDG_STATE_HOME="$S44" bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>"$T/e"; then
  bad "a misbound record passed --verify"
else ok; fi
grep -q "BIND" "$T/e" && ok || bad "the misbound record is not named: $(cat "$T/e")"
if XDG_STATE_HOME="$S44" bash "$SRCC/install.sh" --refresh codex-check >/dev/null 2>&1; then
  bad "a misbound record was refreshed"
else ok; fi
[ ! -e "$T/d44/codex-check" ] && ok \
  || bad "the misbound record steered an install at a sibling path"

# ---- 45. a DIRECTORY wearing the pin's name is refused, not installed ---------------
mkdir "$SRCC/skills/codex-check/model.txt"
if bash "$SRCC/install.sh" --dest "$T/d45" --mode copy codex-check >/dev/null 2>"$T/e"; then
  bad "a directory named model.txt installed as a pin"
else ok; fi
grep -q "REGULAR" "$T/e" && ok || bad "the directory pin is not named: $(cat "$T/e")"
rmdir "$SRCC/skills/codex-check/model.txt"

# ---- 46. skills/ itself replaced by a SYMLINK refuses (ancestor canonicality) -------
if [ "$LINKS_OK" -eq 1 ]; then
  mv "$SRCC/skills" "$T/skillsreal46"
  ln -s "$T/skillsreal46" "$SRCC/skills"
  if bash "$SRCC/install.sh" --dest "$T/d46" --mode copy codex-check >/dev/null 2>"$T/e"; then
    bad "an install through a symlinked skills/ ancestor succeeded"
  else ok; fi
  grep -q "canonical" "$T/e" && ok || bad "the skills/ alias is not named: $(cat "$T/e")"
  rm "$SRCC/skills"
  mv "$T/skillsreal46" "$SRCC/skills"
else
  printf 'note: no symlinks here — test 46 skipped (2 checks)\n'
  ok; ok
fi

# ---- 47. copy mode refuses an entrypoint-less source (no SKILL.md) ------------------
mv "$SRCC/skills/codex-check/SKILL.md" "$T/skillmd47.bak"
if bash "$SRCC/install.sh" --dest "$T/d47" --mode copy codex-check >/dev/null 2>"$T/e"; then
  bad "an entrypoint-less source copy-installed"
else ok; fi
grep -q "SKILL.md" "$T/e" && ok || bad "the missing SKILL.md is not named in copy mode"
mv "$T/skillmd47.bak" "$SRCC/skills/codex-check/SKILL.md"

# ---- 48. the probe validates EVERY record, not just up to the first match -----------
D48="$T/dest48"
S48="$T/state48"
XDG_STATE_HOME="$S48" bash "$SRCC/install.sh" --dest "$D48" --mode copy codex-check >/dev/null 2>&1
printf '{"schema":1,"truncated' > "$S48/claude-codex-skills/install.zzz.aaaaaaaaaaaa.v1.json"
po=$(XDG_STATE_HOME="$S48" bash "$D48/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
[ "$pe" -ne 0 ] && ok \
  || bad "the probe returned OK with a malformed record sorting after the match"
case $po in *record*) ok ;; *) bad "the later malformed record is not named: $po" ;; esac

# ---- 49. two lexical aliases of ONE physical destination share ONE record ----------
if [ "$LINKS_OK" -eq 1 ]; then
  D49="$T/dest49real"
  S49="$T/state49"
  mkdir -p "$D49"
  ln -s "$D49" "$T/dest49alias"
  XDG_STATE_HOME="$S49" bash "$SRCC/install.sh" --dest "$D49" --mode copy codex-check >/dev/null 2>&1
  XDG_STATE_HOME="$S49" bash "$SRCC/install.sh" --dest "$T/dest49alias" --mode copy codex-check >/dev/null 2>&1 \
    && ok || bad "reinstall through a destination alias failed"
  n=$(ls "$S49/claude-codex-skills" | grep -c '^install\.codex-check\.')
  [ "$n" -eq 1 ] && ok || bad "an alias produced $n records for one physical destination"
  XDG_STATE_HOME="$S49" bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>&1 \
    && ok || bad "verify after an alias reinstall failed"
else
  printf 'note: no symlinks here — test 49 skipped (3 checks)\n'
  ok; ok; ok
fi

# ---- 50. a symlink committed in HEAD fails the guard even if the index staged over it
TG3="$T/treeguard3"
git init -q "$TG3"
blob50=$(printf 'target' | git -C "$TG3" hash-object -w --stdin)
git -C "$TG3" update-index --add --cacheinfo "120000,$blob50,alias50"
git -C "$TG3" -c user.email=t@example.invalid -c user.name=t commit -qm x
git -C "$TG3" update-index --add --cacheinfo "100644,$blob50,alias50"
out=$( (cd "$TG3" && bash "$ROOT/tests/check-tree.sh") 2>&1 ); ge=$?
[ "$ge" -ne 0 ] && ok \
  || bad "a committed symlink staged over as a regular file passed the guard"
case $out in *"HEAD (mode 120000)"*) ok ;; *) bad "the HEAD symlink is not named: $out" ;; esac

# ---- 51. the probe FAILS (not skips) when the recorded dest root was aliased --------
if [ "$LINKS_OK" -eq 1 ]; then
  D51="$T/dest51"
  S51="$T/state51"
  XDG_STATE_HOME="$S51" bash "$SRCC/install.sh" --dest "$D51" --mode copy codex-check >/dev/null 2>&1
  mv "$D51" "$T/moved51"
  ln -s "$T/moved51" "$D51"
  po=$(XDG_STATE_HOME="$S51" bash "$D51/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
  [ "$pe" -ne 0 ] && ok \
    || bad "the probe returned OK for a destination root aliased after install"
  case $po in *canonical*) ok ;; *) bad "the aliased dest root is not named: $po" ;; esac
  if XDG_STATE_HOME="$S51" bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>"$T/e"; then
    bad "an aliased dest root passed --verify"
  else ok; fi
else
  printf 'note: no symlinks here — test 51 skipped (3 checks)\n'
  ok; ok; ok
fi

# ---- 52. case variants of ONE physical destination share ONE record ----------------
# (only meaningful on a case-insensitive filesystem — macOS default, NTFS)
printf 'x' > "$T/CaseProbe52"
if [ -f "$T/caseprobe52" ]; then CASE_INSENSITIVE=1; else CASE_INSENSITIVE=0; fi
rm -f "$T/CaseProbe52"
if [ "$CASE_INSENSITIVE" -eq 1 ]; then
  D52="$T/dest52"
  S52="$T/state52"
  mkdir -p "$D52"
  XDG_STATE_HOME="$S52" bash "$SRCC/install.sh" --dest "$D52" --mode copy codex-check >/dev/null 2>&1
  printf '# ninth change\n' >> "$SRCC/skills/codex-check/SKILL.md"
  XDG_STATE_HOME="$S52" bash "$SRCC/install.sh" --dest "$T/DEST52" --mode copy codex-check >/dev/null 2>&1 \
    && ok || bad "reinstall through a case-variant destination failed"
  n=$(ls "$S52/claude-codex-skills" | grep -c '^install\.codex-check\.')
  [ "$n" -eq 1 ] && ok || bad "case variants produced $n records for one physical destination"
  XDG_STATE_HOME="$S52" bash "$SRCC/install.sh" --verify codex-check >/dev/null 2>&1 \
    && ok || bad "verify after a case-variant reinstall failed"
else
  printf 'note: case-sensitive filesystem — test 52 skipped (3 checks)\n'
  ok; ok; ok
fi

# ---- 53. a case-variant XDG_STATE_HOME inside the checkout refuses BEFORE mutation --
if [ "$CASE_INSENSITIVE" -eq 1 ]; then
  vsrc=$(printf '%s' "$SRCC" | tr 'a-z' 'A-Z')
  out=$(XDG_STATE_HOME="$vsrc/statehome53" bash "$SRCC/install.sh" --dest "$T/d53" --mode copy codex-check 2>&1); ge=$?
  [ "$ge" -ne 0 ] && ok || bad "a case-variant state dir inside the checkout was accepted"
  case $out in *INSIDE*) ok ;; *) bad "the containment refusal is not named: $out" ;; esac
  [ ! -e "$SRCC/statehome53" ] && ok \
    || bad "the refusal still created state inside the checkout"
else
  printf 'note: case-sensitive filesystem — test 53 skipped (3 checks)\n'
  ok; ok; ok
fi

# ---- 54. two symlink installs of one skill never mask each other in the probe -------
if [ "$LINKS_OK" -eq 1 ]; then
  DA54="$T/dest54a"
  DB54="$T/dest54b"
  S54="$T/state54"
  XDG_STATE_HOME="$S54" bash "$SRCC/install.sh" --dest "$DA54" --mode symlink codex-check >/dev/null 2>&1
  XDG_STATE_HOME="$S54" bash "$SRCC/install.sh" --dest "$DB54" --mode symlink codex-check >/dev/null 2>&1
  mv "$DA54" "$T/moved54"
  ln -s "$T/moved54" "$DA54"
  po=$(XDG_STATE_HOME="$S54" bash "$DA54/codex-check/scripts/env-probe.sh" 2>&1); pe=$?
  [ "$pe" -ne 0 ] && ok \
    || bad "a healthy sibling symlink record masked the aliased parent"
  case $po in *canonical*) ok ;; *) bad "the aliased parent is not named: $po" ;; esac
else
  printf 'note: no symlinks here — test 54 skipped (2 checks)\n'
  ok; ok
fi

# ---- 55. --update: pull + refresh + NEW-skill adoption ---------------------------
# upstream repo -> clone -> install -> upstream gains a change AND a new
# skill -> ONE command delivers both; the pin survives
U55="$T/up55"; W55="$T/work55"; S55="$T/state55"; D55="$T/dest55"
mkdir -p "$U55/skills"
cp "$ROOT/install.sh" "$U55/"
cp -R "$ROOT/skills/codex-check" "$U55/skills/codex-check"
rm -f "$U55/skills/codex-check/model.txt"
git init -q "$U55"
git -C "$U55" add -A
git -C "$U55" -c user.email=t@example.invalid -c user.name=t commit -qm base
git clone -q "$U55" "$W55"
XDG_STATE_HOME="$S55" bash "$W55/install.sh" --dest "$D55" --mode copy codex-check >/dev/null 2>&1 \
  && ok || bad "update fixture: initial install failed"
printf 'gpt-9.9-keepme\n' > "$D55/codex-check/model.txt"
printf '# upstream v2\n' >> "$U55/skills/codex-check/SKILL.md"
mkdir -p "$U55/skills/newskill55/scripts"
printf '# new skill\n' > "$U55/skills/newskill55/SKILL.md"
git -C "$U55" add -A
git -C "$U55" -c user.email=t@example.invalid -c user.name=t commit -qm v2
uo=$(XDG_STATE_HOME="$S55" bash "$W55/install.sh" --update 2>&1); ue=$?
[ "$ue" -eq 0 ] && ok || bad "--update failed: $uo"
grep -q "upstream v2" "$D55/codex-check/SKILL.md" && ok \
  || bad "--update did not deliver the upstream change"
[ -f "$D55/newskill55/SKILL.md" ] && ok \
  || bad "--update did not adopt the NEW upstream skill"
if ls "$S55/claude-codex-skills"/install.newskill55.*.v1.json >/dev/null 2>&1; then ok
else bad "the adopted new skill has no installation record"; fi
[ "$(cat "$D55/codex-check/model.txt")" = "gpt-9.9-keepme" ] && ok \
  || bad "model.txt did not survive --update"
XDG_STATE_HOME="$S55" bash "$W55/install.sh" --verify >/dev/null 2>&1 && ok \
  || bad "verify after --update failed"

# ---- 56. --update refuses: divergence, flags, non-checkout ------------------------
printf '# local fork\n' >> "$W55/skills/codex-check/SKILL.md"
git -C "$W55" add -A
git -C "$W55" -c user.email=t@example.invalid -c user.name=t commit -qm local
printf '# upstream v3\n' >> "$U55/skills/codex-check/SKILL.md"
git -C "$U55" add -A
git -C "$U55" -c user.email=t@example.invalid -c user.name=t commit -qm v3
uo=$(XDG_STATE_HOME="$S55" bash "$W55/install.sh" --update 2>&1); ue=$?
[ "$ue" -ne 0 ] && ok || bad "--update fast-forwarded a DIVERGED checkout"
case $uo in *--update*) ok ;; *) bad "divergence remedy not named: $uo" ;; esac
grep -q "upstream v3" "$D55/codex-check/SKILL.md" \
  && bad "a refused pull still touched the install" || ok
uo=$(XDG_STATE_HOME="$S55" bash "$W55/install.sh" --update --dest "$D55" 2>&1); ue=$?
[ "$ue" -ne 0 ] && ok || bad "--update accepted --dest"
uo=$(XDG_STATE_HOME="$S55" bash "$SRCC/install.sh" --update 2>&1); ue=$?
[ "$ue" -ne 0 ] && ok || bad "--update ran outside a git checkout"
case $uo in *checkout*) ok ;; *) bad "non-checkout remedy not named: $uo" ;; esac
# action flags are mutually exclusive: last-one-wins would let
# `--update --refresh --dest X` silently bypass --update's flag restriction
uo=$(XDG_STATE_HOME="$S55" bash "$W55/install.sh" --update --refresh 2>&1); ue=$?
[ "$ue" -ne 0 ] && ok || bad "conflicting action flags were accepted"
case $uo in *conflicting*) ok ;; *) bad "conflict not named: $uo" ;; esac
uo=$(XDG_STATE_HOME="$S55" bash "$W55/install.sh" --refresh --verify 2>&1); ue=$?
[ "$ue" -ne 0 ] && ok || bad "--refresh --verify was accepted"

printf '%s\n' "check-install: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
