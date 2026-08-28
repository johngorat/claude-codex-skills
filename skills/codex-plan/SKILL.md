---
name: codex-plan
description: Turn a substantial multi-stage task into a staged, gate-reviewed execution plan — stages with deliverables, a review tier per stage (codex-check vs codex-debate), past reviewer findings converted into hard requirements, and named tools to reuse. Use BEFORE writing any code when starting a port, migration, new pipeline run, or any task big enough to need more than one review.
---

# Codex Plan (staged task resolver)

## Quick Start

`/codex-plan <task>` — produce a staged plan, show it to the user for approval, then execute it stage by stage using `/codex-check` and `/codex-debate` at the tiers the plan assigns.

The plan is the deliverable of the first step. Never start implementing before the user has seen and approved it.

A task that passes /codex-plan-fast's fit gate (proven rails, diff-bounded blast radius, one check covers it) belongs in that lane — route it there instead of staging it here.

**No pre-interview.** Steps 1–6 are autonomous document work — do them without asking the user anything. Questions that come up while drafting go INTO the plan as marked decision points and are asked together with the plan presentation: one consolidated approval round, not a conversation before the work starts.

## Procedure

### 1. Classify the ground

List explicitly which parts of the task ride **proven rails** (tools, templates, and patterns that already passed a review gate in this project) and which parts are **new ground** (anything an existing template or gated tool does not cover). This classification drives everything below.

### 2. Gather lessons before writing the plan

Search, in this order:

- project docs: manual chapters, decision log, declared-divergence registry, prior plan documents of the same kind;
- final reports of previous `/codex-debate` runs — every finding that was FIXED there is a lesson that can recur;
- project memory files, if present.

Convert each relevant lesson into a **hard requirement** in the plan, phrased as a constraint with a concrete check, not as advice. ("Every appearance anchor must be renderable: alpha > 0, not clipped" — not "make good anchors".)

### 3. Split into stages

Typical shape: data/harvest → spec/values → implementation → verification. Merge or drop stages that don't apply; add domain stages that do. Each stage gets: deliverables (file paths), tools to reuse (by name/path), requirements (from step 2), and a review tier.

### 4. Assign a review tier to every stage

- **`/codex-debate`** (full loop, top model): infrastructure code; the first stretch of a template or pipeline to a new case; validators and self-checks; areas where bugs surface late and cost a lot.
- **`/codex-check`** (one-shot, second tier): stages fully on proven rails; small glue; docs.
- Write the escalation rule into the plan: a check that leaves a major finding standing upgrades that stage to a debate.
- If a proven tool needs extension mid-task, the extension diff alone gets a debate gate — the rest of the stage keeps its tier.

### 5. Define success measurably

Per gate: reviewer verdict `APPROVED`, project validators green, probes matching the spec, determinism/regression runs where the project standard requires them. "Looks right" is not a criterion.

### 6. Mark user-decision points

Any choice only the owner can make (policy trade-offs, deliberate divergences from the source material, architecture buckets that fit no existing rule) is marked in the plan as a STOP-and-ask point. Split them into two tiers:

- **Load-bearing** (wrong answer costs a migration, a rewrite, a security hole, or a broken gate) — each one ships in this format, no exceptions:
  - **Why it matters:** the dependency or constraint that makes it load-bearing.
  - **Recommendation:** ONE committed answer — not a menu with a shrug.
  - **If we guess wrong:** the concrete failure.
- **Cosmetic** (renameable, refactorable, cheap to change later) — one batch of recommendations with a one-line rationale each; the user vetoes by exception, silence = accepted.

If a decision's "if we guess wrong" line comes out weak while drafting, it is cosmetic — demote it. If it turns out answerable from the code, docs, or a past gate, answer it yourself and record it in the assumptions ledger instead of asking.

### 7. Present, then execute

Show the plan. The presentation carries, besides the stages:

- **Assumptions Ledger** — everything resolved autonomously while drafting, each entry with its source (code path, doc, past finding, measurement). Presented ONCE as a batch — anything the user does not correct is confirmed. Never drip assumptions as individual questions.
- **Decision Map** — the two decision tiers from step 6, so the user sees how many answers the plan is waiting on.
- **Escape hatch** — the user can say "accept all remaining recommendations": every open decision locks at its recommended answer and is recorded as such in the plan. Offer it explicitly when the load-bearing tier exceeds ~4 questions.

This stays ONE consolidated approval round — the ledger and the decisions ride WITH the plan, never as an interview before it.

After approval, execute stage by stage; after each gate report rounds used, findings fixed/rebutted, and the reviewer model. If reality diverges from the plan (escalations, new ground discovered), say so at the moment it happens, not in the final report.

**Gate execution means invoking the `/codex-debate` or `/codex-check` skill** for that stage — load the skill and follow its protocol. Never substitute an ad-hoc codex CLI call: in particular `codex review` / `codex exec review` is OpenAI's own separate review flow — it bypasses the round protocol, the verdict schema, the model selection, and the sandbox rules, and does NOT count as a gate.

**Scorecard (mandatory in the final report).** Per gate: tier, reviewer model, auth channel, rounds used, wall-clock, findings fixed/rebutted. Token totals come from `bash "<skill dir>/scripts/round-report.sh" "$RUN_DIR"` (the debate/check skill's script directory and that gate's run dir) — its per-round table and `tokens_in/tokens_out` totals read `events.jsonl` plus the rotated `events.r*.jsonl` (review-round.sh rotates rounds instead of truncating precisely so this data survives). Also record: findings caught before review (validator/checklist attestation) vs findings raised by the reviewer, and user-found issues after gates. If the project keeps session records, append the same scorecard there — trend across tasks is the measure of the process itself.

## Plan quality bar

- Every requirement is traceable to a past finding, a project rule, or a gated artifact — no generic advice.
- Tools are named by path; the plan reuses gated tooling instead of rebuilding it.
- Placeholders (ids, session numbers) resolve from project conventions.
- The plan states its expected review cost (how many debates, how many checks) so the user can judge the ceremony before approving.

## Lesson sources

Generic locations this skill searches in step 2:

- `CLAUDE.md`, `docs/` manual and decision records
- previous plan documents and their gate reports
- declared-divergence / known-issues registries

A specialized skill pack or a project may define richer lesson-source and
checklist conventions of its own; when such a skill governs the task, follow
its conventions — this generic skill neither names nor depends on any of them.
