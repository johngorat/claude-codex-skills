# Builder mode (planner/builder split)

Trigger: the invocation names a builder model — a leading bare token
(`/codex-plan opus <task>`; recognized: `opus`, `sonnet`, `haiku`) or
`builder=<model>` anywhere in the arguments. A leading token counts as a
model only when task text follows it; when that reading is in doubt, ask
one button question. Both syntaxes accept ONLY the recognized models: an
unrecognized `builder=` value never dispatches and never drops to the
default path silently — one button question (dispatch to it anyway / pick a
recognized model / run without a builder). With no builder model named at
all, nothing in this file
applies and SKILL.md runs exactly as written.

## Division of labor (hard)

- The PLANNER (the invoking session) keeps everything that requires
  judgment: the plan itself, every gate (via the /codex-check and
  /codex-debate skills), finding triage, rebuttals, escalation, and the
  scorecard.
- The BUILDER (a dispatched agent running the named model, in the same
  working tree) writes code and runs the local suites. The builder never
  invokes codex and never judges review findings.

Expectation to state in the plan: gates bill the same reviewer models as
always — the saving is on execution tokens; a weaker builder typically
costs one or two extra fix cycles per gate, and Builder notes exist to
absorb exactly that.

## Per implementation stage

1. While drafting the plan, add **Builder notes** to each implementation
   stage: exact commands and paths, the attestation checklist to walk,
   and the expected finding classes marked fix-on-sight vs
   rebut-with-this-evidence. Written for a builder weaker than the
   planner.
2. Dispatch ONE builder agent per stage with the model override, handing
   it the plan document path, the stage brief, the Builder notes, and the
   completion-report contract below. Keep that same agent through the
   stage's fix cycles (a continued conversation keeps its context).
3. Whenever the builder claims a stage or a fix cycle is READY FOR
   REVIEW, its reply ends with the completion report (progress replies
   may carry the same object with `"done": false`, or none at all):

   ```json
   {"stage": "<stage id from the plan>", "builder": "<model>",
    "files_touched": ["..."],
    "suites": [{"cmd": "<canonical command>", "result": "pass"}],
    "divergences": ["..."], "assumptions_made": ["..."], "done": true}
   ```

   `done: true` is the review-ready attestation and nothing else.
4. GATE PRECONDITION (mechanical, not judged): the planner parses the
   report and compares `suites` against the CANONICAL suite list the
   plan/Builder notes name for that stage — every canonical command must
   appear, each with `"pass"`; `done` must be true and `stage` must
   identify the stage under review. Any miss — absent report, missing or
   extra-failing suite, `done: false` — returns the stage to the builder;
   a gate is never launched on an unproven diff.
5. Findings: the planner judges each one; fixes go back to the same
   builder agent; suites re-green (a fresh completion report) before any
   re-review round.
6. The stage report and the final scorecard carry `builder=<model>`, and
   the builder's `divergences` lines are quoted verbatim, never smoothed.

## No agent dispatch available

Same contract by handoff: commit the plan plus a kickoff prompt naming
this file; the user opens a separate session on the builder model and
runs the kickoff there; gates still belong to a planner-model session.
