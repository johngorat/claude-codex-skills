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
set -euo pipefail

RUN_DIR=$1; MODEL=$2; EFFORT=$3; SCHEMA=$4; THREAD_ID=${5:-}

[ -s "$RUN_DIR/round.input" ] || { echo "ERROR: $RUN_DIR/round.input missing or empty — nothing to review" >&2; exit 2; }
[ -s "$SCHEMA" ] || { echo "ERROR: schema not found: $SCHEMA" >&2; exit 2; }

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
