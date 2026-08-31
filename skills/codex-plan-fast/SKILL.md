---
name: codex-plan-fast
description: Fast lane of /codex-plan — micro-plan posted and executed in the same turn, ONE codex-check gate at the end. Use for small or mid-size tasks on proven rails (existing gated tools, templates, patterns), or when the user asks for a fast/quick build and the fit gate passes; a task that fails the fit gate is handed to /codex-plan unstarted.
---

# Codex Plan Fast (same-turn lane)

`/codex-plan-fast <task>` — the staged-plan discipline compressed for tasks
where full staging costs more than it protects: the plan shrinks to a
micro-plan in the reply, approval-by-interruption replaces the approval
round, and review shrinks to one check.

A leading bare model token (`/codex-plan-fast opus <task>`) or
`builder=<model>` selects BUILDER MODE per [BUILDER.md](BUILDER.md): the
builder executes the micro-plan, the planner keeps the fit gate, the check
and all judgment. With no model named, nothing changes.

## 1. Fit gate (decide the lane FIRST)

Fast fits when EVERY line holds:

- the work rides PROVEN RAILS — gated tools and already-reviewed patterns,
  each named by path in the micro-plan;
- the blast radius is the diff itself: glue, extensions of gated tools,
  docs, config, tests. Installers, validators, self-checks, first-of-kind
  infrastructure and destructive migrations are debate-tier ground
  (historically 5–13 majors each) and belong to /codex-plan;
- one review check plausibly covers it (as a guide: under ~300 changed
  lines).

Any miss → one sentence naming the failed line, then hand the task to
/codex-plan. State the fit verdict in the reply either way.

## 2. Micro-plan (same message, then GO)

At most 6 numbered steps with concrete file paths, the tools reused (by
path), and ONE success criterion: which local suites must be green and
that the check comes back clean. Convert the lessons the touched files and
project conventions point at into inline constraints — the ones relevant
to THIS diff, not an archive sweep.

Post the micro-plan and START EXECUTING IN THE SAME TURN — the user
interrupts rather than approves. One exception: a LOAD-BEARING decision
(policy trade-off, or a choice costly to migrate later) blocks on a
button question first; everything cosmetic becomes a stated assumption,
cheap to change later.

## 3. Execute

Run the micro-plan; local checks green before any review — a diff known
broken is never sent. New ground discovered mid-task re-runs the fit
gate: the fast lane demotes itself to /codex-plan out loud, never
silently widens.

## 4. One gate

Invoke the /codex-check skill on the final diff — its full protocol
(launcher script, model resolution, channel and cost guard), never an
ad-hoc codex call. Judge every finding: fix the real ones, rebut false
ones with evidence. When anything changed, re-run the micro-plan's local
suites (green again before any resubmission) and re-check once. A major still standing after that → STOP and recommend
/codex-debate; the fast lane never absorbs an unresolved major.

## 5. Report (one paragraph)

What shipped (paths), which suites ran, and the scorecard line: reviewer
model, auth channel, rounds, findings fixed/rebutted, token totals (the
check skill's round-report.sh over its run dir). Divergences from the
micro-plan are named, not smoothed over.
