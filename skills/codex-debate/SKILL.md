---
name: codex-debate
description: Run a task, then have Codex (top available GPT model, e.g. GPT-5.6 Sol) adversarially review the resulting diff, debate the findings, fix what is real, and loop until APPROVED. Use when the user asks for a task with codex review/debate, a second-opinion review loop, or independent verification of a change.
---

# Codex Debate Loop

## Quick Start

`/codex-debate <task>` — implement the task, get an adversarial review of the diff from Codex (top-tier model available on the plan), debate each finding, fix real issues, and loop until Codex returns `APPROVED` **and** local project checks are green.

If the work is already done and only a review is wanted, skip step 2 and start at step 3.

## Model Selection

Resolve `$MODEL` once at the start of the loop, in this order:

1. **User override** — if the invocation names a model or tier ("use terra", "on luna", "with 5.5"), map it to the slug (`gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, …) and use that.
2. **Pinned model** — if a `model.txt` exists next to this SKILL.md, use its contents (written by the installer or the user to save quota).
3. **Auto (default)** — the top tier the CLI knows about:

```bash
MODEL=$(jq -r '[.models[] | select(.visibility=="list")] | sort_by(.priority) | .[0].slug' ~/.codex/models_cache.json)
```

Lower `priority` = higher tier (1 = flagship). The cache refreshes whenever codex runs, so new families (5.7, 5.8, …) are picked up automatically.

If a codex call fails with a **model-access error** mid-loop, step down to the next slug by ascending priority and continue; in the final report state which model actually reviewed, and advise the user to request top-tier access from their ChatGPT workspace admin or upgrade the subscription.

Always state the resolved model in the final report.

## Hard Rules

- Reviewer runs `--sandbox read-only`, always. **Never** pass `--dangerously-bypass-approvals-and-sandbox` or `--sandbox danger-full-access`. Codex never edits files; Claude makes all changes.
- Never auto-apply reviewer suggestions. Judge every finding against the actual code first; rebut false positives with evidence.
- Max **5 review rounds**. A debated-and-unchanged diff is never re-submitted — if nothing changed since the last round, stop and report the divergence instead of looping.
- Run every `codex` command with the Bash tool `timeout` set to `300000` ms. On a hang, kill and retry once.
- On a rate-limit/quota error (rolling 5-hour window), stop the loop, surface whatever `remaining`/`resetsAt` info the error JSONL carries, and tell the user.

## Workflow

### 1. Baseline

```bash
BASE=$(git rev-parse HEAD)
git status --porcelain
```

If the tree is already dirty, note which changes predate the task and say so in the review prompt — they will appear in the diff.

### 2. Run the task

Implement the task with the normal workflow. Before the first review round, local checks must be green (use this project's compile/build/test skills or commands).

Never send a diff to review that you already know is broken.

### 3. Review round 1

Resolve `$MODEL` (see Model Selection) and the schema path: `SCHEMA=<skill dir>/review-schema.json`.

```bash
git add -N .   # intent-to-add: new files show up in the diff
git diff --unified=5 "$BASE" | codex exec \
  -m "$MODEL" -c model_reasoning_effort=xhigh \
  --sandbox read-only --json \
  --output-schema "$SCHEMA" \
  -o /tmp/codex-debate-verdict.json \
  "<review prompt>" | tee /tmp/codex-debate-events.jsonl | tail -3
```

Review prompt template:

> You are an adversarial code reviewer. The task was: `<TASK>`. The unified diff is in the `<stdin>` block. Review ONLY this diff; use the repository read-only for surrounding context. Report concrete defects with a failure scenario — not style preferences. Verdict APPROVED only if no blocker or major findings remain.

Then extract:

```bash
THREAD_ID=$(jq -r 'select(.type=="thread.started").thread_id' /tmp/codex-debate-events.jsonl)
jq . /tmp/codex-debate-verdict.json    # {verdict, summary, findings[]}
```

Keep `THREAD_ID` for all later rounds (explicit UUID, never `--last`).

### 4. Debate the findings

For **each** finding, judge it yourself before touching code:

- Real → fix it.
- Wrong → write a rebuttal with evidence (`file:line`, docs, test output).
- Unsure → verify by reading the code or running the check; never accept severity at face value.

Project conventions (CLAUDE.md, docs/) outrank reviewer taste — convention conflicts become rebuttals, or go to the user if genuinely contested. Re-run the local checks from step 2 after fixes.

### 5. Rounds 2..5 — resume the same thread

```bash
{ printf '%s\n\n' "Round N reply. FIXED: <list>. REBUTTED (with evidence): <list>. Full updated diff follows."; \
  git diff --unified=5 "$BASE"; } | codex exec resume "$THREAD_ID" \
  -m "$MODEL" -c model_reasoning_effort=xhigh \
  --sandbox read-only --json \
  --output-schema "$SCHEMA" \
  -o /tmp/codex-debate-verdict.json - | tail -3
```

### 6. Terminate

- `APPROVED` + local checks green → **success**. Report rounds used, findings fixed, findings rebutted, and the reviewer model.
- 5 rounds without `APPROVED` → stop. Present the unresolved findings and your position on each; the user decides.
- Codex repeats findings on an unchanged diff → stop, report the divergence (see Hard Rules).

Never claim success on your own judgment alone — success is the verdict plus green checks.

### Escalation knob

Default effort is `xhigh`. For a final gate on a risky change, one round at `-c model_reasoning_effort=max` (or `ultra`, where the model supports it; slow and quota-heavy — it spawns internal subagents) is acceptable. Do not run the whole loop above `xhigh`.

## Troubleshooting

- `codex login status` prints to **stderr** — check both streams for "Logged in".
- 401 `require_sso_login` → `codex logout && codex login`.
- "model requires a newer version of Codex" → `npm install -g @openai/codex@latest`.
- Available models: `jq -r '.models[].slug' ~/.codex/models_cache.json`.
- Reviews too slow / quota too tight → pin a cheaper tier: `echo gpt-5.6-terra > <skill dir>/model.txt` (delete the file to return to auto top-tier).
