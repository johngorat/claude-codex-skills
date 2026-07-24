# UE→Cocos Port Pipeline v2 — approved architecture

Design authority for generalizing the pack beyond FX to MATERIALS, MESHES,
ANIMATIONS (and future families), with batch porting and a gated
self-improvement loop. Debated adversarially with codex (GPT-5.6 Sol, xhigh):
gate 1 = 5 rounds / ~45 findings incorporated; gate 2 = final consolidated
verdict (record at the bottom). Implementation happens as separate gated
deliverables per section; THIS document is what they implement.

## 1. Pipeline generalization — family profiles

The stage shape and review tiers are family-invariant: harvest (check) → value
authority + anchors (debate) → implementation + runtime probe (debate) →
production wiring (check). Each asset FAMILY ships a **profile**:

- **dump set** — what the harvest must capture, with **transitive semantic
  closure**: every referenced external function / material function / curve /
  skeleton is itself dumped; the family validator fails on unresolved external
  references. Reference kinds are classified (strong dependency vs editor-only,
  e.g. preview meshes) — only strong references enter the gating DAG.
- **kind vocabulary** — namespaced anchor kinds (`family.kind`) validated
  against the pack's machine-readable kind registry (unknown family or kind =
  FAIL); units and tolerance conventions live in the registry.
- **derive helpers** — scripts that extract derivation values (matrices, curve
  keys, mode fields) directly from dumps wherever machine-readable; a value the
  script cannot extract is flagged `transcribed:true` in its anchor and becomes
  a mandatory reviewer-focus item. Hands never copy numbers machines can copy.
- **probe recipe** — what the runtime harness samples per kind (registry
  pattern: builtin kinds non-overridable).
- **golden fixtures** — see §2.

Family specifics pinned by this design (details go to each profile's own gate):

- **Materials**: static binding anchors (uniforms, pass states, texture
  bindings) PLUS mandatory `render_sample` anchors for any material with
  non-trivial graph math — numeric rgba readback at profile-MANDATED UV points
  (deterministic grid + branch-aware points computed from the decoded graph;
  never author-chosen).
- **Meshes**: canonical stream digests (positions/normals/UVs/tangents/indices,
  deterministic quantization) with per-VERTEX influence digests (bone indices +
  quantized weights in vertex order); winding via signed volume; digest
  canonicalization tolerant to importer vertex reordering is a profile work
  item.
- **Animations**: sampling set = all key times ∪ midpoint of EVERY key interval
  per track; bone transforms compared in a DECLARED space with quaternion
  double-cover normalization; root motion asserted separately as accumulated
  deltas; cubic-tangent parity via script-extracted tangent comparison (profile
  work item); track-type closure — every track type present (morph, attribute,
  notify, material curves) is ported, DD'd, or blocks: no third state.
- **Loops**: `loop.mode: resetting | accumulating`, script-derived from dump
  fields, never author-declared. Resetting loops keep the raw per-group seam
  rules; accumulating loops assert seam continuity (end pose composed with the
  accumulated transform vs start pose, finite-difference velocity, explicit
  tolerances — executable definition in the anims profile).

Out of scope: blueprint/gameplay logic (parity-dossier track), sound/UI until a
profile is designed.

## 2. The independent oracle — family certification

Lesson: self-consistent anchors cannot catch spec-derivation errors (the
YIQ-vs-HSV class). The oracle must come from OUTSIDE the derivation:

- Each family ships **golden fixtures**: small reference UE assets whose
  expected outputs are **captured from UE runtime execution** (materials:
  rendered readback values under pinned states; animations: UE-sampled bone
  poses over the grid; meshes: UE-exported reference stream digests).
- **Coverage matrix**: the profile enumerates supported source features,
  grounded in SOURCE-SIDE introspection, not in our dump schema (which would be
  circular): the dumper enumerates every node/property/track type present in an
  asset via UE reflection AND fails closed on any serialized class or section
  outside its modeled set; custom-serialized/bulk data it cannot model is
  covered by raw content hashing so its silent variation is detectable even
  when not interpretable — and in a PORT such opaque sections are gated like
  any unmodeled feature: DD or block (no third state), unless the profile
  carries a USER-approved classification of that section as non-semantic, with
  rationale. STATED LIMITATION: exhaustiveness is bounded by what
  UE serialization exposes — the residual (native-side semantics invisible to
  serialization) is an accepted, documented risk whose mitigation is the
  per-port UE-capture escalation, not a false claim of completeness.
  Certification REQUIRES every supported feature exercised by ≥1 fixture
  (machine-checked feature×fixture matrix), PLUS pairwise interaction fixtures
  for every feature pair the profile DECLARES interacting (blend modes ×
  colorspace, skinning × morph, …); full combinatorial coverage is explicitly
  NOT claimed — undeclared interactions found later become blocking additions
  to the declared-interaction list via the lessons commit, and their fixtures
  are N-ARY: the fixture is the minimal failing set itself, whatever its arity
  — the pairwise default is a floor, not a ceiling. Feature granularity
  includes semantic discriminators, not just node types (profile work item).
  Features outside the matrix are NOT CERTIFIED: a port touching one must DD it
  or block.
- **Certification identity = the family pack closure hash**: a content hash
  over everything that can change what the oracle means — the profile document,
  dump schema version, every fixture's bytes AND captured expectations, derive
  helpers, kind registry, importer/pack scripts, probe harness, target identity
  (Cocos engine version, render backend) **and source identity (the UE
  build/plugins/capture pipeline that produced the fixture expectations)**. Any
  component change invalidates certification automatically; validate/compare
  surface "stale certification". Nothing semantic sits outside the hash.
- **Executed-code identity** inside that closure is computed by transitively
  walking imports from the entrypoints (never a hand-list, never a git sha —
  dirty worktrees lie). A dynamic/unresolvable import fails closed. **The execution closure covers everything the tools read OR execute: non-import
  data dependencies (LUTs, config files, data tables), environment variables,
  command-line invocation templates, the interpreter/runtime identities
  (python/node versions and binary hashes), and every subprocess invocation
  (declared, with its own binary identity). Reading or executing anything
  absent from the manifest fails closed.**
- **Oracle independence is structural**: the UE-side capture pipeline and the
  Cocos-side comparator/derivation MUST NOT share conversion code, constants
  tables, or authored expectation logic — the only shared artifact is the
  fixture expectation FILE format. A shared library between the two sides is a
  certification-invalidating finding: an oracle that reuses the derivation's
  math cannot catch the derivation's mistakes.
- **Per-port identity pinning**: every port run asserts that its harvest
  environment matches the active certification's SOURCE identity and its probe
  environment matches the certification's TARGET identity — a mismatch is a
  stale-certification block, not a warning. Fixtures certify a specific pair of
  worlds; ports run only inside that pair.
- Per-port UE capture remains available as escalation for contested values.

## 3. Contract v1.1

anchors contract changes, backward-readable (v1 files imply the `fx` family):

- namespaced kinds `family.kind`, validated against the kind registry;
- anchors files record `kindRegistrySha` — validate/compare fail on mismatch
  (same discipline as `--approved-sha`);
- `loop.mode` as in §1; `subject` accepted as alias of `fx`;
- everything else (three addresses, sha-bound runtime files, DD entries,
  GATED/UNGATED, no-tweak) carries over unchanged.

## 4. Batch porting

- ONE harvest session dumps all batch entities (amortizes editor boot); dump
  commands are per-entity — an entity that crashes the session is EJECTED, the
  session restarts and continues; the shared check-gate consumes per-entity
  artifacts and reports per-entity verdicts.
- **Dependency DAG** built from classified harvest references; cycle detection
  at batch planning (editor-only refs excluded; a genuine strong-dep cycle
  blocks with an explicit report). Gates run in topological order; each
  entity's Stage-3 records its dependencies' approved shas; re-gating a
  dependency invalidates dependents via the sha chain. "Per-entity
  independence" applies to siblings without edges only.
- Stage-2/3 are per-entity gates, sequenced (bounded diffs, independent
  failure). Batch size cap: 5.
- **Registry dedup**: identity = hash tuple (source dump sha, conversion
  profile version, exporter/engine versions, per-use conversion options,
  dependency identity hashes, executed-code closure hash, target identity,
  **and the family certification closure hash under which the asset was
  approved**) + approval state. Any component mismatch — including a
  certification change — means a different asset: re-port or re-approve.
- Stage-4: ONE main build measures all batch entities (economy rule), with
  per-entity probe verdicts and ejection. On an aggregate failure BEFORE
  per-entity verdicts: **terminating isolation** — build each entity's wiring
  alone (≤5 builds); all-singles-pass ⇒ interaction defect: search pairs.
  EVERY reproduced failing set — single, pair, or n-ary — becomes a BLOCKING
  interaction record (never mere ejection). Records are rows in the asset
  REGISTRY (the one global store). Their member identity is the STABLE source
  identity: the source dump CONTENT sha lineage alone — content-derived, so a
  rename or move neither detaches a record nor evades one (the same content
  under a new path matches; genuinely changed content is a new lineage entry
  linked to its predecessor by the registry's lineage chain). The asset path is
  recorded as a display label only. Never the full versioned registry tuple: a recertification, importer update, or code-closure change
  does NOT detach a record; nothing resolves a record except regression
  evidence (the recorded combination co-wired and passing in a post-fix
  isolation build). Matching is SUBSET-CONTAINMENT: any candidate co-wiring
  whose member set CONTAINS a recorded set is blocked — {A,B} recorded blocks
  {A,B}, {A,B,C}, and every other superset; sets not containing a recorded set
  are unaffected. EXEMPTION BY CONSTRUCTION: a RESOLUTION BUILD — an isolation
  build explicitly labeled as attempting to resolve one named record, running
  exactly that record's member set, gating nothing and releasing nothing — is
  exempt from the block; it is the only exemption, and its only possible
  outcomes are "record resolved with evidence" or "record stands". Records are
  consulted at two mandatory points: batch planning and Stage-4 wiring
  assembly.
  If no pair reproduces it (3+-way interaction), the full failing member set is
  recorded as a blocking record and the batch splits in half into independent
  batches (splits only produce permitted subsets — the recorded set itself is
  blocked). **After ANY ejection or record, Stage-4 re-runs on the surviving set, defined
  explicitly**: survivors = the batch minus every entity implicated in an
  unresolved record of the current attempt, run TOGETHER (e.g. A+B recorded ⇒
  C,D,E re-run as one build; A and B may each proceed solo afterwards — solo is
  a permitted subset). Survivors are never released on the strength of a run
  that included an ejected member. Termination: each re-run's set is a strict
  subset of the previous run's, and the batch cap (5) bounds total builds.

## 5. Self-improvement loop (gated)

- Closing any port REQUIRES the lessons commit: new finding classes appended
  to the precheck OR an explicit "no new classes" attestation naming what was
  checked; reusable tooling promoted OR attested absent; a scorecard event
  appended to the ledger unconditionally. A clean port has a truthful closing
  path — the requirement is the attestation, not the invention of findings.
- **Precheck lifecycle**: items carry family tags and a `mechanized` field.
  Mechanization DELETES the manual item only with **regression-fixture
  evidence** — the historical failing case added to the replacing validator's
  fixture suite, demonstrated to FAIL when the defect is present.
  `severity:critical` items are exempt from the cap and retire only by USER
  decision. The active-manual-item cap (25) counts only `mechanizable`-pending
  items — pressure to mechanize, never to delete rare high-severity review.
- **Ledger** (`scorecards.jsonl`, versioned schema): append-only EVENTS — a
  port-closure event plus amendment events (late-found defects attribute back
  via portId with discovery timestamps). Trends computed at fixed observation
  windows (defects@7d/@30d); normalization uses EXOGENOUS denominators only
  (dump bytes, node/track/emitter counts from dumps); authored counts recorded
  but non-normative. Batches attribute per-entity rows.
- **Meta-review** every 10 closed entity-gates OR 30 days, whichever first: the
  ledger + precheck deltas go to a codex debate asking what in the PIPELINE
  should change; accepted changes are implemented as normal gated skill edits.
  Self-improvement never edits skills without a gate.

## Gate record — honest status

Three adversarial design gates (GPT-5.6 Sol, xhigh), 15 rounds total, ~74
findings incorporated into this document. Formal APPROVED was NOT reached: each
full re-read of the grown document produced a fresh finding layer (12 → … → 2 →
7), demonstrating that the review surface of a prose architecture is unbounded
— unlike executable artifacts, which converged under the same reviewer (the
anchors script reached full-diff APPROVED). Status by decision: this document
is the DESIGN AUTHORITY; every outstanding finding below is carried as a
MANDATORY work item into the implementation gate of the section it names,
where concrete artifacts make review finite.

## Outstanding findings ledger (binding on implementation gates)

1. §4 Stage-4: survivor definition must remove ejected entities explicitly;
   ejection and record-implication are distinct removal reasons.
2. §4 Stage-4: isolation must also trigger on cross-entity contamination where
   one entity's fault surfaces as another's probe failure (context-dependent
   failures escape aggregate-failure triggering).
3. §4 Stage-4: when singles and pairs pass, bounded search for the minimal
   3+-way culprit subset before recording the whole batch (wrong-granularity
   records over-block).
4. §4/§5 registry: changed-content lineage needs a machine-grounded predecessor
   link (immutable fact tying new content sha to old), not an assertion.
5. §4 records: resolution scope — one passing resolution build proves one
   configuration; define what configuration class a resolution covers.
6. §2 closure: execution-world identity beyond engine+backend+interpreter
   hashes (OS/driver class) — decide inclusion or document as accepted risk.
7. §2 fixtures: capture provenance — evidence binding expectations to the
   asserted source identity capture run (capture-run manifest, hashed).
