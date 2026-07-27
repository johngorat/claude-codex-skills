#!/usr/bin/env python3
"""Fixture suite for ue-cocos-anchors-codex.py. Stdlib only.

Run: python3 tests/run-fixtures.py            (exit 0 = all green)

Positive templates live in tests/fixtures/ (contract examples humans can read);
negative cases are single-defect mutations of those templates, materialized
into a mktemp dir. Placeholders __KIND_REGISTRY_SHA__ / __ANCHORS_SHA256__ are
resolved at run time against the actual registry / materialized anchors file,
so fixtures never go stale when the registry grows.

The external regression (a real gated v1 anchors file) asserts the script's
output is byte-identical to baselines captured from the pre-change script —
the executable proof of contract-v1.1 backward readability. The WHOLE bundle
(anchors, runtime, baseline-time input pins, output baselines) lives OUTSIDE
this public repo: it carries a consumer project's internals, and neither
personal/machine paths nor exact project file names are ever committed here.
Location comes ONLY from $REGRESSION_ANCHORS; sibling files are derived from
it. Unset or missing FAILS the suite: gates need this evidence. The only
opt-out is the explicit ALLOW_MISSING_EXTERNAL_REGRESSION=1, which still
prints a loud notice and is itself a finding at any gate.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPT = os.path.join(SKILL, "scripts", "ue-cocos-anchors-codex.py")
REGISTRY = os.path.join(SKILL, "kind-registry.json")
FIXTURES = os.path.join(HERE, "fixtures")
REG = os.environ.get("REGRESSION_ANCHORS")  # no default: the bundle lives outside this public repo

WRONG_SHA = "0" * 64
registry_sha = hashlib.sha256(open(REGISTRY, "rb").read()).hexdigest()
TMP = tempfile.mkdtemp(prefix="anchors-fixtures-")
n_pass, n_fail = 0, 0


def template(name):
    text = open(os.path.join(FIXTURES, name), encoding="utf-8").read()
    text = text.replace("__KIND_REGISTRY_SHA__", registry_sha)
    return json.loads(text)


def materialize(doc, name):
    path = os.path.join(TMP, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
    return path


def sha_of(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


_rt_seq = 0


def runtime_for(anchors_path, rt_name, mutate=None):
    # Unique output name per call: two materializations of the same template
    # (e.g. a bound one and a stale-sha mutation) must never share a path.
    global _rt_seq
    _rt_seq += 1
    text = open(os.path.join(FIXTURES, rt_name), encoding="utf-8").read()
    doc = json.loads(text.replace("__ANCHORS_SHA256__", sha_of(anchors_path)))
    if mutate:
        mutate(doc)
    return materialize(doc, f"out{_rt_seq}-{rt_name}")


def run(args):
    p = subprocess.run([sys.executable, SCRIPT] + args,
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def case(name, args, expect_exit, contains=(), forbids=()):
    global n_pass, n_fail
    code, out = run(args)
    problems = []
    if code != expect_exit:
        problems.append(f"exit {code}, expected {expect_exit}")
    for s in contains:
        if s not in out:
            problems.append(f"missing expected output: {s!r}")
    for s in forbids:
        if s in out:
            problems.append(f"forbidden output present: {s!r}")
    if problems:
        n_fail += 1
        print(f"FAIL {name}")
        for p in problems:
            print(f"     {p}")
        print("     --- output ---")
        for line in out.splitlines():
            print(f"     {line}")
    else:
        n_pass += 1
        print(f"PASS {name}")


def mutated(base_name, name, mutate):
    doc = template(base_name)
    mutate(doc)
    return materialize(doc, name)


# ---- positive: v1 ----------------------------------------------------------
v1_mini = materialize(template("v1-mini.json"), "v1-mini.json")
case("v1-oneshot-valid", ["validate", v1_mini, "--no-harvest"], 0,
     contains=[": 2 anchors, 0 problems"], forbids=["FAIL"])

harvest = os.path.join(TMP, "harvest")
os.makedirs(harvest, exist_ok=True)
open(os.path.join(harvest, "dump.json"), "w").write("{}\n")
case("v1-harvest-valid", ["validate", v1_mini, "--harvest-root", harvest], 0,
     contains=["VALID: 2 anchors, 0 problems"], forbids=["FAIL"])

v1_loop = materialize(template("v1-loop.json"), "v1-loop.json")
case("v1-loop-valid", ["validate", v1_loop, "--no-harvest"], 0,
     contains=[": 2 anchors, 0 problems"], forbids=["FAIL"])

# ---- negative: v1 under the registry (implied fx family) -------------------
case("v1-loop-seam-end-missing",
     ["validate", mutated("v1-loop.json", "v1-seam.json",
                          lambda d: d["anchors"].pop(1)), "--no-harvest"], 1,
     contains=["loop seam not observed from the end side"])
case("v1-unknown-kind",
     ["validate", mutated("v1-mini.json", "v1-badkind.json",
                          lambda d: d["anchors"][0]["target"].update(kind="particle_wobble")),
      "--no-harvest"], 1,
     contains=["unknown kind 'particle_wobble' in family 'fx'"])

# ---- positive: v1.1 ---------------------------------------------------------
v11_ok = materialize(template("v11-ok.json"), "v11-ok.json")
case("v11-valid", ["validate", v11_ok, "--no-harvest"], 0,
     contains=[f"kind registry: sha256 {registry_sha}", ": 2 anchors, 0 problems"],
     forbids=["FAIL"])
v11_subject = materialize(template("v11-subject.json"), "v11-subject.json")
case("v11-subject-valid", ["validate", v11_subject, "--no-harvest"], 0,
     contains=[": 1 anchors, 0 problems"], forbids=["FAIL"])

# ---- negative: v1.1 — one defect per case ----------------------------------
case("v11-unknown-family",
     ["validate", mutated("v11-ok.json", "m-fam.json",
                          lambda d: d["anchors"][0]["target"].update(kind="mesh.stream_digest")),
      "--no-harvest"], 1, contains=["unknown family 'mesh'"])
case("v11-unknown-kind",
     ["validate", mutated("v11-ok.json", "m-kind.json",
                          lambda d: d["anchors"][0]["target"].update(kind="fx.particle_wobble")),
      "--no-harvest"], 1, contains=["unknown kind 'particle_wobble' in family 'fx'"])
case("v11-unnamespaced-kind",
     ["validate", mutated("v11-ok.json", "m-ns.json",
                          lambda d: d["anchors"][0]["target"].update(kind="particle_count")),
      "--no-harvest"], 1, contains=["v1.1 kinds are namespaced 'family.kind'"])
case("v11-registry-sha-mismatch",
     ["validate", mutated("v11-ok.json", "m-sha.json",
                          lambda d: d.update(kindRegistrySha=WRONG_SHA)),
      "--no-harvest"], 1, contains=["does not match the kind registry in use", "re-gate"])
case("v11-missing-registry-sha",
     ["validate", mutated("v11-ok.json", "m-nosha.json",
                          lambda d: d.pop("kindRegistrySha")),
      "--no-harvest"], 1, contains=["'kindRegistrySha' must be the lowercase sha256"])
case("v11-both-fx-subject",
     ["validate", mutated("v11-ok.json", "m-both.json",
                          lambda d: d.update(subject="NS_test_mini")),
      "--no-harvest"], 1, contains=["exactly ONE of them may be present"])
case("v11-loop-no-mode",
     ["validate", mutated("v11-ok.json", "m-nomode.json",
                          lambda d: d["loop"].pop("mode")),
      "--no-harvest"], 1, contains=["'loop.mode' must be 'resetting' or 'accumulating'"])
case("v11-loop-accumulating",
     ["validate", mutated("v11-ok.json", "m-accum.json",
                          lambda d: d["loop"].update(mode="accumulating")),
      "--no-harvest"], 1, contains=["animations family profile", "silent skip"])
case("v11-missing-space",
     ["validate", mutated("v11-ok.json", "m-nospace.json",
                          lambda d: d["anchors"][0]["target"].pop("space")),
      "--no-harvest"], 1, contains=["requires target.space"])


def to_pass_state(d):
    a = d["anchors"][0]
    a["target"].update(kind="fx.pass_state")
    a["target"].pop("space")
    a.update(expected="additive", tolerance={"exact": True}, units="enum")


case("v11-missing-field",
     ["validate", mutated("v11-ok.json", "m-nofield.json", to_pass_state),
      "--no-harvest"], 1, contains=["requires target.field"])
case("v11-bad-units",
     ["validate", mutated("v11-ok.json", "m-units.json",
                          lambda d: d["anchors"][0].update(units="m")),
      "--no-harvest"], 1, contains=["units 'm' not allowed for kind 'fx.particle_count'"])

# ---- registry fail-closed ---------------------------------------------------
case("registry-missing",
     ["validate", v11_ok, "--no-harvest",
      "--kind-registry", os.path.join(TMP, "no-such-registry.json")], 1,
     contains=["kind registry unreadable"])
bad_reg = materialize({"registry": "ue-cocos-anchors-codex-kinds/v1", "families": []},
                      "bad-registry.json")
case("registry-malformed",
     ["validate", v11_ok, "--no-harvest", "--kind-registry", bad_reg], 1,
     contains=["kind registry 'families' must be a non-empty object"])
case("unknown-flag-rejected", ["validate", v11_ok, "--no-harvestt"], 2,
     contains=["unknown flag"])

# ---- compare: binding + GATED ----------------------------------------------
rt_ok = runtime_for(v11_ok, "v11-ok.runtime.json")
case("compare-v11-gated-pass",
     ["compare", v11_ok, rt_ok, "--approved-sha", sha_of(v11_ok)], 0,
     contains=["2 PASS, 0 DD, 0 FAIL of 2 [GATED]"])
case("compare-v11-ungated-notice", ["compare", v11_ok, rt_ok], 0,
     contains=["[UNGATED (no --approved-sha"])
rt_subj = runtime_for(v11_subject, "v11-subject.runtime.json")
case("compare-subject-gated-pass",
     ["compare", v11_subject, rt_subj, "--approved-sha", sha_of(v11_subject)], 0,
     contains=["1 PASS, 0 DD, 0 FAIL of 1 [GATED]"])
case("compare-runtime-stale-sha",
     ["compare", v11_ok,
      runtime_for(v11_ok, "v11-ok.runtime.json",
                  mutate=lambda d: d.update(anchorsSha256=WRONG_SHA)),
      "--approved-sha", sha_of(v11_ok)], 1,
     contains=["stale or foreign runtime output", "not bound to this anchors file"])
v11_badsha = mutated("v11-ok.json", "cmp-badsha.json",
                     lambda d: d.update(kindRegistrySha=WRONG_SHA))
case("compare-registry-sha-mismatch",
     ["compare", v11_badsha, runtime_for(v11_badsha, "v11-ok.runtime.json")], 1,
     contains=["FAIL(anchors)", "does not match the kind registry in use"])

def as_render_sample(d, components):
    a = d["anchors"][0]
    a["target"] = {"kind": "materials.render_sample", "node": "Quad",
                   "field": "u0.500_v0.500"}
    a.update(expected=components, tolerance={"abs": 0.01}, units="linear-rgb")
    d["anchors"].pop(1)
    d.pop("loop", None)


case("v11-render-sample-rgba-ok",
     ["validate", mutated("v11-ok.json", "rs-ok.json",
                          lambda d: as_render_sample(d, [0.1, 0.2, 0.3, 1.0])),
      "--no-harvest"], 0, contains=[": 1 anchors, 0 problems"], forbids=["FAIL"])
case("v11-render-sample-rgb-rejected",
     ["validate", mutated("v11-ok.json", "rs-short.json",
                          lambda d: as_render_sample(d, [0.1, 0.2, 0.3])),
      "--no-harvest"], 1,
     contains=["exactly 4 components", "leave a channel unchecked"])

case("v11-transcribed-ok",
     ["validate", mutated("v11-ok.json", "m-transcribed.json",
                          lambda d: d["anchors"][0].update(transcribed=True)),
      "--no-harvest"], 0,
     contains=["transcribed: 1 hand-entered anchor(s)", "MANDATORY reviewer-focus"])
case("v11-transcribed-nonbool",
     ["validate", mutated("v11-ok.json", "m-transcribed-bad.json",
                          lambda d: d["anchors"][0].update(transcribed="yes")),
      "--no-harvest"], 1,
     contains=["'transcribed' must be a boolean"])
case("v1-transcribed-rejected",
     ["validate", mutated("v1-mini.json", "v1-transcribed.json",
                          lambda d: d["anchors"][0].update(transcribed=True)),
      "--no-harvest"], 1,
     contains=["unknown key 'transcribed'"])

# ---- registry trust boundary: gates run on the pack registry only -----------
reg_copy = os.path.join(TMP, "registry-copy.json")
open(reg_copy, "w", encoding="utf-8").write(open(REGISTRY, encoding="utf-8").read())
case("validate-custom-registry-marked",
     ["validate", v11_ok, "--no-harvest", "--kind-registry", reg_copy], 0,
     contains=["CUSTOM REGISTRY", "a gate treats this as a finding"])
case("compare-gated-custom-registry-rejected",
     ["compare", v11_ok, rt_ok, "--approved-sha", sha_of(v11_ok),
      "--kind-registry", reg_copy], 1,
     contains=["mutually exclusive"])
case("compare-ungated-custom-registry-marked",
     ["compare", v11_ok, rt_ok, "--kind-registry", reg_copy], 0,
     contains=["custom registry and no --approved-sha"])
case("render-custom-registry-rejected",
     ["render", v11_ok, "--kind-registry", reg_copy], 2,
     contains=["unknown flag '--kind-registry'"])

# ---- render: generated table stays script-owned -----------------------------
table = os.path.join(TMP, "v11-ok.table.md")
case("render-v11", ["render", v11_ok, "-o", table], 0,
     contains=["rendered 2 anchors"])
case("render-check-current", ["render", v11_ok, "--check", table], 0,
     contains=["CURRENT"])
case("render-subject-header", ["render", v11_subject], 0,
     contains=["### Anchors — M_test_material (T001)"])

# ---- external regression: byte-identical to the pre-change baselines --------
# The bundle lives next to the private anchors file; siblings derive from its
# path (base = path minus .json): <base>.runtime.json, <base>.inputs.sha256
# (baseline-time pins), <base>.baseline-validate.txt, <base>.baseline-compare.txt.
REG_BASE = REG[: -len(".json")] if REG else None
REG_RUNTIME = REG_BASE + ".runtime.json" if REG else None


def regression_inputs_pinned():
    """The baselines are only meaningful against the EXACT external inputs they
    were captured from — verify both files against their pinned sha256 before
    trusting a byte-identical output (path existence alone would let edited or
    rebound inputs claim regression coverage falsely)."""
    global n_pass, n_fail
    pins = {}
    for line in open(REG_BASE + ".inputs.sha256", encoding="utf-8"):
        sha, role = line.split()
        pins[role] = sha
    ok = True
    for role, path in (("anchors", REG), ("runtime", REG_RUNTIME)):
        try:
            actual = hashlib.sha256(open(path, "rb").read()).hexdigest()
        except OSError as e:
            ok = False
            n_fail += 1
            print(f"FAIL external-input-pin ({role}) — unreadable: {e}")
            continue
        if actual != pins[role]:
            ok = False
            n_fail += 1
            print(f"FAIL external-input-pin ({role}) — {path} sha256 {actual[:16]}… does not "
                  f"match the baseline-time pin {pins[role][:16]}… from "
                  f"{REG_BASE}.inputs.sha256; the baselines prove nothing about this "
                  f"file. Re-capture baselines from a PRE-change script only.")
    if ok:
        n_pass += 1
        print("PASS external-input-pin")
    return ok


if not REG:
    missing = "$REGRESSION_ANCHORS (unset)"
elif not os.path.isfile(REG):
    missing = REG
elif not os.path.isfile(REG_RUNTIME):
    missing = REG_RUNTIME
else:
    missing = None
if missing:
    if os.environ.get("ALLOW_MISSING_EXTERNAL_REGRESSION") == "1":
        print(f"SKIP external-regression — {missing} not available; explicitly waived via "
              f"ALLOW_MISSING_EXTERNAL_REGRESSION=1. LOUD NOTICE: backward-compatibility "
              f"is NOT proven on this machine; any gate treats this waiver as a finding.")
    else:
        n_fail += 1
        print(f"FAIL external-regression — {missing} not available and no explicit waiver. "
              f"Point $REGRESSION_ANCHORS at the gated anchors file of the external "
              f"regression bundle (siblings derived from its path; the bundle is kept "
              f"OUTSIDE this public repo), or — outside gate runs only — set "
              f"ALLOW_MISSING_EXTERNAL_REGRESSION=1. A silent skip here would let a "
              f"clean clone report green without the backward-compat proof.")
elif regression_inputs_pinned():
    # pin failures are already counted inside regression_inputs_pinned()
    for label, args, baseline_path in (
            ("external-validate-regression", ["validate", REG, "--no-harvest"],
             REG_BASE + ".baseline-validate.txt"),
            ("external-compare-regression", ["compare", REG, REG_RUNTIME],
             REG_BASE + ".baseline-compare.txt")):
        code, out = run(args)
        expected = open(baseline_path, encoding="utf-8").read()
        actual = out + f"exit={code}\n"
        if actual == expected:
            n_pass += 1
            print(f"PASS {label}")
        else:
            n_fail += 1
            print(f"FAIL {label} — output differs from the pre-change baseline "
                  f"{baseline_path}; v1 behavior MUST be byte-identical (contract v1.1 "
                  f"is backward-readable by design)")

print(f"\n{n_pass} passed, {n_fail} failed (fixtures in {TMP})")
sys.exit(1 if n_fail else 0)
