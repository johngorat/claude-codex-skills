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

## Model

Default is the **second tier** in the catalog (one below flagship) — fast and quota-cheap, adequate for a single advisory pass:

```bash
MODEL=$(jq -r '[.models[] | select(.visibility=="list")] | sort_by(.priority) | .[1].slug // .[0].slug' ~/.codex/models_cache.json)
```

Overrides, strongest first: a model named in the invocation ("use sol", "on luna") → `model.txt` next to this SKILL.md → the default above. Effort is `medium`; bump to `high` only if the user asks for a deeper pass.

## Hard Rules

- Reviewer runs `--sandbox read-only`, always. **Never** pass `--dangerously-bypass-approvals-and-sandbox` or `--sandbox danger-full-access`. Codex never edits files; Claude makes all changes.
- Never auto-apply reviewer suggestions. Judge every finding against the actual code first.
- **One codex call total.** No resume, no rounds. Escalation happens through `/codex-debate`, not by extending this skill.
- Run the `codex` command with the Bash tool `timeout` set to `300000` ms. On a hang, kill and retry once.
- Scratch files live in a per-run `mktemp` dir — never fixed shared paths.
- On a rate-limit/quota error, report it and stop.

## Workflow

### 1. Scratch and baseline

```bash
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-check.XXXXXX")
BASE=$(git rev-parse HEAD)
```

### 2. Single review call

Resolve `$MODEL` (see Model) and `SCHEMA=<skill dir>/review-schema.json`.

```bash
git add -N .   # intent-to-add: new files show up in the diff
git diff --unified=5 "$BASE" | codex exec \
  -m "$MODEL" -c model_reasoning_effort=medium \
  --sandbox read-only --json \
  --output-schema "$SCHEMA" \
  -o "$RUN_DIR/verdict.json" \
  "<review prompt>" | tail -3
jq . "$RUN_DIR/verdict.json"
```

Review prompt template:

> You are a code reviewer giving a second opinion. The task was: `<TASK>`. The unified diff is in the `<stdin>` block. Review ONLY this diff; use the repository read-only for surrounding context. Report concrete defects with a failure scenario — not style preferences. This is a single-pass review; there will be no follow-up round, so include everything that matters now.

### 3. Triage

For each finding: real and quick to fix → fix now; real but substantial → escalation candidate; wrong → note the rebuttal with evidence. Re-run local checks if anything was fixed.

### 4. Report

State: the model used, findings fixed, findings rebutted (and why), findings left open. If any open `blocker`/`major` remains → explicitly recommend `/codex-debate` for this change.

## Troubleshooting

Same as `codex-debate`: login status prints to stderr; `codex logout && codex login` on SSO 401; `npm install -g @openai/codex@latest` if the model requires a newer CLI.
