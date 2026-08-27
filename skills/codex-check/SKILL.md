---
name: codex-check
description: One-shot Codex review of the current diff — a single round, no debate loop. Claude triages the findings, fixes the real ones, and recommends escalating to /codex-debate if a major finding stands. Use for routine changes on proven patterns, small diffs, config/docs edits, or a quick second opinion where a full debate is too heavy.
---

# Codex Check (one-shot review)

## Quick Start

`/codex-check <what was done, or what to focus on>` — one review round: diff → Codex findings → Claude triages and fixes → short report. No loop, no `APPROVED` gate; the output is advisory.

## When to use / when not

- **Use for:** routine work that follows already-reviewed patterns, small diffs with limited blast radius, config and docs changes, a fast sanity pass before commit.
- **Do NOT use for:** infrastructure code, the first run of a new pipeline or template, validators/self-checks, or changes whose bugs surface late and cost a lot to find. Those get `/codex-debate`.
- **Escalation rule:** if after triage at least one `blocker` or `major` finding stands — Claude agrees it is real and non-trivial, or cannot confidently refute it — say so and recommend running `/codex-debate` for that change. Do not silently absorb an unresolved major.
- **Inspection default (whoever made the thing never checks the thing):** when substantive implementation work finishes WITHOUT any review gate — no check, no debate — OFFER this check before calling the work done. The user declining is fine and costs nothing, but the skip must be VISIBLE (stated in the wrap-up / session record), never silent; and the offer never auto-runs the review — quota is spent only on an explicit yes. Trivial mechanical edits don't trigger the offer.

## Model

Environment first, once per session: `bash "<skill dir>/scripts/env-probe.sh"` — silent exit 0 means healthy; on failure follow its printed remedies.
Then resolve: `bash "<skill dir>/scripts/resolve-model.sh" check` prints `<slug>	<source>` (second tier — fast, quota-cheap, adequate for a single advisory pass); pass the user-named slug as a second argument only when the invocation names a model or tier. State `model=<slug> source=<source>` in the report.
On refusal (exit 1), follow the script's printed bootstrap verbatim — it is the ONLY pin-writing protocol; never pick or guess a model yourself. Effort is `medium` (the launcher's third argument); pass `high` there only if the user asks for a deeper pass.

## Hard Rules

- Reviewer runs `--sandbox read-only`, always. **Never** pass `--dangerously-bypass-approvals-and-sandbox` or `--sandbox danger-full-access`. Codex never edits files; Claude makes all changes.
- Never auto-apply reviewer suggestions. Judge every finding against the actual code first.
- **One codex call total.** No resume, no rounds. Escalation happens through `/codex-debate`, not by extending this skill.
- **Every launch goes through the bundled `scripts/review-round.sh`** (detached + poll), whatever the diff size — it is the single owner of the codex CLI contract and of the run-dir laws (one model / one auth channel per run, launch marker, mutation lock, rotated telemetry); a hand-written foreground `codex exec` bypasses all of them. Never pass a thread id here — that is the debate's resume path.
- Distinguish **overrun** from **hang**: while `$RUN_DIR/events.jsonl` grows, the round is working — wait. No growth for 10 minutes = hang → kill the pid, `rm "$RUN_DIR/launched"` (the launcher refuses a second launch otherwise; deleting the marker is the conscious retry statement), relaunch once.
- Scratch files live in a per-run `mktemp` dir — never fixed shared paths.
- On a rate-limit/quota, **authentication (401)**, or **model-access** error, report it with the USER's remedy and stop — retry nothing, never relaunch after credential remediation without the user asking, never substitute another model silently.

## Workflow

### 1. Scratch and baseline

```bash
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-check.XXXXXX")
BASE=$(git rev-parse HEAD)
```

### 2. Single review call

Resolve `$MODEL` (see Model) and `SCHEMA=<skill dir>/review-schema.json`.

Build the round input — diff FIRST as its own file, because the emptiness
check must run on the diff alone: once the prompt is prepended, the launcher's
empty-input fail-fast can never fire, and an empty diff would buy a paid
review of nothing.

```bash
git add -N .   # intent-to-add: new files show up in the diff
git diff --unified=5 "$BASE" > "$RUN_DIR/diff"
[ -s "$RUN_DIR/diff" ] || { echo "nothing to review — the diff is empty"; }   # STOP here
{ printf '%s\n\n' "<review prompt>"; cat "$RUN_DIR/diff"; } > "$RUN_DIR/round.input"
```

Review prompt template:

> You are a code reviewer giving a second opinion. The task was: `<TASK>`. The unified diff follows this prompt. Review ONLY this diff; use the repository read-only for surrounding context. Report concrete defects with a failure scenario — not style preferences. This is a single-pass review; there will be no follow-up round, so include everything that matters now.

**Channel & cost guard (BEFORE the call spends anything).** `bash "<skill dir>/scripts/auth-status.sh"` — `mode=none` → stop; remedy `/codex-login`. `mode=apikey` → this single pass bills per token: run `bash "<skill dir>/scripts/cost-estimate.sh" "$RUN_DIR/round.input" "$MODEL" 1`, present the line, and proceed only on the user's explicit yes; exit 1 = the machine-local cap is exceeded — hard stop (the USER edits the cap file to override; `/codex-login` seeds prices/cap).

Launch through the bundled launcher (Hard Rules) — no thread id, one round:

```bash
bash "<skill dir>/scripts/review-round.sh" "$RUN_DIR" "$MODEL" medium "$SCHEMA"
```

It fails fast on an empty `round.input` and returns immediately. Poll with
short foreground calls every 1–2 minutes:

```bash
kill -0 "$(cat "$RUN_DIR/pid")" 2>/dev/null && echo running || echo finished
wc -c "$RUN_DIR/events.jsonl"    # growing = working; static for 10 min = hang (Hard Rules)
```

On `finished`, check `verdict.json` is non-empty before parsing; if the
process died early, read `stderr.log` and the tail of `events.jsonl`:

```bash
PYTHONIOENCODING=utf-8 python3 -m json.tool "$RUN_DIR/verdict.json"
```

(The launcher keeps `events.jsonl` — its `turn.completed` usage feeds the
round-report scoreboard and the codex-plan scorecard.)

### 3. Triage

For each finding: real and quick to fix → fix now; real but substantial → escalation candidate; wrong → note the rebuttal with evidence. Re-run local checks if anything was fixed.

### 4. Report

Open with the standard scoreboard: run `bash "<skill dir>/scripts/round-report.sh" "$RUN_DIR"` and quote its line (found counts by severity, tokens, model, channel), then add your triage — fixed `b/M/m/n`, rebutted `x`. On the `apikey` channel restate the step-2 estimate next to the actual tokens spent. Then: findings left open, and if any open `blocker`/`major` remains → explicitly recommend `/codex-debate` for this change.

## Troubleshooting

Same as `codex-debate`: login status prints to stderr; `codex logout && codex login` on SSO 401; `npm install -g @openai/codex@latest` if the model requires a newer CLI.
Reviewer looks stale / wrong family? `bash "<skill dir>/scripts/preflight-model.sh"` — silent means fresh; a printed line names what is stale and its remedy (report-only: it never updates codex).
