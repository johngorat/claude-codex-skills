#!/usr/bin/env python3
"""Fixture suite for the materials family profile (PORT-V2 B2). Stdlib only.

Run: python3 tests/run-fixtures.py            (exit 0 = all green)

Covers the two derive helpers on synthetic dumps (no consumer-project content
in this public repo), and an end-to-end pack check: the profile + helpers are
assembled into a temporary family pack with coverage-only test fixtures and
must pass `family-closure.py hash` — the executable proof that the helpers
obey the B1 pack-code contract and features.json is schema-valid. Optional
smoke against real dumps runs only when MATERIALS_SMOKE_MATINFO /
MATERIALS_SMOKE_GRAPH2 point at them (kept outside this repo).
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
PROFILE_DIR = os.path.dirname(HERE)
SCRIPTS = os.path.join(PROFILE_DIR, "scripts")
FIXTURES = os.path.join(HERE, "fixtures")
CLOSURE = os.path.normpath(os.path.join(PROFILE_DIR, "..", "..", "certification",
                                        "scripts", "family-closure.py"))
TMP = tempfile.mkdtemp(prefix="materials-profile-")
n_pass, n_fail = 0, 0


def run(script, args, env=None, cwd=None):
    base = dict(os.environ)
    base["PYTHONHASHSEED"] = "0"
    base["CERT_DRIVER_CLASS"] = "test-driver"
    base.pop("PYTHONPATH", None)
    if env:
        base.update(env)
    p = subprocess.run([sys.executable, script] + args,
                       capture_output=True, text=True, env=base, cwd=cwd)
    return p.returncode, p.stdout + p.stderr


def check(name, ok, detail=""):
    global n_pass, n_fail
    if ok:
        n_pass += 1
        print(f"PASS {name}")
    else:
        n_fail += 1
        print(f"FAIL {name}{(' — ' + detail) if detail else ''}")


def case(name, script, args, expect_exit, contains=(), forbids=(), parse=None):
    # helpers run from the scratch dir with RELATIVE dump names — the helper
    # itself flags absolute input paths as not anchor-ready
    code, out = run(script, args, cwd=TMP)
    problems = []
    if code != expect_exit:
        problems.append(f"exit {code}, expected {expect_exit}")
    for s in contains:
        if s not in out:
            problems.append(f"missing: {s!r}")
    for s in forbids:
        if s in out:
            problems.append(f"forbidden: {s!r}")
    doc = None
    if parse and not problems:
        try:
            doc = json.loads(out)
        except ValueError as e:
            problems.append(f"stdout is not JSON: {e}")
        if doc is not None:
            problems.extend(parse(doc))
    check(name, not problems, "; ".join(problems) + ("\n" + out if problems else ""))


def mutate_json(src, name, fn):
    doc = json.load(open(os.path.join(TMP, src), encoding="utf-8"))
    fn(doc)
    json.dump(doc, open(os.path.join(TMP, name), "w", encoding="utf-8"), indent=1)
    return name  # cases run with cwd=TMP, so the relative name is the argument


ANCHORS = os.path.join(SCRIPTS, "derive-material-anchors.py")
POINTS = os.path.join(SCRIPTS, "derive-render-points.py")
SAMPLER = os.path.join(SCRIPTS, "derive-sampler-anchors.py")
for _f in ("master.matinfo.json", "instance.matinfo.json", "graph.graph2.json",
           "texture.samplerinfo.json"):
    shutil.copy(os.path.join(FIXTURES, _f), TMP)
MASTER = "master.matinfo.json"
INSTANCE = "instance.matinfo.json"
GRAPH = "graph.graph2.json"
SAMPLERINFO = "texture.samplerinfo.json"

# ---- derive-material-anchors --------------------------------------------------


def parse_master_only(doc):
    p = []
    if doc.get("subject") != "M_example_master":
        p.append("subject wrong")
    sc = {s["name"]: s for s in doc["params"]["scalar"]}
    if sc.get("Intensity", {}).get("value") != 2.0 or \
            sc.get("Intensity", {}).get("origin") != "declared":
        p.append("master Intensity wrong")
    if doc["params"]["vector"][0].get("value") != [1.0, 0.5, 0.25, 1.0]:
        p.append("vector not normalized to rgba list")
    if doc.get("flags"):
        p.append(f"unexpected flags: {doc['flags']}")
    bm = {b["field"]: b for b in doc["passState"]}
    if bm.get("blend_mode", {}).get("value") != "BLEND_Translucent" or \
            "base_properties.blend_mode" not in bm["blend_mode"]["source"]["path"]:
        p.append("passState blend_mode/source wrong")
    return p


case("a-master-only", ANCHORS, [MASTER], 0, parse=parse_master_only)


def parse_chain(doc):
    p = []
    if doc.get("subject") != "MI_example_leaf" or \
            doc.get("chain") != ["M_example_master", "MI_example_leaf"]:
        p.append("subject/chain wrong")
    sc = {s["name"]: s for s in doc["params"]["scalar"]}
    if sc.get("Intensity", {}).get("value") != 5.0 or \
            sc.get("Intensity", {}).get("origin") != "override":
        p.append("override not applied")
    if sc.get("EdgeControl", {}).get("origin") != "inherited":
        p.append("inherited origin wrong")
    if not sc.get("Intensity", {}).get("source", {}).get("path", "").endswith(".value"):
        p.append("scalar source path not value-exact")
    tx = {t["name"]: t for t in doc["params"]["texture"]}
    if tx.get("mask", {}).get("value") != \
            "/Game/Example/T_example_other.T_example_other" or \
            tx.get("mask", {}).get("displayName") != "T_example_other":
        p.append("texture override not applied / identity not full path")
    if "texture_path" not in tx.get("mask", {}).get("sources", {}) \
            .get("value", {}).get("path", ""):
        p.append("texture value source not exact")
    bm = {b["field"]: b for b in doc["passState"]}
    if bm.get("two_sided", {}).get("value") is not True:
        p.append("leaf two_sided not taken")
    if set(doc.get("featuresExercised", [])) != {"blend_translucent",
                                                 "shading_unlit", "two_sided_on",
                                                 "domain_surface"}:
        p.append(f"featuresExercised wrong: {doc.get('featuresExercised')}")
    if doc.get("flags"):
        p.append(f"unexpected flags: {doc['flags']}")
    return p


case("a-chain-override", ANCHORS, [MASTER, INSTANCE], 0, parse=parse_chain)

dishonest = mutate_json(INSTANCE, "dishonest.json", lambda d: d["result"]["data"]
                        ["scalar_parameters"][1].update(default_value=9.9))
case("a-dishonest-inherited", ANCHORS, [MASTER, dishonest], 0,
     contains=["instance table is not honest"])
case("a-inherited-value-disagrees", ANCHORS,
     [MASTER, mutate_json(INSTANCE, "disagree.json", lambda d: d["result"]["data"]
                          ["scalar_parameters"][1].update(value=7.0))], 0,
     contains=["claims inherited but disagrees"])
case("a-missing-overridden-truth", ANCHORS,
     [MASTER, mutate_json(INSTANCE, "no-truth.json", lambda d: d["result"]["data"]
                          ["scalar_parameters"][1].pop("overridden"))], 0,
     contains=["no boolean 'overridden'", "override truth is unknown"])
case("a-orphan-instance-param", ANCHORS,
     [MASTER, mutate_json(INSTANCE, "orphan.json", lambda d: d["result"]["data"]
                          ["scalar_parameters"].append(
                              {"name": "Ghost", "value": 1.0, "overridden": True}))],
     0, contains=["does not exist on the parent"])
case("a-truncated-chain", ANCHORS, [INSTANCE], 0,
     contains=["chain is TRUNCATED", "master-only parameters"])
case("a-lit-model-blocks", ANCHORS,
     [mutate_json(MASTER, "lit.json", lambda d: d["result"]["data"]
                  ["base_properties"].update(shading_model="MSM_DefaultLit"))], 0,
     contains=["OUTSIDE profile v1 scope", "must BLOCK"])
case("a-bad-scalar-value", ANCHORS,
     [mutate_json(MASTER, "badscalar.json", lambda d: d["result"]["data"]
                  ["scalar_parameters"][0].update(value=None))], 0,
     contains=["not a finite number", "transcribed:true required"])
case("a-wrong-chain-order", ANCHORS, [INSTANCE, MASTER], 0,
     contains=["declares neither parent nor parent_instance",
               "discontinuous chain"])
case("a-parent-instance-only-match", ANCHORS,
     [MASTER, mutate_json(INSTANCE, "pi-only.json", lambda d: d["result"]["data"]
                          .update(parent="/Game/Example/M_other.M_other"))], 0,
     forbids=["declares neither parent nor parent_instance"])


def inherited_texture(d):
    d["result"]["data"]["texture_parameters"][0].update(
        texture_name="T_example_mask",
        texture_path="/Game/Example/T_example_mask.T_example_mask",
        width=256, height=256, overridden=False,
        default_value="/Game/Example/T_example_mask.T_example_mask")


case("a-inherited-texture-honest", ANCHORS,
     [MASTER, mutate_json(INSTANCE, "inh-tex.json", inherited_texture)], 0,
     forbids=["not honest"])


def same_basename_other_path(d):
    """Same display name, DIFFERENT asset — must not read as inherited."""
    d["result"]["data"]["texture_parameters"][0].update(
        texture_name="T_example_mask",
        texture_path="/Game/OtherFolder/T_example_mask.T_example_mask",
        overridden=False, default_value="T_example_mask")


case("a-same-basename-different-path", ANCHORS,
     [MASTER, mutate_json(INSTANCE, "same-name.json", same_basename_other_path)], 0,
     contains=["claims inherited but disagrees"])


def nan_scalar(d):
    d["result"]["data"]["scalar_parameters"][0]["value"] = float("nan")


case("a-nan-rejected", ANCHORS,
     [mutate_json(MASTER, "nan.json", nan_scalar)], 1,
     contains=["non-finite JSON literal"])
# 1e400 is VALID JSON that Python parses to inf — parse_constant never sees it,
# so the per-property finiteness check is the only guard
overflow = os.path.join(TMP, "overflow.json")
open(overflow, "w", encoding="utf-8").write(
    open(os.path.join(TMP, MASTER), encoding="utf-8").read()
    .replace('"opacity_mask_clip_value": 0.3333',
             '"opacity_mask_clip_value": 1e400'))
case("a-exponent-overflow-flagged", ANCHORS, ["overflow.json"], 0,
     contains=["'opacity_mask_clip_value' has an unusable value",
               "transcribed:true required"])
case("a-mistyped-bool-base-prop", ANCHORS,
     [mutate_json(MASTER, "badbool.json", lambda d: d["result"]["data"]
                  ["base_properties"].update(two_sided="yes"))], 0,
     contains=["'two_sided' has an unusable value"])
case("a-uncertified-blend-mode", ANCHORS,
     [mutate_json(MASTER, "modulate.json", lambda d: d["result"]["data"]
                  ["base_properties"].update(blend_mode="BLEND_Modulate"))], 0,
     contains=["blend_mode='BLEND_Modulate' is NOT CERTIFIED", "DD it or BLOCK"])
case("a-traversal-path-flagged", ANCHORS, ["../" + os.path.basename(TMP) + "/"
                                           + MASTER], 0,
     contains=["is parent-traversing", "anchor-ready"])
case("a-deep-chain-refused", ANCHORS, [MASTER, INSTANCE, INSTANCE, INSTANCE], 2,
     contains=["gated widening"])
bad = mutate_json(MASTER, "bad-envelope.json", lambda d: d.update(status="error"))
case("a-bad-envelope", ANCHORS, [bad], 1, contains=["bad dump"])

# ---- derive-render-points ------------------------------------------------------


def parse_points(doc):
    p = []
    pts = doc.get("points", [])
    grid = [x for x in pts if x["kind"] == "grid"]
    branch = [x for x in pts if x["kind"] == "branch"]
    if len(grid) != 25:
        p.append(f"grid {len(grid)} != 25")
    keys = {x["key"] for x in branch}
    # threshold 0.37 → below / AT / above on both axes (the equality band
    # sits exactly at the threshold and shows up nowhere else)
    want = {"u0.320_v0.500", "u0.370_v0.500", "u0.420_v0.500",
            "u0.500_v0.320", "u0.500_v0.370", "u0.500_v0.420"}
    if keys != want:
        p.append(f"branch keys {sorted(keys)} != {sorted(want)}")
    reasons = " | ".join(f.get("reason", "") for f in doc.get("flags", []))
    if "Custom HLSL node 'HueShift'" not in reasons:
        p.append("custom HLSL flag missing")
    if "static switch 'UseEdge'" not in reasons:
        p.append("switch flag missing")
    if "threshold (B operand) is not statically readable" not in reasons:
        p.append("unreadable-threshold flag missing")
    if "DeadCustom" in reasons:
        p.append("dead-island node was flagged (reachability broken)")
    if len(set(x["key"] for x in pts)) != len(pts):
        p.append("duplicate point keys")
    return p


case("b-grid-branch-flags", POINTS, [GRAPH], 0, parse=parse_points)
case("b-usage", POINTS, [], 2, contains=["usage"])
dup_reroute = mutate_json(GRAPH, "dup-reroute.json", lambda d: d["result"]["data"]
                          ["expressions"].append({"index": 12,
                           "class": "MaterialExpressionNamedRerouteDeclaration",
                           "desc": "edge", "x": 0, "y": 900, "props": {}}))
case("b-dup-reroute-reachable-flagged", POINTS, [dup_reroute], 0,
     contains=["duplicated and a reachable usage needs that bridge"])


def add_dead_dup(d):
    d["result"]["data"]["expressions"].extend([
        {"index": 12, "class": "MaterialExpressionNamedRerouteDeclaration",
         "desc": "deadname", "x": 0, "y": 900, "props": {}},
        {"index": 13, "class": "MaterialExpressionNamedRerouteDeclaration",
         "desc": "deadname", "x": 0, "y": 950, "props": {}}])


case("b-dup-reroute-dead-silent", POINTS,
     [mutate_json(GRAPH, "dead-dup.json", add_dead_dup)], 0,
     forbids=["deadname"])
case("b-partial-graph-rejected", POINTS,
     [mutate_json(GRAPH, "no-pins.json", lambda d: d["result"]["data"]
                  .pop("output_pins"))], 1,
     contains=["partial or inconsistent graph dump", "fails closed"])
case("b-duplicate-index-rejected", POINTS,
     [mutate_json(GRAPH, "dup-index.json", lambda d: d["result"]["data"]
                  ["expressions"].append(dict(d["result"]["data"]["expressions"][0])))],
     1, contains=["partial or inconsistent graph dump"])
case("b-missing-to-name-rejected", POINTS,
     [mutate_json(GRAPH, "no-toname.json", lambda d: d["result"]["data"]
                  ["connections"][1].pop("to_name"))], 1,
     contains=["without a string 'to_name'"])
case("b-duplicate-pin-rejected", POINTS,
     [mutate_json(GRAPH, "dup-pin.json", lambda d: d["result"]["data"]
                  ["connections"].append(dict(d["result"]["data"]["connections"][1])))],
     1, contains=["driven by more than one connection"])


def direct_custom(d):
    data = d["result"]["data"]
    data["expressions"] = [
        {"index": 0, "class": "MaterialExpressionCustom", "desc": "Solo",
         "x": 0, "y": 0, "props": {"Code": "return 1;"}}]
    data["connections"] = []
    data["output_pins"] = {"EmissiveColor": {"expression": 0, "output": 0,
                                             "class": "MaterialExpressionCustom",
                                             "desc": "Solo"}}


case("b-direct-custom-to-output", POINTS,
     [mutate_json(GRAPH, "direct.json", direct_custom)], 0,
     contains=["Custom HLSL node 'Solo'"])


def if_without_a(d):
    data = d["result"]["data"]
    data["expressions"].append({"index": 12, "class": "MaterialExpressionIf",
                                "desc": "orphanIf", "x": 0, "y": 300, "props": {}})
    data["connections"].append({"from": 12, "from_out": 0, "to": 8, "to_in": 2,
                                "to_name": "C"})


case("b-if-no-a-input-blocks", POINTS,
     [mutate_json(GRAPH, "no-a.json", if_without_a)], 0,
     contains=["no recognizable A input", '"blocking": true'])


def texture_collection(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 23, "class": "MaterialExpressionTextureCollection", "desc": "tc",
         "x": 50, "y": 800,
         "props": {"TextureCollection": "/Game/Example/TC_x.TC_x"}})
    data["connections"].append({"from": 23, "from_out": 0, "to": 8, "to_in": 12,
                                "to_name": "M"})


case("b-texture-collection-blocks", POINTS,
     [mutate_json(GRAPH, "texcoll.json", texture_collection)], 0,
     contains=["TC_x", "NOT modelled by profile v1"])


def gather_mode(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 24, "class": "MaterialExpressionTextureSample", "desc": "gather",
         "x": 50, "y": 850,
         "props": {"Texture": "/Game/Example/T_g.T_g", "GatherMode": "TGM_Red"}})
    data["connections"].append({"from": 24, "from_out": 0, "to": 8, "to_in": 13,
                                "to_name": "N"})


case("b-gather-mode-blocks", POINTS,
     [mutate_json(GRAPH, "gather.json", gather_mode)], 0,
     contains=["'GatherMode' is RECOGNIZED but NOT MODELLED", "DD it or BLOCK"])

def b_driven_branch(d):
    """A = literal 0.37, B = raw UV — the mirror of the default fixture."""
    data = d["result"]["data"]
    for c in data["connections"]:
        if c["to"] == 3 and c["to_name"] == "A":
            c["from"] = 2          # Constant 0.37 → A
        elif c["to"] == 3 and c["to_name"] == "B":
            c["from"] = 1          # ComponentMask(uv) → B


case("b-branch-on-b-operand", POINTS,
     [mutate_json(GRAPH, "b-driven.json", b_driven_branch)], 0,
     contains=["u0.320_v0.500", "u0.420_v0.500"])


def scaled_uv(d):
    """A = 10*u — UV-dependent but TRANSFORMED: the threshold is not the
    transition point, so no numeric points may be invented."""
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 13, "class": "MaterialExpressionMultiply", "desc": "scale",
         "x": 150, "y": 50, "props": {"ConstB": 10}})
    for c in data["connections"]:
        if c["to"] == 3 and c["to_name"] == "A":
            c["from"] = 13
    data["connections"].append({"from": 1, "from_out": 0, "to": 13, "to_in": 0,
                                "to_name": "A"})


case("b-scaled-uv-flagged", POINTS,
     [mutate_json(GRAPH, "scaled.json", scaled_uv)], 0,
     contains=["TRANSFORMED coordinate", "10*u vs 0.37"],
     forbids=["u0.320_v0.500"])


def both_uv(d):
    data = d["result"]["data"]
    for c in data["connections"]:
        if c["to"] == 3 and c["to_name"] == "B":
            c["from"] = 1          # ComponentMask(uv) on BOTH operands


case("b-both-operands-uv-flagged", POINTS,
     [mutate_json(GRAPH, "bothuv.json", both_uv)], 0,
     contains=["BOTH operands", "not a single coordinate threshold"])


def nonparam_texture(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 13, "class": "MaterialExpressionTextureSample", "desc": "raw",
         "x": 150, "y": 300,
         "props": {"Texture": "/Game/Example/T_hardcoded.T_hardcoded"}})
    data["connections"].append({"from": 13, "from_out": 0, "to": 8, "to_in": 4,
                                "to_name": "E"})


case("b-custom-without-code-blocks", POINTS,
     [mutate_json(GRAPH, "nocode.json", lambda d: d["result"]["data"]
                  ["expressions"][6].update(props={}))], 0,
     contains=["NO readable HLSL body", "DD it or BLOCK"])


def equality_branch(d):
    d["result"]["data"]["expressions"][3]["props"]["EqualsThreshold"] = 0.01


case("b-equality-branch-blocks", POINTS,
     [mutate_json(GRAPH, "equals.json", equality_branch)], 0,
     contains=["equality outcome", "DD it or BLOCK"])
case("b-basename-texture-blocks", ANCHORS,
     [mutate_json(MASTER, "basename-tex.json", lambda d: d["result"]["data"]
                  ["texture_parameters"][0].update(texture_path="T_example_mask"))],
     0, contains=["not a canonical UE object path", "DD it or BLOCK"])
case("b-nonparam-texture-flagged", POINTS,
     [mutate_json(GRAPH, "rawtex.json", nonparam_texture)], 0,
     contains=["reachable texture reference", "T_hardcoded"])


def implicit_uv_sample(d):
    """A TextureSampleParameter2D with NO Coordinates input drives an If: it
    samples at implicit UV0, so the branch IS UV-driven but its threshold is a
    sampled value that cannot be inverted to a position."""
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 14, "class": "MaterialExpressionTextureSampleParameter2D",
         "desc": "mask", "x": 50, "y": 400,
         "props": {"ParameterName": "mask",
                   "Texture": "/Game/Example/T_example_mask.T_example_mask"}})
    for c in data["connections"]:
        if c["to"] == 3 and c["to_name"] == "A":
            c["from"] = 14


case("b-implicit-uv-sample-flagged", POINTS,
     [mutate_json(GRAPH, "implicit-uv.json", implicit_uv_sample)], 0,
     contains=["TRANSFORMED coordinate"], forbids=["u0.320_v0.500"])


def virtual_texture(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 15, "class": "MaterialExpressionRuntimeVirtualTextureSample",
         "desc": "rvt", "x": 50, "y": 450,
         "props": {"VirtualTexture": "/Game/Example/RVT_example.RVT_example"}})
    data["connections"].append({"from": 15, "from_out": 0, "to": 8, "to_in": 5,
                                "to_name": "F"})


case("b-virtual-texture-flagged", POINTS,
     [mutate_json(GRAPH, "rvt.json", virtual_texture)], 0,
     contains=["RVT_example", "realized-sampler artifact"])


def unmodelled_resource(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 16, "class": "MaterialExpressionFontSample", "desc": "font",
         "x": 50, "y": 500, "props": {"Font": "/Game/Example/F_x.F_x"}})
    data["connections"].append({"from": 16, "from_out": 0, "to": 8, "to_in": 6,
                                "to_name": "G"})


case("b-unmodelled-resource-blocks", POINTS,
     [mutate_json(GRAPH, "font.json", unmodelled_resource)], 0,
     contains=["NOT modelled by profile v1", "DD it or BLOCK"])


def collection_parameter(d):
    """MaterialExpressionCollectionParameter stores its asset in 'Collection'."""
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 21, "class": "MaterialExpressionCollectionParameter",
         "desc": "mpc", "x": 50, "y": 700,
         "props": {"Collection": "/Game/Example/MPC_example.MPC_example"}})
    data["connections"].append({"from": 21, "from_out": 0, "to": 8, "to_in": 10,
                                "to_name": "K"})


case("b-collection-parameter-blocks", POINTS,
     [mutate_json(GRAPH, "mpc.json", collection_parameter)], 0,
     contains=["MPC_example", "NOT modelled by profile v1"])


def sampler_type_override(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 22, "class": "MaterialExpressionTextureSample", "desc": "nrm",
         "x": 50, "y": 750,
         "props": {"Texture": "/Game/Example/T_n.T_n",
                   "SamplerType": "SAMPLERTYPE_Normal"}})
    data["connections"].append({"from": 22, "from_out": 0, "to": 8, "to_in": 11,
                                "to_name": "L"})


case("b-sampler-type-blocks", POINTS,
     [mutate_json(GRAPH, "samptype.json", sampler_type_override)], 0,
     contains=["SamplerType='SAMPLERTYPE_Normal'", "DD it or BLOCK"])


def hidden_upstream_via_broken_bridge(d):
    """A reachable usage whose declaration is MISSING hides everything upstream
    — including a Custom node — so the bridge failure must BLOCK."""
    data = d["result"]["data"]
    for e in data["expressions"]:
        if e["index"] == 4:          # the 'edge' declaration
            e["desc"] = "renamed"


case("b-broken-bridge-blocks", POINTS,
     [mutate_json(GRAPH, "nobridge.json", hidden_upstream_via_broken_bridge)], 0,
     contains=["cannot be bridged", "DISAPPEARS from reachability", "BLOCK"])


def sampler_override(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 17, "class": "MaterialExpressionTextureSample", "desc": "shared",
         "x": 50, "y": 550,
         "props": {"Texture": "/Game/Example/T_wrap.T_wrap",
                   "SamplerSource": "SSM_Clamp_WorldGroupSettings"}})
    data["connections"].append({"from": 17, "from_out": 0, "to": 8, "to_in": 7,
                                "to_name": "H"})


case("b-sampler-source-override-blocks", POINTS,
     [mutate_json(GRAPH, "sampoverride.json", sampler_override)], 0,
     contains=["SamplerSource='SSM_Clamp_WorldGroupSettings'", "DD it or BLOCK"])


def explicit_mip(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 18, "class": "MaterialExpressionTextureSample", "desc": "mip",
         "x": 50, "y": 600,
         "props": {"Texture": "/Game/Example/T_mip.T_mip",
                   "SamplerSource": "SSM_FromTextureAsset",
                   "MipValueMode": "TMVM_MipLevel", "ConstMipValue": 2}})
    data["connections"].append({"from": 18, "from_out": 0, "to": 8, "to_in": 8,
                                "to_name": "I"})


case("b-explicit-mip-blocks", POINTS,
     [mutate_json(GRAPH, "mipmode.json", explicit_mip)], 0,
     contains=["MipValueMode='TMVM_MipLevel'", "DD it or BLOCK"])


def unreadable_texture_object(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 19, "class": "MaterialExpressionTextureObject", "desc": "obj",
         "x": 50, "y": 650, "props": {}})
    data["connections"].append({"from": 19, "from_out": 0, "to": 8, "to_in": 9,
                                "to_name": "J"})


case("b-unreadable-texture-object-blocks", POINTS,
     [mutate_json(GRAPH, "texobj.json", unreadable_texture_object)], 0,
     contains=["NO readable asset property", "DD it or BLOCK"])

# ---- material-function closure ------------------------------------------------
FUNC_PATH = "/Game/Example/MF_example.MF_example"


def with_function_call(d):
    data = d["result"]["data"]
    data["expressions"].append(
        {"index": 12, "class": "MaterialExpressionMaterialFunctionCall",
         "desc": "MaterialFunctionCall (MF_example)", "x": 800, "y": 0,
         "props": {"MaterialFunction": FUNC_PATH}})
    data["connections"].append({"from": 12, "from_out": 0, "to": 8, "to_in": 3,
                                "to_name": "D"})


CALLER = mutate_json(GRAPH, "caller.json", with_function_call)
FUNC = os.path.join(TMP, "func.json")
json.dump({"status": "success", "result": {"success": True, "data": {
    "name": "MF_example", "path": FUNC_PATH,
    "expressions": [
        {"index": 0, "class": "MaterialExpressionFunctionInput", "desc": "UVs",
         "x": 0, "y": 0, "props": {}},
        {"index": 1, "class": "MaterialExpressionConstant", "desc": "", "x": 100,
         "y": 0, "props": {"R": 0.6}},
        {"index": 2, "class": "MaterialExpressionIf", "desc": "innerBranch",
         "x": 200, "y": 0, "props": {}},
        {"index": 3, "class": "MaterialExpressionCustom", "desc": "InnerHLSL",
         "x": 300, "y": 0, "props": {"Code": "return 1;"}}],
    "connections": [
        {"from": 0, "from_out": 0, "to": 2, "to_in": 0, "to_name": "A"},
        {"from": 1, "from_out": 0, "to": 2, "to_in": 1, "to_name": "B"},
        {"from": 2, "from_out": 0, "to": 3, "to_in": 0, "to_name": "c"}],
    "output_pins": {"Result": {"expression": 3, "output": 0,
                               "class": "MaterialExpressionCustom",
                               "desc": "InnerHLSL"}}}}},
          open(FUNC, "w", encoding="utf-8"), indent=1)


def parse_function_closure(doc):
    p = []
    keys = {x["key"] for x in doc["points"] if x["kind"] == "branch"}
    # the master's own 0.37 branch still yields points…
    for want in ("u0.320_v0.500", "u0.420_v0.500"):
        if want not in keys:
            p.append(f"missing branch point {want}")
    reasons = " | ".join(f.get("reason", "") for f in doc.get("flags", []))
    # …while the function's inner If is driven by a FunctionInput, whose
    # call-site mapping is unknown: honest FLAG, never invented points
    if "TRANSFORMED coordinate" not in reasons:
        p.append("inner FunctionInput-driven If not flagged as transformed")
    if "InnerHLSL" not in reasons:
        p.append("inner Custom node not flagged")
    if not any(f.get("graph", "").endswith("func.json") for f in doc["flags"]):
        p.append("flags carry no function-graph provenance")
    if doc.get("functionGraphs") != [FUNC_PATH]:
        p.append(f"functionGraphs wrong: {doc.get('functionGraphs')}")
    return p


case("b-function-closure-traversed", POINTS, [CALLER, "func.json"], 0,
     parse=parse_function_closure)
case("b-unresolved-function-fails", POINTS, [CALLER], 1,
     contains=["unresolved material function target", FUNC_PATH])
dup_func = os.path.join(TMP, "func2.json")
shutil.copy(FUNC, dup_func)
case("b-duplicate-function-fails", POINTS, [CALLER, "func.json", "func2.json"], 1,
     contains=["same asset path", "ambiguous function target"])
case("b-function-empty-pins-fails", POINTS,
     [CALLER, mutate_json("func.json", "func-nopins.json",
                          lambda d: d["result"]["data"].update(output_pins={}))], 1,
     contains=["'output_pins' missing or empty"])
case("b-function-no-identity-fails", POINTS,
     [CALLER, mutate_json("func.json", "func-noid.json",
                          lambda d: d["result"]["data"].pop("path"))], 1,
     contains=["function dump has no asset path"])
case("b-call-without-target-fails", POINTS,
     [mutate_json(CALLER, "call-notarget.json", lambda d: d["result"]["data"]
                  ["expressions"][-1].update(props={}))], 1,
     contains=["<missing MaterialFunction prop>"])
case("a-unsupported-domain-blocks", ANCHORS,
     [mutate_json(MASTER, "postproc.json", lambda d: d["result"]["data"]
                  ["base_properties"].update(material_domain="MD_PostProcess"))], 0,
     contains=["material_domain='MD_PostProcess' is NOT CERTIFIED", "DD it or BLOCK"])
case("a-missing-domain-flagged", ANCHORS,
     [mutate_json(MASTER, "nodomain.json", lambda d: d["result"]["data"]
                  ["base_properties"].pop("material_domain"))], 0,
     contains=["base property 'material_domain' missing"])
case("a-dithered-lod-blocks", ANCHORS,
     [mutate_json(MASTER, "dither.json", lambda d: d["result"]["data"]
                  ["base_properties"].update(dithered_lod_transition=True))], 0,
     contains=["dithered_lod_transition is ENABLED", "DD it or BLOCK"])
bad_g = mutate_json(GRAPH, "bad-graph.json", lambda d: d.update(status="error"))
case("b-bad-envelope", POINTS, [bad_g], 1, contains=["not a successful graph payload"])

# ---- derive-sampler-anchors ---------------------------------------------------


def parse_sampler(doc):
    p = []
    ps = {a["field"]: a for a in doc.get("passState", [])}
    if len(ps) != 7 or doc.get("flags"):
        p.append(f"expected 7 clean anchors, got {len(ps)} with flags {doc.get('flags')}")
    want_features = {"sampler_filter_linear", "sampler_address_wrap",
                     "sampler_address_clamp", "sampler_srgb_off",
                     "sampler_mips_none", "sampler_lodbias_zero"}
    if set(doc.get("featuresExercised", [])) != want_features:
        p.append(f"featuresExercised {doc.get('featuresExercised')} != "
                 f"{sorted(want_features)}")
    f = ps.get("sampler.slot0.filter", {})
    if f.get("value") != "TF_Bilinear" or f.get("units") != "enum" or \
            not f.get("source", {}).get("path", "").endswith(".filter"):
        p.append("filter anchor wrong")
    lb = ps.get("sampler.slot0.lodBias", {})
    if lb.get("value") != 0 or lb.get("units") != "level":
        p.append("lodBias anchor wrong")
    return p


case("c-sampler-ok", SAMPLER, [SAMPLERINFO, "slot0"], 0, parse=parse_sampler)
case("c-sampler-missing-field", SAMPLER,
     [mutate_json(SAMPLERINFO, "s-miss.json", lambda d: d["result"]["data"]
                  .pop("addressV")), "slot0"], 0,
     contains=["'addressV' is missing", "transcribed:true"])
case("c-sampler-bad-lodbias", SAMPLER,
     [mutate_json(SAMPLERINFO, "s-bad.json", lambda d: d["result"]["data"]
                  .update(lodBias="high")), "slot0"], 0,
     contains=["'lodBias' has an unusable value"])
case("c-sampler-bad-slot", SAMPLER, [SAMPLERINFO, "a.b"], 2,
     contains=["simple identifier"])
case("c-sampler-tab-slot", SAMPLER, [SAMPLERINFO, "a\tb"], 2,
     contains=["simple identifier"])
case("c-sampler-path-slot", SAMPLER, [SAMPLERINFO, "../x"], 2,
     contains=["simple identifier"])
case("c-sampler-uncertified-filter", SAMPLER,
     [mutate_json(SAMPLERINFO, "s-trilinear.json", lambda d: d["result"]["data"]
                  .update(filter="TF_Trilinear")), "slot0"], 0,
     contains=["NOT CERTIFIED by the family matrix", "DD it or BLOCK"])
case("c-sampler-uncertified-address", SAMPLER,
     [mutate_json(SAMPLERINFO, "s-mirror.json", lambda d: d["result"]["data"]
                  .update(addressU="TA_Mirror")), "slot0"], 0,
     contains=["addressU='TA_Mirror'", "NOT CERTIFIED"])
case("c-sampler-uncertified-mips", SAMPLER,
     [mutate_json(SAMPLERINFO, "s-mips.json", lambda d: d["result"]["data"]
                  .update(mipGenSettings="TMGS_Sharpen5")), "slot0"], 0,
     contains=["mipGenSettings='TMGS_Sharpen5'", "NOT CERTIFIED"])
code, out = run(SAMPLER, [os.path.join(TMP, SAMPLERINFO), "slot0"], cwd=TMP)
check("c-sampler-absolute-path-flagged",
      code == 0 and "is absolute" in out and "anchor-ready" in out,
      f"exit {code}\n{out}")

# ---- end-to-end: profile + helpers must pass the B1 pack contract -------------
pack = os.path.join(TMP, "pack")
os.makedirs(os.path.join(pack, "fixtures"))
shutil.copy(os.path.join(PROFILE_DIR, "PROFILE.md"), pack)
shutil.copy(os.path.join(PROFILE_DIR, "features.json"), pack)
shutil.copytree(SCRIPTS, os.path.join(pack, "scripts"))
shutil.copy(os.path.normpath(os.path.join(PROFILE_DIR, "..", "..",
                                          "ue-cocos-anchors-codex",
                                          "kind-registry.json")), pack)
COVERS = {
    "f1": ["scalar_param", "vector_param", "texture_param", "sampler_filter_linear",
           "sampler_address_clamp", "sampler_srgb_on", "blend_translucent",
           "shading_unlit", "two_sided_off", "render_grid", "render_backface",
           "domain_surface", "sampler_srgb_off"],
    "f2": ["switch_true", "switch_false", "graph_if_branch", "instance_override",
           "parent_chain", "blend_additive", "two_sided_on",
           "sampler_mips_default", "sampler_lodbias_zero", "render_grid",
           "render_backface", "sampler_srgb_on", "sampler_srgb_off"],
    "f3": ["graph_custom_hlsl", "render_branch_points", "graph_lerp", "graph_arith",
           "blend_opaque", "sampler_filter_point", "sampler_srgb_off",
           "render_grid", "graph_if_branch"],
    "f4": ["graph_texcoord_math", "render_grid", "blend_masked_clip",
           "sampler_address_wrap", "sampler_mips_none", "sampler_lodbias_nonzero",
           "texture_param", "sampler_filter_point", "sampler_address_clamp",
           "sampler_srgb_off", "sampler_filter_linear", "sampler_srgb_on"],
}
for name, covers in COVERS.items():
    os.makedirs(os.path.join(pack, "fixtures", name))
    json.dump({"covers": covers},
              open(os.path.join(pack, "fixtures", name, "fixture.json"), "w",
                   encoding="utf-8"))
# the e2e pack is the DELIVERED template with certification-time placeholders
# filled in — testing a hand-built manifest instead would let the template rot
manifest = json.load(open(os.path.join(PROFILE_DIR, "pack.template.json"),
                          encoding="utf-8"))
manifest.pop("_comment", None)
manifest["sourceIdentity"] = {"ueBuild": "test", "capturePipeline": "test"}
manifest["targetIdentity"] = {"cocos": "test", "backend": "test"}
json.dump(manifest, open(os.path.join(pack, "pack.json"), "w", encoding="utf-8"),
          indent=1)
code, out = run(CLOSURE, ["hash", os.path.join(pack, "pack.json"),
                          "-o", os.path.join(TMP, "cert.json")])
check("e2e-helpers-pass-b1-contract", code == 0 and "closure" in out,
      f"exit {code}\n{out}")
code, out = run(CLOSURE, ["matrix", os.path.join(pack, "pack.json")])
check("e2e-matrix-covered", code == 0 and "COVERED" in out, f"exit {code}\n{out}")
cert_doc = json.load(open(os.path.join(TMP, "cert.json"), encoding="utf-8"))
canonical_sha = hashlib.sha256(open(os.path.normpath(os.path.join(
    PROFILE_DIR, "..", "..", "ue-cocos-anchors-codex", "kind-registry.json")),
    "rb").read()).hexdigest()
check("e2e-registry-in-closure",
      cert_doc["components"].get("file:kind-registry.json") == canonical_sha,
      "registry copy missing from components or sha differs from canonical")

# ---- optional smoke on real dumps (paths via env, kept outside this repo) -----
smoke_mat = os.environ.get("MATERIALS_SMOKE_MATINFO")
smoke_graph = os.environ.get("MATERIALS_SMOKE_GRAPH2")
if smoke_mat:
    code, out = run(ANCHORS, smoke_mat.split(os.pathsep))
    ok = code == 0 and json.loads(out).get("tool")
    check("smoke-matinfo", bool(ok), f"exit {code}")
if smoke_graph:
    code, out = run(POINTS, [smoke_graph])
    ok = code == 0 and len(json.loads(out).get("points", [])) >= 25
    check("smoke-graph2", bool(ok), f"exit {code}")
if not smoke_mat and not smoke_graph:
    print("SKIP smoke (set MATERIALS_SMOKE_MATINFO / MATERIALS_SMOKE_GRAPH2 to run "
          "against real dumps)")

print(f"\n{n_pass} passed, {n_fail} failed (scratch in {TMP})")
sys.exit(1 if n_fail else 0)
