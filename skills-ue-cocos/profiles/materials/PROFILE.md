# Materials family profile (PORT-V2 phase 2, B2)

Family profile for porting standalone UE materials/material instances to
Cocos, per PORT-V2-DESIGN §1 (family profiles) and §2 (independent oracle).
The executable authorities are the pack's derive helpers (`scripts/`) and the
anchors/certification toolchain; this document binds them together.

## 1. Dump set (harvest contract, transitive semantic closure)

For every ported material the harvest MUST capture, per entity:

| Dump | Harvester command | Covers |
|---|---|---|
| `<name>.matinfo_<sid>.json` | `get_material_info` | base properties **including `material_domain`** (a dumper extension where absent — the probe renders a SURFACE material, so post-process/UI/decal/volume domains must be visible to block), scalar/vector/texture/switch parameters (with instance override truth: `value`/`default_value`/`overridden`) |
| `<name>.graph2_<sid>.json` | `get_material_graph` | master graph: `expressions[]`, `connections[]`, `output_pins{}` |
| enum dumps | `get_enum_info` | every enum-valued selector encountered |

**Transitive closure (strong references — each is itself dumped, unresolved
= harvest FAIL):**
- the FULL parent chain of a material instance (`parent` / `parent_instance`
  fields) up to the master material — one matinfo per link, plus the
  master's graph2;
- every `MaterialExpressionMaterialFunctionCall` target in the graph — its
  function graph dump;
- **every reachable texture reference, not only parameters** — a
  `MaterialExpressionTextureSample`/`TextureObject` carrying a literal
  `Texture` property never appears in `texture_parameters`, so
  `derive-render-points.py` flags each one (machine-enforced, not prose) and
  it is subject to the SAME contract as a parameter texture: realized sampler
  artifact + `materials.texture_binding` anchor keyed by the FULL asset path
  (two textures may share a basename — the name alone is not an identity). A
  reachable texture node whose asset cannot be read is a blocking flag; any
  other unmodeled resource-reference class blocks too (no third state);
- every texture in `texture_parameters` — its realized sampler artifact
  `<texture>.samplerinfo_<sid>.json` with fields {textureGroup, filter,
  addressU, addressV, sRGB, mipGenSettings, lodBias}, measured for the
  texture's ACTUAL TextureGroup (never ini claims; a group with no recorded
  artifact → measure and record one first). Each consumed sampler state
  becomes a `materials.pass_state` anchor with field
  `sampler.<slot>.<state>` — interior grid points intentionally do NOT
  expose wrap/clamp differences, so sampler state is anchored directly;
- every `MaterialExpressionCustom` node's HLSL body (present in the graph2
  `props`) — decoded from the HLSL, never from the node's display name
  (the color-transform lesson: a "HueShift"-named node can be a YIQ matrix).

**Editor-only references (recorded, NOT in the gating closure):** preview
meshes, editor comments, node positions (`x`/`y`). NOTE: named-reroute
`desc` values are STRONG semantic inputs — they are the Usage→Declaration
bridge identifiers that reachability and mandated points depend on; only
free-text comments and display labels of other nodes are editor-only.

## 2. Kind vocabulary

`materials.*` in the pack kind registry (`ue-cocos-anchors-codex/
kind-registry.json`, gated edits only): `uniform`, `pass_state`,
`texture_binding`, `render_sample`. Anchors files use contract v1.1 with
`subject` naming the material.

Static binding anchors (`uniform`/`pass_state`/`texture_binding`) are
REQUIRED for every resolved parameter and base property the port consumes.
**Static switches are certified per OUTCOME:** `switch_true` and
`switch_false` are separate features, each interacting with `render_grid`, so
one true-branch fixture cannot certify a port that takes the false branch —
every used combination needs its own fixture variant (the derive helper flags
each reachable switch to that effect).
`render_sample` anchors are MANDATORY for any material whose graph contains
more than parameter-to-output plumbing (any of: Lerp/If/Custom/TexCoord
math/static-switch-dependent branches) — self-consistent static bindings
cannot catch spec-derivation errors.

## 3. Derive helpers (hands never copy numbers machines can copy)

- `scripts/derive-material-anchors.py <matinfo-root.json> [... <matinfo-leaf.json>]`
  — resolves the parameter set over the parent chain (leaf override wins only
  when `overridden` is true), emits anchor-ready values with their source
  addresses inside the dumps. Any value the helper cannot extract must be
  entered by hand with `"transcribed": true` in the anchor — a MANDATORY
  reviewer-focus item at the Stage-2 gate.
- `scripts/derive-sampler-anchors.py <texture.samplerinfo.json> <slotName>` —
  turns the realized sampler artifact (§1) into anchor-ready
  `materials.pass_state` values with fields `sampler.<slot>.<state>` (lodBias
  in `level` units); a missing or mistyped artifact field is flagged for hand
  transcription.
- `scripts/derive-render-points.py <graph2.json> [<functiongraph.json> …up to
  5]` — emits the MANDATED render_sample UV points (every reachable material
  function's graph must be passed; an unresolved target fails closed):
  - deterministic grid: 5×5 at u,v ∈ {0.1, 0.3, 0.5, 0.7, 0.9} (edges
    avoided: wrap/clamp sampler behavior is anchored via sampler-state
    anchors, §1);
  - **mip/LOD observation requirement (B3 fixtures):** every
    `sampler_mips_*` and `sampler_lodbias_*` variant is declared as
    interacting with `render_grid`, so its fixture MUST force minification —
    high-frequency texture content plus UV derivatives scaled so the grid
    readbacks land on a mip level that differs between variants. A nominal
    engine-API state anchor alone does not certify these variants: a target
    that reports the requested value and ignores it while sampling would
    otherwise pass;
  - branch-aware points: for every UV-driven `If` node with a statically
    readable literal threshold, a pair of points at threshold ± 0.05
    (clamped to [0.02, 0.98]) along BOTH axes (the compared axis is not
    statically determined); UV-driven `Lerp` is continuous and covered by
    the grid — it mandates no extra points;
  - flags: every `Custom` (HLSL) node, every UV-driven branch whose
    threshold is NOT statically readable, and every StaticSwitch reachable
    from the output — each flag is a mandatory reviewer-focus item and (for
    switches) a fixture-variant requirement at certification.
  Author-chosen sample points are a gate finding — the helper's output is
  the authority.

## 4. Probe recipe (project side; builtin kinds non-overridable)

**Profile v1 scope: MD_Surface + MSM_Unlit materials ONLY**, with
`dithered_lod_transition` DISABLED as the supported baseline and every
node-local sampling control (`SamplerSource`, `SamplerType`, `MipValueMode`,
view-mip-bias, const mip/coordinate) at its UE default — per-consumption
sampling state is a gated widening, so any override BLOCKS. Lit shading
models are OUT OF SCOPE — their render oracle would depend on
lighting/exposure/tonemapping state this profile does not pin — and enabled
dithered LOD is equally uncertified; a port touching either must BLOCK (the
derive helper flags both as blocking). These are documented limitations, not
silent gaps.

The probe's render state is PINNED: orthographic camera, unit quad exactly
filling the viewport, no scene lights, no post-processing/tone mapping,
readback in LINEAR space with straight (non-premultiplied) alpha, over a
**known NON-ZERO backdrop** — a fixed opaque mid-grey (0.25, 0.25, 0.25, 1)
cleared before the quad draws. A transparent-black backdrop is BANNED here:
with a zero destination, blend equations that differ only in their
destination factor (source-alpha translucent vs additive) produce identical
output, so a target implementing additive as translucent would pass the
oracle while reporting the requested pass state. Every blend discriminator is
therefore bound to `render_grid` in features.json and its fixture is read
back over this backdrop. Then:
- `materials.render_sample`: reads back rgba at each mandated UV point
  (`field` = point key `u<u>_v<v>` with 3 decimals) in LINEAR color space;
- `materials.uniform` / `pass_state` / `texture_binding`: reads the target
  material's effective state via engine API, never from authored source.

**Back-face observation (mandatory for the two-sided discriminators).** Each
fixture is read back TWICE: once with the quad facing the camera and once
rotated 180° about its vertical axis. The `two_sided_off` variant must show
the pure backdrop from behind (the material is culled); `two_sided_on` must
show the material. `render_backface` is a declared feature interacting with
both two-sided variants, so an engine-API state anchor alone cannot certify
them — a target that reports two-sided while always culling would otherwise
pass. Point keys from the back-facing pass carry a `back:` prefix.
The FIRST version of this probe is infrastructure → its own debate gate.

## 5. Features & certification

The machine-readable feature matrix lives in `features.json` (schema-closed;
consumed by `family-closure.py matrix`). Features are SEMANTIC
DISCRIMINATORS, not generic property names: each supported blend mode and
two-sided state is its own feature — a fixture exercising
`blend_translucent` certifies nothing about `blend_masked_clip`. Golden
fixtures with UE-captured expectations, the capture-run manifest (design
ledger #7), and the certification record are B3/B4 deliverables;
`pack.template.json` is instantiated then (identities and CERT_DRIVER_CLASS
are certification-time values), and the instantiated pack CARRIES a copy of
the canonical `kind-registry.json` as a declared data file — the kind
vocabulary is part of the certification identity, and the copy's sha256 must
equal the canonical registry's (asserted by the profile test suite). Helpers
here are written under the B1 pack-code contract (allowlisted subset; dump
inputs enter through the CLI-input read form with harvest-root-relative
paths).
