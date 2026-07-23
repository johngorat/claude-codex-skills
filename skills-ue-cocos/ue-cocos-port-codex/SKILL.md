---
name: ue-cocos-port-codex
description: Staged, gate-reviewed pipeline for porting a UE Niagara FX to Cocos — harvest, value authority with anchors, implementation with a runtime probe, production wiring; review tiers per stage, pre-gate checklist attestation, numeric render truth. Use when the user asks to port an FX / Niagara system from UE to Cocos, or to plan such a port.
---

# UE→Cocos FX Port (pipeline orchestrator)

The porting specialization of the generic `codex-plan` / `codex-debate` /
`codex-check` family. The generic skills stay project-agnostic on purpose; this
skill supplies everything porting-specific and OWNS the pack's conventions.
Companion: `ue-cocos-anchors-codex` (the anchor contract; read it before
Stage 2).

`/ue-cocos-port-codex <NS_system name> [context: where it plays, one-shot vs
looping, attachment]` — the entry flow, in order: (1) draft the staged plan
(codex-plan procedure: no pre-interview, decision points ship WITH the plan,
expected review cost stated); (2) run the Stage-0 `codex-check` on the plan doc
and fold its findings in; (3) present the checked plan for USER approval;
(4) only then execute stages 1–4. The Stage-0 check comes BEFORE approval — the
user approves a reviewed plan, not a draft.

## Conventions this pack owns

- **`docs/CODEX-LESSONS.md`** — the project's index of lesson sources and local
  check commands. Read FIRST when planning; every plan requirement traces to an
  entry there, a past gate finding, or a dump. The local check commands/skills
  it names are BINDING throughout this pipeline: they must be green before
  round 1 of every debate gate and re-run after fixes — this pack is the
  "specialized skill naming specific checks" that the generic codex-debate
  step 2 defers to.
- **`docs/FX-GATE-PRECHECK.md`** — the pre-gate checklist. Walking it and
  writing the attestation block into the round-1 prompt is MANDATORY for every
  Stage-2/Stage-3 debate gate of this pipeline (this is the checklist the
  generic codex-debate attestation hook refers to). When a debate closes with a
  new recurring finding class, appending it to the checklist is part of closing
  that debate.
- **`fx_<name>_<sid>.ue-cocos-anchors-codex.json`** (+ its bound `.runtime.json`)
  next to the value authority — the anchor contract files.

## Pipeline and default review tiers

| Stage | Work | Tier |
|---|---|---|
| 0 | Plan doc (`docs/design/fx_<name>_plan.md`) via the codex-plan procedure, lesson sources folded in | `codex-check` |
| 1 | Harvest: gated dumper, validator inheriting the hardened checks, enum library before fresh dumps | `codex-check`; a dumper EXTENSION is infrastructure → its diff alone gets a full `codex-debate` gate |
| 2 | Value authority (`docs/design/mechanics/fx_<name>_values_<sid>.md`) extending the template — never forking it — plus the anchors file authored at translation time (`target` = the translation decision as data); `validate --harvest-root` VALID, table GENERATED + `render --check` CURRENT | full `codex-debate`, top model; the gate report RECORDS the approved anchors sha256 |
| 3 | Implementation + runtime probe, ONE combined gate (impl-vs-spec AND probe-vs-spec). Probe reads the anchors file, emits the bound runtime file; `compare --approved-sha <recorded sha>` → GATED, zero unexplained FAILs; determinism A/B per the project manual. The FIRST version of the probe is itself infrastructure → its own debate gate | full `codex-debate`; focus the review prompt on lifecycle, attachment, and timing — NOT on material math already gated in earlier ports |
| 4 | Production wiring | `codex-check` |

Escalation everywhere: a check leaving a `blocker`/`major` standing upgrades
that stage to a debate.

## Effect-type notes (set these in the plan)

- **One-shot** (hit, level-up class): anchors at lifetime fractions; NO `loop`
  block in the anchors file — the per-emitter seam rules switch off with it.
- **Looping** (aura class): `loop.periodSec` declared; per-emitter seam anchors
  on both sides are mandatory (the script enforces this — do not argue it in
  prose).
- **Attached to a unit**: location-readiness law applies (never sample an
  unready node at engine defaults); record the DelayedStartComponent-vs-
  pooled-ephemera bucket decision with rationale — persistent attached effects
  fit neither bucket obviously.

## Hard rules (restated from the project's law, binding here)

- **Image-analysis verdicts are banned.** Rendered output is verified
  numerically through the anchor contract; the USER's eye is the final
  acceptance and the only visual judge.
- **No-tweak:** a comparator FAIL is closed by a value-chain trace to the UE
  source (fixing the Cocos side on the strength of a proven trace is correct),
  or by a USER-approved DD entry — never by adjusting values, expectations, or
  tolerances to make the check pass.
- Gates are executed by INVOKING `codex-debate` / `codex-check` — `codex
  review` / ad-hoc CLI calls are not gates.

## Report

The codex-plan scorecard is mandatory: per gate — tier, model, rounds,
wall-clock, findings fixed/rebutted; totals — input tokens from the rotated
events logs, findings caught by attestation/validators vs by the reviewer,
user-found issues after gates. Append it to the project's session record, and
append any recurring finding class to `docs/FX-GATE-PRECHECK.md`.
