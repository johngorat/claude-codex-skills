# Family certification toolchain (PORT-V2 §2)

Family-agnostic machinery behind every family profile's "independent oracle":
golden fixtures certify a conversion pipeline only while NOTHING semantic has
drifted — and "nothing semantic sits outside the hash".

Executable authority: `scripts/family-closure.py` (stdlib only; its docstring
is the rule book). Run `tests/run-fixtures.py` after ANY change here.

## Artifacts

- **Pack manifest** (`pack.json`, contract `ue-cocos-family-pack/v1`): the
  family's declared composition — profile doc, machine-readable features
  file, entrypoints (roots of the executed-code walk), REQUIRED invocation
  templates (entrypoint + argv + cwd — same code, different arguments is a
  different oracle), data files, fixtures dir, source identity (UE build /
  capture pipeline), target identity (engine version / render backend), and
  read env variables. Unknown keys fail closed; a `subprocesses` key fails
  closed (process launch is not part of this contract).
- **Certification** (`hash -o certification.json`, contract
  `ue-cocos-family-certification/v1`): per-component sha256 map + the overall
  `closureSha256`. Includes interpreter identity (version + binary sha256 +
  execution flags), privacy-safe VALUE digests of every declared env variable
  plus the pinned interpreter-state set, and the invocation contract. Issued
  ONLY over a pack whose coverage matrix passes, ONLY under a pinned
  PYTHONHASHSEED (decimal, 0..4294967295), with an EMPTY PYTHONPATH, and
  with `CERT_DRIVER_CLASS` exported (e.g.
  `CERT_DRIVER_CLASS='metal-m2' PYTHONHASHSEED=0 … hash pack.json -o cert.json`).
  Execution-world info (OS class + the supplied driver class) is RECORDED in
  the certificate's schema-closed envelope but EXCLUDED from the invalidating
  hash — USER decision on design ledger #6; the residual is an accepted,
  documented risk mitigated by per-port UE-capture escalation. verify
  requires the world record to be present and well-formed.
- **`verify`**: authenticates the certificate first (its components map must
  reproduce its own `closureSha256` — a tampered certificate fails), then
  recomputes and compares component-by-component; CURRENT only when the fresh
  map EQUALS the certified map; any drift prints `STALE <component>` and
  exits 1. The pack path on the CLI is caller-selected, so a gate passes
  `--approved-closure <sha recorded in the gate report>` — output is marked
  GATED/UNGATED exactly like the anchors contract's `--approved-sha`
  discipline (a stale pack copy with its old certificate cannot pass a gate).
- **`matrix`**: feature×fixture coverage — every declared feature exercised
  by ≥1 fixture (`fixture.json` `covers` lists), every DECLARED interacting
  pair exercised by a fixture covering both members; an undeclared feature in
  a `covers` list fails (no third state). Full combinatorial coverage is
  explicitly NOT claimed. Also enforced inside `hash` and `verify`.

## Fail-closed guarantees of the code walk

Pack code is ALLOWLISTED, not denylisted — everything not explicitly
recognized fails closed. The package-aware transitive import walk runs PER
ENTRYPOINT with that entrypoint's directory as the single import root (the
`sys.path[0]` model of its invocation — imports never resolve into another
entrypoint's directory); every walked file, hashed file, and invocation cwd
must be symlink-contained under the pack root, and manifest paths reject
absolute/`..`/backslash/drive forms. Allowlisted stdlib imports: json, os,
sys, re, math, hashlib, itertools, collections, functools, struct; widening
the list is a gated edit. Fails closed on: any other module (io, runpy,
pathlib, importlib, builtins, ctypes, **subprocess**, third-party, …), ANY
import aliasing, from-imports of stdlib modules (qualified access only),
relative imports, banned builtins (exec, eval, compile, __import__, input,
breakpoint, getattr/setattr/delattr, globals/locals/vars, and hash/id —
hash-seed-dependent), sensitive names used as values (`read_env =
os.getenv`, `reader = open`), `__file__` outside the recognized read
expression, non-allowlisted os/sys surfaces (only pure-string `os.path.*`
called directly — relpath is excluded, it consults the cwd — plus
literal-form `os.environ`/`os.getenv`; no stdin, no import state, no
executable path), file reads outside the two accepted forms (both read-only,
≤2 positional arguments, literal encoding in text mode: the declared-file
form `open(os.path.join(os.path.dirname(__file__), <literals>), 'r'|'rb')`
to an EXISTING pack file, and the CLI-input form
`open(sys.argv[<int literal>], …)` — a port parameter outside the closure by
design, its integrity owned by the anchors contract's source addresses), and
environment enumeration/aliasing. **Process launch is
not supported in this contract** — any subprocess use or `subprocesses`
manifest key fails closed; it returns with the runtime-enforcement layer
(phase 2+), which can bind inherited stdin/env/PATH and interpreter
semantics that static analysis cannot. Declared env variables AND the pinned
interpreter-state set (PYTHONPATH, PYTHONHASHSEED, PYTHONUTF8,
PYTHONSTARTUP, LANG, LC_ALL, LC_CTYPE) are bound by privacy-safe VALUE digests,
domain-separated from the unset state; certification runs require a pinned
PYTHONHASHSEED. The pack identity (contract + family) and the declared
entrypoints/invocations are hashed components, so an approved closure
authenticates them too.

**Stated limitation (accepted, documented):** the walker's guarantee is
"accepted ⇒ closed", not "all of Python is analyzable" — it admits only the
recognized subset and fails closed on the rest. Pack code is itself a hashed
component authored under gates; an adversarial pack author is outside this
tool's threat model (drift detection for honestly-written code is the goal).
A runtime enforcement layer (sys.addaudithook-based read/exec/env audit
during certification runs) is the planned phase-2+ strengthening.

## Division of labor

This directory owns the family-agnostic tools. Each family profile (B2+)
ships its own `pack.json`, features file, and fixtures, and wires stale-
certification surfacing into its port pipeline. The UE-side capture pipeline
lives in the consumer project and shares NO conversion code with the
Cocos-side derivation — the expectation file format is the only shared
artifact (oracle independence is structural).
