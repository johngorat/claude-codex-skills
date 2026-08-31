# Builder mode (fixes only)

Trigger: the invocation names a builder model — a leading bare token
(`/codex-check opus <context>`; recognized: `opus`, `sonnet`, `haiku`) or
`builder=<model>` anywhere in the arguments. A leading token counts as a
model only when context text follows it; when that reading is in doubt, ask
one button question. Both syntaxes accept ONLY the recognized models: an
unrecognized `builder=` value never dispatches and never drops to the
default path silently — one button question (dispatch to it anyway / pick a
recognized model / run without a builder). With no builder model named at
all, nothing in this file
applies and SKILL.md runs exactly as written.

Nothing changes before the review. This skill reviews an EXISTING diff, so
the builder builds nothing up front: the session runs the review round
exactly as SKILL.md prescribes and triages the findings itself. Only the
FIXES for findings judged REAL are dispatched — ONE builder agent on the
named model, in the same working tree, handed the finding text, the paths
and the local suites the session names for this change. Triage, rebuttals
and the escalation call are never handed over; the builder never invokes
codex.

Attestation: the builder's reply ends with the same completion report
codex-plan/BUILDER.md defines (progress replies may carry the same object
with `"done": false`, or none at all):

```json
{"stage": "fixes", "builder": "<model>", "files_touched": ["..."],
 "suites": [{"cmd": "<canonical command>", "result": "pass"}],
 "divergences": ["..."], "assumptions_made": ["..."], "done": true}
```

`suites` is checked against the CANONICAL list — the suites THE SESSION
named, no substitutes. `done: true` is the fixes-complete attestation and
nothing else. The session verifies that mechanically (report present, every
named suite `"pass"`, `done` true) before treating the fixes as done; any
miss returns them to the same builder agent. The final report carries
`builder=<model>` and quotes the builder's `divergences` lines verbatim,
never smoothed.

Escalation is unchanged: a `blocker`/`major` the session cannot resolve
still stops the work and recommends `/codex-debate`.

No agent dispatch available: same contract by handoff — hand the finding
list, the paths and the named suites to a separate session on the builder
model; the review round and all triage stay here.
