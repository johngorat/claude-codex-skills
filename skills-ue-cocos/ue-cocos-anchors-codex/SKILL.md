---
name: ue-cocos-anchors-codex
description: Anchor contract for UE→Cocos FX ports — machine-readable anchors.json binding every ported value to its UE dump source and its Cocos runtime target, validated and compared by script instead of eyes. Use during Stage-2 (value authority authoring) and Stage-3 (implementation gate) of a UE→Cocos effect port, or whenever rendered output must be verified numerically without visual verdicts.
---

# UE→Cocos Anchors (numeric render-truth contract)

## Why this exists

Visual comparison by the agent is banned in UE→Cocos port work: model verdicts on
"does it look the same" are unreliable, and they invite param-tweaking to make
things look right. This skill replaces eyes with numbers: the UE side is already
script-harvested; the anchor contract makes the Cocos side symmetric — dump the
running effect, compare numbers to numbers. The USER's eye remains the final
acceptance; the agent never issues visual verdicts.

## The contract

One file per FX, next to the value authority, named
`fx_<name>_<sessionId>.ue-cocos-anchors-codex.json` (schema:
`ue-cocos-anchors-codex.schema.json`; executable authority:
`scripts/ue-cocos-anchors-codex.py validate`). Every anchor carries three addresses:

- **`id`** — canonical join key, derived deterministically from UE names
  (`<emitter>.<module|material>.<param>[.<atTag>]`). The comparator joins on it;
  nobody ever matches names by similarity.
- **`source`** — where the expected value comes from in the UE dumps (file +
  path + chain ref). Every FAIL is traced through this address.
- **`target`** — what the Cocos-side probe samples (kind + node + space/field).
  Written at Stage-2, at the moment the UE→Cocos translation decision is made —
  never inferred later.

Plus `at` (cycleTime or deterministic tick), `expected`, `tolerance`
(abs/rel for numbers, exact for strings/bools), `units`, and optionally
`dd: {"id": "DD-n", "approvedBy": "USER"}` — the ONLY legitimate representation
of a deliberate divergence (compare reports it as DD, never as PASS or FAIL).

Hard rules the validator enforces beyond structure: NaN/Infinity rejected
everywhere; bool is never a number; spatial kinds require `space`;
field-addressed kinds (`material_uniform`, `pass_state`, `texture_binding`)
require `field`; two anchors may not share a (node, kind, field, space, at)
address; declared loops must have cycleTime anchors observing BOTH sides of the
seam (one in the first quarter, one in the last quarter of the period).

**Binding.** The runtime file must carry `fx`, `sessionId`, and `anchorsSha256`
(sha256 of the anchors file bytes) matching the anchors file — the comparator
refuses stale or foreign probe output.

**Where enforcement lives — stated plainly.** The script makes every check
mechanical once given its inputs, but two authorities are procedural by nature
and no script can replace them: (1) the VALUE of `--approved-sha` — its
authority is the Stage-2 gate report; the Stage-3 reviewer verifies the flag
value against that record (a self-computed sha proves binding, not approval);
(2) `source.path` correctness INSIDE a dump file — format-specific, verified by
the Stage-2 review against the harvest; the script verifies the file exists and
cannot be escaped via absolute or `../` paths.

**Immutability after approval.** The Stage-2 gate report RECORDS the approved
anchors file's sha256 (the same value the runtime binding uses). At Stage-3 the
sha of the anchors file in use must equal the recorded one; any mismatch means
`expected`/`tolerance`/`dd` changed after approval — Stage-2 re-opens for the
changed anchors before Stage-3 may proceed. This makes immutability checkable
even on uncommitted working trees.

**Coverage — what is and is not guaranteed.** The script guarantees
"everything anchored is verified"; it CANNOT guarantee "everything is anchored"
— it has no knowledge of the full set of ported values. That completeness is
contract item #1 for the Stage-2 adversarial review: the reviewer checks the
generated authority against the harvest dumps and hunts omissions (the finding
class it already catches reliably). `validate --harvest-root <dir>` verifies
every `source.file` actually exists in the harvest, and per-emitter counts
expose thin spots — evidence FOR that review, not a substitute.

## Workflow

### Stage-2 (value authority authoring)

1. While translating each UE value, add its anchor record — the `target` field
   IS the translation decision, recorded as data.
2. `python3 "<skill dir>/scripts/ue-cocos-anchors-codex.py" validate <anchors.json> --harvest-root <harvest dir>` —
   must be VALID before the Stage-2 review round 1 (unique ids, tolerance types,
   loop-seam coverage from both sides, no bool-as-number, no NaN/Infinity, every
   source.file present in the harvest).
3. The human-readable anchor table in the value authority document is
   **generated**: `... render <anchors.json> -o <section file>` — never written
   or edited by hand. The generated header embeds the anchors sha256;
   `... render <anchors.json> --check <section file>` verifies the table is
   CURRENT — a stale table (generated, then anchors edited) is a gate finding.
   Run the `--check` as part of the Stage-2 attestation.

### Stage-3 (implementation gate)

4. The project's runtime probe reads the anchors file, walks the `target`
   addresses at the `at` times, and emits
   `fx_<name>_<sessionId>.ue-cocos-anchors-codex.runtime.json`
   (`contract: "ue-cocos-anchors-codex-runtime/v1"`, plus the binding fields
   `fx`, `sessionId`, `anchorsSha256`, and
   `samples: [{id, actual} | {id, error}]`).
   Probe contract: an anchor it cannot sample is emitted as an `error` entry —
   silent skips do not exist. Spatial samples from Local-space buffers must be
   transformed through the node's world matrix before being reported.
5. `... compare <anchors.json> <runtime.json> --approved-sha <sha from the
   Stage-2 gate report>` — the gate criterion. Exit 0 = every anchor PASS.
   Unsampled anchors (DD included), probe errors, DD samples without `actual`,
   duplicate or unknown ids are FAILs by definition. Without `--approved-sha`
   the summary line says UNGATED — a Stage-3 gate must show GATED output.

### Resolving FAILs — the no-tweak rule

A FAIL is resolved in exactly one of two ways:

- **Trace the chain**: follow the anchor's `source` address into the UE dump,
  find which value/formula/branch diverges, fix the data or the implementation
  from the evidence.
- **Declared divergence**: if the deviation is deliberate, record a DD entry and
  get USER approval.

Adjusting Cocos-side params, tolerances, or expected values to make a check pass
is falsifying the test — same severity as the visual-verdict ban.

## Success criteria (per FX)

- Anchor coverage 100%: every anchor has both expected and sampled actual
  (DD anchors included — a divergence is approved, not unsampled); no unpaired
  ids on either side; loop seam observed from both sides.
- Stage-3 ran against the exact anchors file Stage-2 approved (sha match).
- Comparator: zero unexplained FAILs — each one closed by source-trace fix or
  USER-approved DD.
- Zero tweak-fixes: every FAIL resolution references a source address or a DD.
- After the USER's final visual acceptance: 0 major findings by eye.

## Division of labor

- This skill owns: the schema, the validator/comparator/renderer script, the
  file naming, the rules above.
- The project owns: the runtime probe (engine-specific — it knows how to read
  particle buffers, material uniforms, pass states) and the per-FX anchor files.
  The probe is infrastructure: its first version goes through a full
  `/codex-debate` gate.
