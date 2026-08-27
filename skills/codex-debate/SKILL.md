---
name: codex-debate
description: Run a task, then have Codex (top available GPT model, e.g. GPT-5.6 Sol) adversarially review the resulting diff, debate the findings, fix what is real, and loop until APPROVED. Use when the user asks for a task with codex review/debate, a second-opinion review loop, or independent verification of a change.
---

# Codex Debate Loop

## Quick Start

`/codex-debate <task>` — implement the task, get an adversarial review of the diff from Codex (top-tier model available on the plan), debate each finding, fix real issues, and loop until Codex returns `APPROVED` **and** local project checks are green.

If the work is already done and only a review is wanted, skip step 2 and start at step 3.

## Model Selection

Environment first, once per session: `bash "<skill dir>/scripts/env-probe.sh"` — silent exit 0 means healthy; on failure follow its printed remedies.
Then resolve once per debate: `bash "<skill dir>/scripts/resolve-model.sh" debate` prints `<slug>	<source>`; pass the user-named slug as a second argument only when the invocation names a model or tier ("use terra" → `gpt-5.6-terra`). Use that slug as `$MODEL` and state `model=<slug> source=<source>` in the final report.
On refusal (exit 1), follow the script's printed bootstrap verbatim — it is the ONLY pin-writing protocol; never pick or guess a model yourself.

## Hard Rules

- Reviewer runs `--sandbox read-only`, always. **Never** pass `--dangerously-bypass-approvals-and-sandbox` or `--sandbox danger-full-access`. Codex never edits files; Claude makes all changes.
- Never auto-apply reviewer suggestions. Judge every finding against the actual code first; rebut false positives with evidence.
- Max **5 review rounds**, plus at most ONE confirmation-only overflow round when a delta APPROVED lands exactly on round 5 (see step 6) — the overflow may only confirm or fail the gate, never debate. A debated-and-unchanged diff is never re-submitted **in response to a REVISE** — if nothing changed since the last round, stop and report the divergence instead of looping. (The confirmation round's full-diff resubmission after a delta APPROVED is the explicit, sanctioned exception.)
- Review rounds run **detached** (`nohup … &` + polling — see step 3). Never run a round in a foreground Bash call and never rely on the harness's background-task tracking: a review of a non-trivial diff legitimately outlives the foreground ceiling, and tracked background tasks have been observed killed within a minute. Foreground with `timeout: 300000` is only for quick probes and smoke tests.
- Distinguish **overrun** from **hang**: while the events log grows, the round is working — wait, never retry (a retry burns a full quota pass to hit the same wall). No event growth for 10 minutes = hang → kill, retry once. A round-1 retry additionally requires `rm "$RUN_DIR/launched"` first — the script's launch marker refuses a second id-less launch otherwise (it cannot tell a conscious retry from an accident; deleting the marker is that statement).
- On a rate-limit/quota error (rolling 5-hour window), an **authentication error (401)**, or a **model-access error**, stop the loop — hard non-approval. Surface whatever `remaining`/`resetsAt` info the error JSONL carries and the remedy for the USER (wait out the window / re-login / request tier access). Retry NOTHING automatically, never relaunch after credential remediation without the user asking, and never step down to another model silently. One sanctioned OFFER accompanies a subscription quota stop: print the channel-switch instruction (`/codex-login` → API key) together with `bash "<skill dir>/scripts/cost-estimate.sh" "$RUN_DIR/round.input" "$MODEL" <remaining rounds>` — the USER performs the switch and restarts the gate themselves; the interrupted run dir stays on its recorded channel (one channel per run) and a fresh run dir starts the paid gate.
- All scratch files live in the per-run `$RUN_DIR` created in step 1. **Never use fixed shared paths** (e.g. `/tmp/codex-debate-*.json`) — concurrent debates in different sessions on the same machine would clobber each other's verdicts.

## Workflow

### 1. Baseline

```bash
BASE=$(git rev-parse HEAD)
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-debate.XXXXXX")   # per-run scratch, safe under concurrent debates
git status --porcelain
```

Reuse the same `$BASE` and `$RUN_DIR` for every round of this debate (shell state does not persist between Bash calls — re-derive or inline the literal values each time).

If the tree is already dirty, note which changes predate the task and say so in the review prompt — they will appear in the diff.

### 2. Run the task

Implement the task with the normal workflow. Before the first review round, local checks must be green (the project's compile/build/test skills or commands; a specialized skill governing the task may name specific ones).

Never send a diff to review that you already know is broken.

### 3. Review round 1

**Pre-gate attestation first.** If a pre-gate checklist is in effect for this
gate — supplied by the project's docs or by a specialized skill that invoked
this debate — walk EVERY item, verify it against the actual diff, and write an
attestation block into the review prompt (item → how verified → result;
inapplicable items attested as N/A with a reason). An item that fails
attestation is fixed BEFORE the review — a known finding class must never cost
a reviewer round. This skill does not define any checklist itself.

Resolve `$MODEL` (see Model Selection) and the schema path: `SCHEMA=<skill dir>/review-schema.json`.

**Channel & cost guard (before round 1).** `bash "<skill dir>/scripts/auth-status.sh"` — one line, `mode=chatgpt|apikey|none|unknown`. `none` → stop; remedy: `/codex-login`. `apikey` → this gate bills per token: after building `round.input`, run `bash "<skill dir>/scripts/cost-estimate.sh" "$RUN_DIR/round.input" "$MODEL" 5` (worst-case whole gate), present its line, and proceed only on the user's explicit yes; exit 1 = the machine-local cap is exceeded — hard stop, the only bypass is the USER editing the cap file (`/codex-login` seeds prices/cap). The channel is recorded per run by review-round.sh and belongs in the final report.

Build the round input (review prompt first, then the diff), then launch via the bundled script — it owns the codex CLI contract and the detached launch; do not hand-write the codex command:

```bash
git add -N .   # intent-to-add: new files show up in the diff
{ printf '%s\n\n' "<review prompt>"; git diff --unified=5 "$BASE"; } > "$RUN_DIR/round.input"
bash "<skill dir>/scripts/review-round.sh" "$RUN_DIR" "$MODEL" xhigh "$SCHEMA"
```

The script fails fast on an empty `round.input` (an empty diff means there is nothing to review — stop, don't burn a quota pass). It returns immediately; poll with short foreground calls every 1–2 minutes:

```bash
kill -0 "$(cat "$RUN_DIR/pid")" 2>/dev/null && echo running || echo finished
wc -c "$RUN_DIR/events.jsonl"    # growing = working (overrun is normal); static for 10 min = hang
```

On `finished`, check `verdict.json` is non-empty before parsing; if the process died early, read `stderr.log` and the tail of `events.jsonl` for the error.

Review prompt template:

> You are an adversarial code reviewer. The task was: `<TASK>`. The unified diff is in the `<stdin>` block. Review ONLY this diff; use the repository read-only for surrounding context. Report concrete defects with a failure scenario — not style preferences. Verdict APPROVED only if no blocker or major findings remain.

Then extract:

```bash
THREAD_ID=$(PYTHONIOENCODING=utf-8 python3 -c 'import json,sys
for line in open(sys.argv[1], encoding="utf-8"):
    e = json.loads(line)
    if e.get("type") == "thread.started":
        print(e["thread_id"]); break' "$RUN_DIR/events.jsonl")
PYTHONIOENCODING=utf-8 python3 -m json.tool "$RUN_DIR/verdict.json"    # {verdict, summary, findings[]}
```

Keep `THREAD_ID` for all later rounds (explicit UUID, never `--last`).

### 4. Debate the findings

For **each** finding, judge it yourself before touching code:

- Real → fix it.
- Wrong → write a rebuttal with evidence (`file:line`, docs, test output).
- Unsure → verify by reading the code or running the check; never accept severity at face value.

Project conventions (CLAUDE.md, docs/) outrank reviewer taste — convention conflicts become rebuttals, or go to the user if genuinely contested. Re-run the local checks from step 2 after fixes.

### 4b. Scoreboard & drift watchdog (after EVERY round, before the next launch)

Run `bash "<skill dir>/scripts/round-report.sh" "$RUN_DIR"` and post the standard scoreboard, combining its machine line with your triage:

> **Round N** [model, channel]: found `b/M/m/n` (recurring `k/total`) · fixed `b/M/m/n` · rebutted `x` · tokens `in/out` (cumulative) · `trend=… drift=…`

Then act on the signals — this is the loop's own convergence law, not decoration:

- **`drift=yes`** (≥half of the round's findings re-flag already-debated sites): STOP before the next round. Patching again is the known dead end — present the cures and let the user pick: narrow the contract (delete the failing capability class), raise the findings to lemma-level rules, pin reality with executable fixtures, re-gate the burned surface in a FRESH thread, or re-scope the task.
- **`trend=flat` with `drift=no`** (majors not decreasing, but the sites are new): spend AT MOST one more round, and say explicitly that you are spending it; still flat after that → stop as above.
- **Requirements-level findings** (capacity caps, policy trade-offs, "no compliant option exists") — regardless of trend: stop immediately; those are USER decisions and further rounds only re-review prose.
- **`converging` / `approved`**: continue normally.

A watchdog stop is a legitimate outcome, not a failure — report it like a deadlock (each unresolved point, your position, the applicable cures) and never chase APPROVED past the signals.

### 5. Rounds 2..5 — resume the same thread

Same script, with the thread id as the fifth argument — that is what switches it
to `codex exec resume` with the correct flag set (`resume` has no `--sandbox` and
takes options only before the session id; the script owns those details).
In later Bash calls re-derive the model as `MODEL=$(cat "$RUN_DIR/model")` —
round 1 wrote it there, and the script enforces ONE model per run (a mismatching
model on a resume round is a hard error, never a silent switch).

**Delta rounds (default).** Middle rounds do NOT resend the full diff — the
thread already holds it, and full resends were measured ballooning a single gate
to 18M+ input tokens. Send per-finding resolutions plus the current hunks of
ONLY the files changed since the previous round; name the unchanged files as
unchanged. The FINAL round — the one expected to APPROVE — sends the full diff
again as ground truth.

```bash
git add -N .   # EVERY round, not just round 1 — a helper file created while fixing
               # a finding must be visible in this round's delta and in the final full diff
{ printf '%s\n\n' "Round N reply. FIXED: <list>. REBUTTED (with evidence): <list>. DELTA below covers only files changed this round: <files>; everything else is unchanged since the previous round."; \
  git diff --unified=5 "$BASE" -- <files changed this round>; } > "$RUN_DIR/round.input"
bash "<skill dir>/scripts/review-round.sh" "$RUN_DIR" "$MODEL" xhigh "$SCHEMA" "$THREAD_ID"
```

When naming `<files changed this round>`, derive the list mechanically — memory misses exactly the files it created late, and `git status` has no previous-round baseline. **Guard first:** the manifest below parses `git diff --name-only` line-wise, which is only safe for plain paths. If git C-quotes any path in the diff (tabs, newlines, backslashes, non-ASCII — the line starts with `"`), **disable the delta protocol for this debate and send the full diff every round** — delta is an optimization, never worth a silently missing file:

```bash
git add -N .
if git diff --name-only "$BASE" | grep -q '^"'; then
  echo "exotic paths in diff — delta protocol OFF, full diff every round"
fi
```

Otherwise keep a per-file diff manifest (a grep over a diff-of-diffs misses files whose hunks changed without their header line changing):

```bash
git diff --name-only "$BASE" | while IFS= read -r f; do
  printf '%s %s\n' "$(git diff "$BASE" -- "$f" | git hash-object --stdin)" "$f"
done > "$RUN_DIR/manifest.new"
# git hash-object, not shasum/sha1sum: git is the one tool this workflow
# already guarantees on every platform

# changed this round = files on lines that differ (changed hash, newly present,
# or reverted-to-base). Strip only the marker and the hash; spaces survive:
diff "$RUN_DIR/manifest.prev" "$RUN_DIR/manifest.new" | awk '/^[<>]/ {sub(/^[<>] [^ ]+ /, ""); print}' | sort -u
mv "$RUN_DIR/manifest.new" "$RUN_DIR/manifest.prev"
```

(Before round 1, create the baseline: run the manifest block once and just `mv` it to `manifest.prev`. A file that disappears from the diff — reverted to base — shows up as a `<` line and is correctly reported as changed.)

Poll the same way as in step 3.

On very large diffs (roughly 2,000+ changed lines) intermediate rounds may pass
`high` as the script's effort argument to stay inside a practical window — keep
`xhigh` for the final gate round. If a single pass is still impractical, chunk
the review by file groups within the same thread via the thread-id argument.

### 6. Terminate

- **An APPROVED verdict on a delta round does NOT close the gate.** It triggers
  the confirmation round: full diff, re-attestation of every checklist item
  whose subject changed during the debate, expecting APPROVED again. Only a
  full-diff APPROVED closes the gate — a file omitted from a delta must never
  hide a regression permanently. (Round 1 is always full-diff, so a round-1
  APPROVED closes the gate directly.) The confirmation round counts toward the
  5-round budget; if a delta APPROVED lands exactly on round 5, ONE confirmation
  round is permitted as the single sanctioned overflow (6 total) — it may only
  confirm or fail the gate, never open new debate.
- Full-diff `APPROVED` + local checks green → **success**. Report rounds used, findings fixed, findings rebutted, the reviewer model, the auth channel, and round-report's token totals (its final table is the gate scorecard).
- 5 rounds without `APPROVED` → stop. Present the unresolved findings and your position on each; the user decides.
- Codex repeats findings on an unchanged diff → stop, report the divergence (see Hard Rules).

Never claim success on your own judgment alone — success is the verdict plus green checks.

### Escalation knob

Default effort is `xhigh`. For a final gate on a risky change, one round at `-c model_reasoning_effort=max` (or `ultra`, where the model supports it; slow and quota-heavy — it spawns internal subagents) is acceptable. Do not run the whole loop above `xhigh`.

## Troubleshooting

- `error: unexpected argument '--sandbox' found` on round 2 → the resume call put
  options after `SESSION_ID`, or passed `--sandbox`, which `resume` does not have.
  See step 5: options first, `-c sandbox_mode='"read-only"'`, id and `-` last.
- Round killed exactly at the Bash timeout, or a harness-tracked background run
  dies within ~a minute leaving a 39-byte events log → it was run foreground or
  harness-tracked. Relaunch detached per step 3 (`nohup … &` + poll). A growing
  events log is an overrun, not a hang — wait, don't retry.
- `codex login status` prints to **stderr** — check both streams for "Logged in".
- 401 `require_sso_login` → the gate has hard-stopped; USER remedy: `codex logout && codex login`, then restart the gate manually.
- "model requires a newer version of Codex" → `npm install -g @openai/codex@latest`.
- Available models + validation evidence: `bash "<skill dir>/scripts/resolve-model.sh" --propose debate`.
- Reviewer looks stale / wrong family? `bash "<skill dir>/scripts/preflight-model.sh"` — silent means fresh; a printed line names what is stale and its remedy (report-only: it never updates codex).
- Reviews too slow / quota too tight → `bash "<skill dir>/scripts/resolve-model.sh" --propose debate` prints the candidates and the pinning protocol.
