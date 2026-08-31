# Builder mode (one-stage planner/builder split)

Trigger: the invocation names a builder model — a leading bare token
(`/codex-plan-fast opus <task>`; recognized: `opus`, `sonnet`, `haiku`) or
`builder=<model>` anywhere in the arguments. A leading token counts as a
model only when task text follows it; when that reading is in doubt, ask
one button question. Both syntaxes accept ONLY the recognized models: an
unrecognized `builder=` value never dispatches and never drops to the
default path silently — one button question (dispatch to it anyway / pick a
recognized model / run without a builder). With no builder model named at
all, nothing in this file
applies and SKILL.md runs exactly as written.

Division of labor (hard): the PLANNER (the invoking session) keeps the fit
gate, the micro-plan, the single /codex-check gate, finding triage,
rebuttals, escalation and the report; the BUILDER (one dispatched agent on
the named model, same working tree) executes the micro-plan's steps and
runs the local suites it names, never invokes codex and never judges a
finding.

1. Post the micro-plan as SKILL.md prescribes, then dispatch ONE builder
   agent with the model override, handing it the micro-plan verbatim
   (steps, tools-by-path, named suites, inline constraints) plus the
   report contract below. Keep that agent for the whole task.
2. Claiming review-readiness ends the builder's reply with the same
   completion report codex-plan/BUILDER.md defines (progress replies may
   carry the same object with `"done": false`, or none at all):

   ```json
   {"stage": "micro-plan", "builder": "<model>",
    "files_touched": ["..."],
    "suites": [{"cmd": "<canonical command>", "result": "pass"}],
    "divergences": ["..."], "assumptions_made": ["..."], "done": true}
   ```

   `done: true` is the review-ready attestation and nothing else.
3. GATE PRECONDITION (mechanical, not judged): `suites` is compared against
   the CANONICAL list — the suites the MICRO-PLAN named, no substitutes —
   every one present with `"pass"`, and `done` true. Any miss (absent
   report, missing or failing suite, `done: false`) returns the work to the
   builder; the check is never launched on an unproven diff.
4. Fix cycles after the check go to the SAME builder agent; the micro-plan's
   suites re-green (a fresh report clearing the precondition again) before
   the single re-check.
5. The report carries `builder=<model>` and quotes the builder's
   `divergences` lines verbatim, never smoothed.

No agent dispatch available: same contract by handoff — hand the micro-plan
plus a kickoff prompt naming this file to a separate session on the builder
model; the single check stays with a planner-model session.
