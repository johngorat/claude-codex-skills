#!/usr/bin/env python3
"""derive-render-points.py — mandated render_sample UV points (PORT-V2 B2).

Usage: derive-render-points.py <graph2.json> [<functiongraph.json> ...]

Computes the profile-MANDATED UV sample points for a material's render_sample
anchors from its graph dump — never author-chosen:
  - a deterministic 5x5 grid at u,v in {0.1, 0.3, 0.5, 0.7, 0.9};
  - branch-aware pairs around every statically readable threshold of a
    UV-driven `If` node (threshold +/- 0.05 along both axes, clamped);
  - FLAGS (mandatory reviewer-focus items) for: Custom HLSL nodes (decode the
    HLSL, never the node name), UV-driven branches whose threshold is not
    statically readable, StaticSwitch parameters reachable from the output
    (fixture-variant requirement), and named-reroute pairs this tool cannot
    bridge.

Only nodes REACHABLE from output_pins participate — dead graph islands mandate
nothing.

MATERIAL FUNCTIONS: a reachable MaterialExpressionMaterialFunctionCall pulls
its function graph into the traversal — pass every function dump the profile's
transitive closure requires as extra arguments (matched by the asset path in
props.MaterialFunction). An unresolved or duplicated function target FAILS: a
function whose graph the tool cannot see could hide UV branches, Custom nodes,
or switches, and a silently omitted obligation is exactly what this helper
exists to prevent. Every point and flag carries the graph it came from.

UV OVER-APPROXIMATION (deliberate, safe direction): inside a reachable
function graph, FunctionInput nodes count as UV-dependent regardless of what
the call site feeds them. That can mandate MORE points/flags than strictly
needed; it can never mandate fewer.

Written under the B1 pack-code contract (allowlisted stdlib only; inputs enter
through the CLI-input read form).
"""
import json
import math
import sys

TOOL = "derive-render-points/v1"
GRID = (0.1, 0.3, 0.5, 0.7, 0.9)
EPS = 0.05
UV_SOURCE = "MaterialExpressionTextureCoordinate"
FUNC_INPUT = "MaterialExpressionFunctionInput"
FUNC_CALL = "MaterialExpressionMaterialFunctionCall"
IF_CLASS = "MaterialExpressionIf"
CUSTOM_CLASS = "MaterialExpressionCustom"
SWITCH_CLASS = "MaterialExpressionStaticSwitchParameter"
REROUTE_USAGE = "MaterialExpressionNamedRerouteUsage"
REROUTE_DECL = "MaterialExpressionNamedRerouteDeclaration"
CONST_CLASS = "MaterialExpressionConstant"
# value-preserving nodes: a UV coordinate reaching a comparison through ONLY
# these is still the raw coordinate, so a literal threshold locates the
# transition directly. Anything else transforms the value and the transition
# point is no longer the threshold (10*u vs 0.37 transitions at u=0.037).
PASS_THROUGH = ("MaterialExpressionComponentMask", "MaterialExpressionReroute",
                REROUTE_USAGE, REROUTE_DECL)
# Texture-SAMPLING classes: they consume UVs — implicitly UV0 when their
# Coordinates pin is unconnected — so a branch fed by one is UV-driven, and
# its threshold is a SAMPLED VALUE that cannot be inverted to a UV position.
TEX_SAMPLE_CLASSES = ("MaterialExpressionTextureSample",
                      "MaterialExpressionTextureSampleParameter",
                      "MaterialExpressionTextureSampleParameter2D",
                      "MaterialExpressionTextureSampleParameterCube",
                      "MaterialExpressionTextureSampleParameterVolume",
                      "MaterialExpressionRuntimeVirtualTextureSample")
# Resource-BEARING props: a reachable node carrying one of these with an asset
# path must be a MODELLED class, else the profile's closure would miss it.
RESOURCE_PROPS = ("Texture", "VirtualTexture", "Font", "Curve", "CurveAtlas",
                  "MaterialFunction", "Collection", "ParameterCollection",
                  "TextureCollection", "TextureCollectionObject",
                  "SubsurfaceProfile", "PhysicalMaterial", "SparseVolumeTexture")
# classes whose resource reference this profile models (everything else with a
# resource prop blocks — no third state)
MODELLED_RESOURCE_CLASSES = TEX_SAMPLE_CLASSES + (
    "MaterialExpressionTextureObject",
    "MaterialExpressionTextureObjectParameter",
    "MaterialExpressionMaterialFunctionCall")
# Node-local sampling controls: profile v1 derives sampler/mip state from the
# TEXTURE ASSET only, so every one of these must hold its baseline value —
# anything else (or an unreadable value) blocks until per-consumption state is
# modelled at a gate. Baselines are UE's defaults.
SAMPLING_BASELINE = (("SamplerSource", "SSM_FromTextureAsset"),
                     ("SamplerType", "SAMPLERTYPE_Color"),
                     ("MipValueMode", "TMVM_None"),
                     ("AutomaticViewMipBias", False),
                     ("AutomaticViewMipBiasValue", False),
                     ("ConstMipValue", 0),
                     ("ConstCoordinate", 0))
# Recognized-but-UNMODELLED sampling controls: their mere PRESENCE blocks. No
# guessed baseline is needed — an unsupported control that appears at all is
# outside profile v1 until its semantics are gated in.
UNMODELLED_SAMPLING_CONTROLS = ("GatherMode", "TextureCollectionIndex",
                                "ConstTextureCollectionIndex")


def reject_nonfinite(c):
    raise ValueError("non-finite JSON literal '%s' — a NaN/Infinity dump value can "
                     "never be a derived truth" % c)


def point_key(u, v):
    return "u%.3f_v%.3f" % (u, v)


def clamp(x):
    return max(0.02, min(0.98, x))


def load_graph(doc, path, require_pins, problems):
    """Validate one already-parsed graph dump and normalize it (or None).
    Reading is done by the caller with literal argv indexes — the pack-code
    contract accepts only that form."""
    if not isinstance(doc, dict) or doc.get("status") != "success" or \
            not isinstance(doc.get("result"), dict) or \
            doc["result"].get("success") is not True or \
            not isinstance(doc["result"].get("data"), dict):
        problems.append("%s: not a successful graph payload" % path)
        return None
    data = doc["result"]["data"]
    if not isinstance(data.get("expressions"), list) or not data["expressions"]:
        problems.append("%s: 'expressions' missing or empty" % path)
        return None
    # connections may legitimately be EMPTY: a single expression can feed an
    # output directly through output_pins
    if not isinstance(data.get("connections"), list):
        problems.append("%s: 'connections' missing or not a list" % path)
        return None
    # EVERY graph needs output pins: a function whose outputs cannot be seen
    # contributes no roots and would silently swallow its own obligations
    if not isinstance(data.get("output_pins"), dict) or not data["output_pins"]:
        problems.append("%s: 'output_pins' missing or empty" % path)
        return None
    if not require_pins:  # a function dump must also be identifiable
        asset = data.get("path") or data.get("asset")
        if not isinstance(asset, str) or not asset:
            problems.append("%s: function dump has no asset path — it cannot be "
                            "matched to a MaterialFunction target" % path)
            return None
    exprs = {}
    for e in data["expressions"]:
        if not isinstance(e, dict) or not isinstance(e.get("index"), int) or \
                not isinstance(e.get("class"), str):
            problems.append("%s: expression without integer index / class string"
                            % path)
            continue
        if e["index"] in exprs:
            problems.append("%s: duplicate expression index %d" % (path, e["index"]))
        exprs[e["index"]] = e
    conns, pin_seen = [], set()
    for c in data["connections"]:
        if not isinstance(c, dict) or c.get("from") not in exprs or \
                c.get("to") not in exprs:
            problems.append("%s: connection with endpoints outside the expression set"
                            % path)
            continue
        if not isinstance(c.get("to_name"), str):
            problems.append("%s: connection to expression %s without a string "
                            "'to_name' — pin mapping is unreadable"
                            % (path, c.get("to")))
            continue
        if c["to_name"]:
            pin = (c["to"], c["to_name"])
            if pin in pin_seen:
                problems.append("%s: expression %s pin '%s' is driven by more than "
                                "one connection — ambiguous graph"
                                % ((path,) + pin))
                continue
            pin_seen.add(pin)
        conns.append(c)
    roots = []
    for pin_name, pin in data["output_pins"].items():
        if not isinstance(pin, dict) or pin.get("expression") not in exprs:
            problems.append("%s: output pin '%s' does not reference a known "
                            "expression" % (path, pin_name))
            continue
        roots.append(pin["expression"])
    inputs = {}
    for c in conns:
        inputs.setdefault(c["to"], []).append(c)
    decl_by_desc, dup_descs = {}, set()
    for e in exprs.values():
        if e.get("class") == REROUTE_DECL:
            d = e.get("desc")
            if d in decl_by_desc:
                dup_descs.add(d)
            else:
                decl_by_desc[d] = e["index"]
    return {"path": path, "assetPath": data.get("path") or data.get("asset"),
            "name": data.get("name"), "exprs": exprs, "inputs": inputs,
            "roots": roots, "decl_by_desc": decl_by_desc, "dup_descs": dup_descs}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"tool": TOOL, "error": "usage: <graph2.json> "
                          "[<functiongraph.json> ...]"}))
        return 2
    if len(sys.argv) > 7:
        print(json.dumps({"tool": TOOL, "error": "more than 5 function graphs needs "
                          "a gated widening of this helper — refusing to guess"}))
        return 2
    problems = []
    # literal argv indexes only: the pack-code contract rejects slices and
    # non-literal open() paths, so the reads are unrolled deliberately
    raw = []
    try:
        raw.append((sys.argv[1], json.load(open(sys.argv[1], encoding="utf-8"),
                                           parse_constant=reject_nonfinite)))
        if len(sys.argv) > 2:
            raw.append((sys.argv[2], json.load(open(sys.argv[2], encoding="utf-8"),
                                               parse_constant=reject_nonfinite)))
        if len(sys.argv) > 3:
            raw.append((sys.argv[3], json.load(open(sys.argv[3], encoding="utf-8"),
                                               parse_constant=reject_nonfinite)))
        if len(sys.argv) > 4:
            raw.append((sys.argv[4], json.load(open(sys.argv[4], encoding="utf-8"),
                                               parse_constant=reject_nonfinite)))
        if len(sys.argv) > 5:
            raw.append((sys.argv[5], json.load(open(sys.argv[5], encoding="utf-8"),
                                               parse_constant=reject_nonfinite)))
        if len(sys.argv) > 6:
            raw.append((sys.argv[6], json.load(open(sys.argv[6], encoding="utf-8"),
                                               parse_constant=reject_nonfinite)))
    except ValueError as err:
        print(json.dumps({"tool": TOOL, "error": "dump rejected: %s" % err}))
        return 1
    graphs = []
    for gi, entry in enumerate(raw):
        g = load_graph(entry[1], entry[0], require_pins=(gi == 0),
                       problems=problems)
        if g is not None:
            g["id"] = gi
            graphs.append(g)
    if problems:
        print(json.dumps({"tool": TOOL, "error": "partial or inconsistent graph "
                          "dump — mandated points cannot be derived; fails closed",
                          "problems": problems}))
        return 1
    by_asset = {}
    for g in graphs[1:]:
        key = g["assetPath"]
        if key in by_asset:
            problems.append("two function dumps declare the same asset path '%s' — "
                            "ambiguous function target; fails closed" % key)
        by_asset[key] = g
    if problems:
        print(json.dumps({"tool": TOOL, "error": "ambiguous function closure",
                          "problems": problems}))
        return 1

    gmap = {g["id"]: g for g in graphs}
    flags = []
    flagged_bridges = set()
    unresolved = []

    def node_of(key):
        g = gmap.get(key[0])
        return g["exprs"].get(key[1]) if g else None

    def upstream(key):
        gid, idx = key
        g = gmap[gid]
        e = g["exprs"].get(idx)
        found = [(gid, c["from"]) for c in g["inputs"].get(idx, [])]
        if e is None:
            return []
        cls = e.get("class")
        if cls == REROUTE_USAGE:
            d = e.get("desc")
            if d in g["dup_descs"]:
                if ("dup", gid, d) not in flagged_bridges:
                    flagged_bridges.add(("dup", gid, d))
                    flags.append({"graph": g["path"], "expression": idx,
                                  "class": REROUTE_USAGE,
                                  "reason": "named reroute declaration desc '%s' is "
                                            "duplicated and a reachable usage needs "
                                            "that bridge — ambiguous; the upstream "
                                            "chain (branches, resources, functions) "
                                            "DISAPPEARS from reachability, so its "
                                            "obligations cannot be emitted; DD it or "
                                            "BLOCK" % d, "blocking": True})
            elif d not in g["decl_by_desc"]:
                if ("miss", gid, idx) not in flagged_bridges:
                    flagged_bridges.add(("miss", gid, idx))
                    flags.append({"graph": g["path"], "expression": idx,
                                  "class": REROUTE_USAGE,
                                  "reason": "named reroute cannot be bridged to its "
                                            "declaration — the upstream chain "
                                            "DISAPPEARS from reachability, so its "
                                            "obligations cannot be emitted; DD it or "
                                            "BLOCK", "blocking": True})
            else:
                found.append((gid, g["decl_by_desc"][d]))
        elif cls == FUNC_CALL:
            target = (e.get("props") or {}).get("MaterialFunction")
            if not isinstance(target, str) or not target:
                if "<missing MaterialFunction prop>" not in unresolved:
                    unresolved.append("<missing MaterialFunction prop>")
                return []
            fg = by_asset.get(target)
            if fg is None:
                if target not in unresolved:
                    unresolved.append(target)
            else:
                # the call's value comes from the function's outputs
                found.extend((fg["id"], r) for r in fg["roots"])
        return [k for k in found if node_of(k) is not None]

    reachable, stack = set(), [(0, r) for r in gmap[0]["roots"]]
    while stack:
        k = stack.pop()
        if k in reachable:
            continue
        reachable.add(k)
        stack.extend(upstream(k))
    if unresolved:
        print(json.dumps({"tool": TOOL, "error": "unresolved material function "
                          "target(s) reachable from the output — their graphs could "
                          "hide UV branches, Custom nodes, or switches; pass every "
                          "function dump the profile's transitive closure requires; "
                          "fails closed", "unresolved": unresolved}))
        return 1

    uv_memo = {}

    def uv_dep(key, trail):
        if key in uv_memo:
            return uv_memo[key]
        if key in trail:
            return False  # a cycle cannot make anything MORE UV-driven
        e = node_of(key)
        if e is None:
            return False
        cls = e.get("class")
        # over-approximation: a function's inputs count as UV-driven (see the
        # module docstring) — errs toward MORE mandated points, never fewer.
        # A texture SAMPLE consumes UVs too — implicitly UV0 when its
        # Coordinates pin is unconnected — so it is UV-driven regardless of
        # what feeds it.
        if cls in (UV_SOURCE, FUNC_INPUT) or cls in TEX_SAMPLE_CLASSES:
            uv_memo[key] = True
            return True
        result = False
        for up in upstream(key):
            if uv_dep(up, trail | {key}):
                result = True
                break
        uv_memo[key] = result
        return result

    def uv_identity(key, trail):
        """True only when the value at key IS the raw UV coordinate: a
        TextureCoordinate at unit tiling reached through value-preserving
        nodes. Any transform (scale, add, custom, function input) makes the
        comparison threshold NOT the transition point."""
        if key in trail:
            return False
        e = node_of(key)
        if e is None:
            return False
        cls = e.get("class")
        if cls == UV_SOURCE:
            props = e.get("props") or {}
            return props.get("UTiling", 1) == 1 and props.get("VTiling", 1) == 1
        if cls in PASS_THROUGH:
            ups = upstream(key)
            return len(ups) == 1 and uv_identity(ups[0], trail | {key})
        # a SAMPLED value is never the raw coordinate, even though the sample
        # itself is UV-driven — its threshold cannot be inverted to a position
        return False

    def literal_of(key):
        """The literal value carried by a Constant node, else None."""
        e = node_of(key)
        if e is None or e.get("class") != CONST_CLASS:
            return None
        v = (e.get("props") or {}).get("R")
        if isinstance(v, (int, float)) and not isinstance(v, bool) \
                and math.isfinite(v):
            return float(v)
        return None

    branch_points = []
    for key in sorted(reachable):
        gid, idx = key
        g = gmap[gid]
        e = g["exprs"][idx]
        cls = e.get("class")
        props = e.get("props") or {}
        # every reachable RESOURCE reference must be modelled by this profile
        held = [(k, props[k]) for k in RESOURCE_PROPS
                if isinstance(props.get(k), str) and props[k]
                and props[k] != "(null)"]
        if held and cls not in MODELLED_RESOURCE_CLASSES:
            flags.append({"graph": g["path"], "expression": idx, "class": cls,
                          "reason": "reachable node references resource(s) %s but its "
                                    "class is NOT modelled by profile v1 — an "
                                    "unmodelled resource-reference class cannot be "
                                    "closed over; no third state: DD it or BLOCK"
                                    % ", ".join("%s='%s'" % kv for kv in held),
                          "blocking": True})
        elif cls in MODELLED_RESOURCE_CLASSES and cls != FUNC_CALL:
            tex = None
            for k in ("Texture", "VirtualTexture"):
                if isinstance(props.get(k), str) and props[k] \
                        and props[k] != "(null)":
                    tex = props[k]
            if tex is not None:
                flags.append({"graph": g["path"], "expression": idx, "class": cls,
                              "reason": "reachable texture reference '%s' — the "
                                        "profile's transitive closure must supply "
                                        "its realized-sampler artifact and a "
                                        "texture_binding anchor keyed by the FULL "
                                        "asset path (a non-parameter node never "
                                        "appears in texture_parameters); reviewer "
                                        "focus" % tex})
            else:
                # EVERY modelled texture class must be identifiable: an asset
                # that cannot be read cannot enter the sampler/binding closure
                pname = props.get("ParameterName")
                hint = (" (parameter '%s' — resolve it from matinfo and pass the "
                        "resolved asset)" % pname) if isinstance(pname, str) and pname \
                    else ""
                flags.append({"graph": g["path"], "expression": idx, "class": cls,
                              "reason": "reachable texture node with NO readable "
                                        "asset property%s — its texture cannot enter "
                                        "the sampler-artifact and binding closure; "
                                        "DD it or BLOCK" % hint,
                              "blocking": True})
            for prop_name in UNMODELLED_SAMPLING_CONTROLS:
                if prop_name in props:
                    flags.append({"graph": g["path"], "expression": idx,
                                  "class": cls,
                                  "reason": "sampling control '%s' is RECOGNIZED but "
                                            "NOT MODELLED by profile v1 — its mere "
                                            "presence changes how the texture is "
                                            "sampled, and no baseline is claimed for "
                                            "it; DD it or BLOCK" % prop_name,
                                  "blocking": True})
            for prop_name, baseline in SAMPLING_BASELINE:
                if prop_name not in props:
                    continue
                v = props[prop_name]
                if v == baseline:
                    continue
                flags.append({"graph": g["path"], "expression": idx, "class": cls,
                              "reason": "node-local sampling control %s=%r (baseline "
                                        "%r) — profile v1 derives sampler/mip state "
                                        "from the TEXTURE ASSET only, so a "
                                        "per-consumption override (shared clamp on a "
                                        "wrapping texture, an explicit mip level, a "
                                        "view mip bias) would make the anchored state "
                                        "a lie; DD it or BLOCK"
                                        % (prop_name, v, baseline),
                              "blocking": True})
        if cls == CUSTOM_CLASS:
            code_body = (e.get("props") or {}).get("Code")
            if not (isinstance(code_body, str) and code_body.strip()):
                flags.append({"graph": g["path"], "expression": idx, "class": cls,
                              "reason": "Custom node '%s' has NO readable HLSL body "
                                        "(props.Code missing or empty) — its "
                                        "semantics cannot be reconstructed from the "
                                        "dump, and the name is never the math; "
                                        "DD it or BLOCK" % (e.get("desc") or ""),
                              "blocking": True})
            else:
                flags.append({"graph": g["path"], "expression": idx, "class": cls,
                              "reason": "Custom HLSL node '%s' — its math comes from "
                                        "the dumped HLSL body verbatim, never from "
                                        "the name; mandatory reviewer focus and a "
                                        "certification fixture"
                                        % (e.get("desc") or "")})
        if cls == SWITCH_CLASS:
            pname = (e.get("props") or {}).get("ParameterName") or e.get("desc") or ""
            flags.append({"graph": g["path"], "expression": idx, "class": cls,
                          "reason": "static switch '%s' reachable from the output — "
                                    "each used switch combination needs its own "
                                    "fixture variant at certification" % pname})
        if cls != IF_CLASS:
            continue
        props = e.get("props") or {}
        sides = {}
        for pin in ("A", "B"):
            conn = [c for c in g["inputs"].get(idx, []) if c.get("to_name") == pin]
            if conn:
                sides[pin] = {"key": (gid, conn[0]["from"]),
                              "literal": literal_of((gid, conn[0]["from"]))}
            elif ("Const" + pin) in props:
                cv = props["Const" + pin]
                lit = float(cv) if isinstance(cv, (int, float)) \
                    and not isinstance(cv, bool) and math.isfinite(cv) else None
                sides[pin] = {"key": None, "literal": lit}
            else:
                sides[pin] = None
        if sides["A"] is None or sides["B"] is None:
            missing = "A" if sides["A"] is None else "B"
            flags.append({"graph": g["path"], "expression": idx, "class": cls,
                          "reason": "reachable If has no recognizable %s input (no "
                                    "connection, no Const%s) — its branch "
                                    "obligations cannot be determined; a partial "
                                    "dump must not under-mandate; DD it or BLOCK"
                                    % (missing, missing), "blocking": True})
            continue
        uv_sides = [pin for pin in ("A", "B")
                    if sides[pin]["key"] is not None
                    and uv_dep(sides[pin]["key"], frozenset())]
        if not uv_sides:
            continue
        if len(uv_sides) == 2:
            flags.append({"graph": g["path"], "expression": idx, "class": cls,
                          "reason": "BOTH operands of a reachable If are UV-driven — "
                                    "the transition locus is not a single coordinate "
                                    "threshold; mandated points cannot be computed; "
                                    "DD it or BLOCK", "blocking": True})
            continue
        # UE's If has a THIRD outcome (AEqualsB) with its own EqualsThreshold
        # band; profile v1 models only the two-way comparison, so a connected
        # equality output or a non-default band blocks
        eq_conn = [c for c in g["inputs"].get(idx, [])
                   if c.get("to_name") == "AEqualsB"]
        eq_band = props.get("EqualsThreshold")
        if eq_conn or (eq_band is not None and eq_band != 0.00001):
            flags.append({"graph": g["path"], "expression": idx, "class": cls,
                          "reason": "reachable If uses UE's equality outcome "
                                    "(AEqualsB connected or EqualsThreshold=%r "
                                    "non-default) — profile v1 models the two-way "
                                    "comparison only, and neither the grid nor the "
                                    "threshold pairs sample the equality band; "
                                    "DD it or BLOCK" % (eq_band,),
                          "blocking": True})
            continue
        uv_pin = uv_sides[0]
        other = "B" if uv_pin == "A" else "A"
        if not uv_identity(sides[uv_pin]["key"], frozenset()):
            flags.append({"graph": g["path"], "expression": idx, "class": cls,
                          "reason": "UV-driven If whose %s operand is a TRANSFORMED "
                                    "coordinate (not the raw UV) — the comparison "
                                    "threshold is not the transition point (e.g. "
                                    "10*u vs 0.37 transitions at u=0.037); mandated "
                                    "points cannot be computed; DD it or BLOCK"
                                    % uv_pin, "blocking": True})
            continue
        threshold = sides[other]["literal"]
        if threshold is None:
            flags.append({"graph": g["path"], "expression": idx, "class": cls,
                          "reason": "UV-driven If whose threshold (%s operand) is not "
                                    "statically readable — mandated points cannot be "
                                    "computed; DD it or BLOCK" % other,
                          "blocking": True})
            continue
        if not 0.0 <= threshold <= 1.0:
            flags.append({"graph": g["path"], "expression": idx, "class": cls,
                          "reason": "UV-driven If threshold %.4f lies outside the UV "
                                    "domain — no points mandated; confirm the "
                                    "comparison domain at review" % threshold})
            continue
        # the threshold ITSELF is sampled too: the equality band sits there,
        # and a target that mis-implements the boundary shows up nowhere else
        for t in (clamp(threshold - EPS), clamp(threshold), clamp(threshold + EPS)):
            branch_points.append({"uv": [round(t, 3), 0.5], "graph": g["path"],
                                  "fromExpression": idx, "threshold": threshold,
                                  "axis": "u"})
            branch_points.append({"uv": [0.5, round(t, 3)], "graph": g["path"],
                                  "fromExpression": idx, "threshold": threshold,
                                  "axis": "v"})

    seen_keys, points = set(), []
    for u in GRID:
        for v in GRID:
            k = point_key(u, v)
            seen_keys.add(k)
            points.append({"key": k, "uv": [u, v], "kind": "grid"})
    for bp in branch_points:
        k = point_key(bp["uv"][0], bp["uv"][1])
        if k in seen_keys:
            continue
        seen_keys.add(k)
        points.append({"key": k, "uv": bp["uv"], "kind": "branch",
                       "graph": bp["graph"], "fromExpression": bp["fromExpression"],
                       "threshold": bp["threshold"], "axis": bp["axis"]})

    print(json.dumps({
        "tool": TOOL,
        "subject": gmap[0]["name"],
        "functionGraphs": [g["assetPath"] for g in graphs[1:]],
        "expressionsReachable": len(reachable),
        "points": points,
        "flags": flags,
    }, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
