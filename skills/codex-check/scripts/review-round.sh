#!/usr/bin/env bash
# Launch ONE detached Codex review round and return immediately.
#
# Usage:
#   review-round.sh <run_dir> <model> <effort> <schema> [thread_id]
#
# Contract:
#   - The full round input (review prompt + unified diff) must already be at
#     <run_dir>/round.input. Empty input is a hard error: nothing to review.
#   - Round 1: omit thread_id. Rounds 2+: pass the thread UUID from round 1's
#     thread.started event.
#   - Returns immediately. Poll:  kill -0 "$(cat <run_dir>/pid)"
#     Progress:                   wc -c <run_dir>/events.jsonl   (growing = working)
#     Result (after exit):        <run_dir>/verdict.json          (schema-validated)
#     Errors:                     <run_dir>/stderr.log
#
# This script is the single owner of the codex CLI contract:
#   - `exec` takes --sandbox; `exec resume` does NOT — sandbox goes via -c sandbox_mode.
#   - On `resume`, every option must precede the SESSION_ID positional.
#   - `-` as the PROMPT argument = read the prompt from stdin; it stays last.
#   - nohup + detach, because foreground calls die at the Bash ceiling and
#     harness-tracked background tasks have been observed killed within a minute.
#   - Resume-target law: `codex exec resume` with a missing or garbage id has
#     been observed (third-party measurement, 2026-07-08, adopted here) to
#     silently fall back to the MOST RECENT session instead of erroring — and
#     a wrong-target resume looks exactly like a successful one. So: the id is
#     validated as EXACTLY one UUID (python re.fullmatch over the whole value)
#     BEFORE any launch, and the run dir pins its thread the same way it pins
#     its model — one thread per run, record created no-clobber on the FIRST
#     resume, an empty/corrupt record refuses (never overwritten), a mismatch
#     refuses, and an id-LESS launch into a run dir that already pinned a
#     thread refuses too (it would open a second thread in the same run).
#     Round 1 returns before the thread.started event exists, so rounds 2
#     vs 3+ get cross-run protection and round 1 vs 2 gets the shape gate.
set -euo pipefail

RUN_DIR=$1; MODEL=$2; EFFORT=$3; SCHEMA=$4; THREAD_ID=${5:-}

[ -s "$RUN_DIR/round.input" ] || { echo "ERROR: $RUN_DIR/round.input missing or empty — nothing to review" >&2; exit 2; }
[ -s "$SCHEMA" ] || { echo "ERROR: schema not found: $SCHEMA" >&2; exit 2; }

# One model per run: the FIRST launch records the resolved slug; every later
# launch — resume OR a re-run of round 1 in the same run dir — must present
# the same one. A model switch mid-run is always a bug or a silent fallback —
# both are hard errors, never absorbed, and the record is created only when
# absent so a retry can never overwrite it. A resume with NO recorded model
# is equally hard: without the record the comparison cannot happen, and
# accepting the caller's word re-opens the silent-switch hole.
if [ -s "$RUN_DIR/model" ]; then
  PINNED=$(cat "$RUN_DIR/model")
  if [ "$PINNED" != "$MODEL" ]; then
    echo "ERROR: model '$MODEL' differs from this run's recorded model '$PINNED' — pass '$PINNED' (one resolution per run) or start a fresh run dir" >&2
    exit 2
  fi
elif [ -n "$THREAD_ID" ]; then
  echo "ERROR: resume round but $RUN_DIR/model is missing or empty — round 1 records the run's model and a resume may not re-choose it. Restore the original run dir or start a fresh debate" >&2
  exit 2
else
  printf '%s\n' "$MODEL" > "$RUN_DIR/model"
fi

# Resume-target law (header): validate the id's shape, then pin one thread
# per run dir. Every failure exits BEFORE any codex process exists.
if [ -z "$THREAD_ID" ] && [ -e "$RUN_DIR/thread" ]; then
  echo "ERROR: $RUN_DIR/thread already records this run's thread but no thread id was passed — a fresh launch here would open a SECOND thread in the same run dir. Pass the recorded id (cat $RUN_DIR/thread) or start a fresh run dir" >&2
  exit 2
fi
if [ -n "$THREAD_ID" ]; then
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found — run env-probe.sh and follow its remedy" >&2; exit 2; }
  # python re.fullmatch over the WHOLE argv value (parsing law: python3, not
  # grep — a line-wise match would pass a multi-line value containing one
  # valid UUID line, and codex would receive the malformed whole).
  if ! PYTHONIOENCODING=utf-8 python3 -c 'import re,sys; sys.exit(0 if re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", sys.argv[1]) else 1)' "$THREAD_ID"; then
    echo "ERROR: the passed thread id is not exactly one UUID — refusing to resume: codex has been observed silently resuming the MOST RECENT session on a malformed id, and a wrong-target resume looks successful. Take the id from round 1's thread.started event" >&2
    exit 2
  fi
  if [ -e "$RUN_DIR/thread" ]; then
    RECORDED_THREAD=$(cat "$RUN_DIR/thread" 2>/dev/null || true)
    if [ -z "$RECORDED_THREAD" ]; then
      # -e not -s above: an EMPTY record is corrupt (interrupted write), and a
      # corrupt record is refused, never silently replaced — same law as model.
      echo "ERROR: $RUN_DIR/thread exists but is empty or unreadable — the thread record is corrupt and is never overwritten. Start a fresh run dir" >&2
      exit 2
    fi
    if [ "$RECORDED_THREAD" != "$THREAD_ID" ]; then
      echo "ERROR: thread id '$THREAD_ID' differs from this run's recorded thread '$RECORDED_THREAD' — one thread per run dir; a cross-run resume would graft rounds onto a foreign review. Pass '$RECORDED_THREAD' or start a fresh run dir" >&2
      exit 2
    fi
  else
    # no-clobber creation: two concurrent first-resumes must not both win
    if ! (set -C; printf '%s\n' "$THREAD_ID" > "$RUN_DIR/thread") 2>/dev/null; then
      echo "ERROR: $RUN_DIR/thread appeared concurrently — another launch is using this run dir; refusing" >&2
      exit 2
    fi
  fi
fi

# Rotate previous round's artifacts instead of truncating them: token usage in
# the events logs feeds the end-of-run scorecard, so every round must survive.
N=$(find "$RUN_DIR" -maxdepth 1 -name 'events.r*.jsonl' | wc -l | tr -d ' ')   # find, not ls: zero matches must not trip pipefail
if [ -f "$RUN_DIR/events.jsonl" ]; then
  R=$((N + 1))
  mv "$RUN_DIR/events.jsonl" "$RUN_DIR/events.r$R.jsonl"
  # verdict.json is MOVED, not copied: while a round runs there must be no
  # verdict file — a round that dies early must never be read as the previous
  # round's (possibly APPROVED) verdict.
  [ -f "$RUN_DIR/verdict.json" ] && mv "$RUN_DIR/verdict.json" "$RUN_DIR/verdict.r$R.json"
  [ -f "$RUN_DIR/stderr.log" ] && mv "$RUN_DIR/stderr.log" "$RUN_DIR/stderr.r$R.log"
  cp "$RUN_DIR/round.input" "$RUN_DIR/round.r$((R + 1)).input" 2>/dev/null || true
fi

if [ -z "$THREAD_ID" ]; then
  nohup codex exec \
    -m "$MODEL" -c "model_reasoning_effort=$EFFORT" \
    --sandbox read-only --json \
    --output-schema "$SCHEMA" \
    -o "$RUN_DIR/verdict.json" \
    - \
    < "$RUN_DIR/round.input" > "$RUN_DIR/events.jsonl" 2> "$RUN_DIR/stderr.log" &
else
  nohup codex exec resume \
    -m "$MODEL" -c "model_reasoning_effort=$EFFORT" \
    -c 'sandbox_mode="read-only"' \
    --json \
    --output-schema "$SCHEMA" \
    -o "$RUN_DIR/verdict.json" \
    "$THREAD_ID" - \
    < "$RUN_DIR/round.input" > "$RUN_DIR/events.jsonl" 2> "$RUN_DIR/stderr.log" &
fi

echo $! > "$RUN_DIR/pid"
echo "launched pid=$(cat "$RUN_DIR/pid"); poll: kill -0 \$(cat $RUN_DIR/pid); events: $RUN_DIR/events.jsonl"
