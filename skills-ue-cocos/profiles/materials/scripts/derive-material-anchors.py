#!/usr/bin/env python3
"""derive-material-anchors.py — materials-family derive helper (PORT-V2 B2).

Usage: derive-material-anchors.py <matinfo-root.json> [<matinfo-mid.json>] [<matinfo-leaf.json>]

Resolves the effective parameter set over a material parent chain (TRUE
root/master first — a first dump that itself declares a parent is a truncated
chain and fails; leaf instance last; deeper chains need a gated widening) and
prints an anchor-ready JSON document to stdout. Override semantics: a
non-root entry replaces the parent's record ONLY when its `overridden` is
true; an inherited entry must AGREE with the parent's value; missing override
truth, parent-less names, disagreeing inherited values, and any value this
tool cannot validate for its parameter kind are FLAGGED — entering such a
value by hand requires "transcribed": true on the anchor (mandatory reviewer
focus at the gate). Every emitted value carries its own exact dump address.
Profile v1 scope: MSM_Unlit only — any other shading model is flagged as a
blocker (port must block, no third state).

Written under the B1 pack-code contract: allowlisted stdlib only, inputs enter
exclusively through the CLI-input read form (sys.argv literal indexes; pass
harvest-root-relative paths so source file labels are anchor-ready).
"""
import json
import math
import re
import sys

# /Root/Dir/Asset.Asset — UE's canonical object path form
CANON_ASSET_RE = re.compile(r"^/[A-Za-z0-9_]+(/[^/\s.]+)+\.[^/\s.]+$")


def reject_nonfinite(c):
    raise ValueError("non-finite JSON literal '%s' — a NaN/Infinity dump value can "
                     "never be a derived truth" % c)

TOOL = "derive-material-anchors/v1"
PARAM_GROUPS = ("scalar_parameters", "vector_parameters", "texture_parameters",
                "switch_parameters")
# base property → value kind (validated before emission: parse_constant catches
# NaN/Infinity LITERALS, but a valid-JSON exponent overflow like 1e400 parses
# to inf, so every numeric property is finiteness-checked here too)
BASE_PROPS = (("material_domain", "str"),
              ("blend_mode", "str"),
              ("shading_model", "str"),
              ("two_sided", "bool"),
              ("dithered_lod_transition", "bool"),
              ("opacity_mask_clip_value", "num"))
SUPPORTED_SHADING = ("MSM_Unlit",)
# base discriminator value → the CERTIFIED feature variant it exercises. A
# value outside these maps is NOT CERTIFIED: no third state, DD or block.
SUPPORTED_BASE = {
    # the probe renders a SURFACE material on a quad: post-process, UI, decal,
    # volume and light-function domains have different execution models
    "material_domain": {"MD_Surface": "domain_surface"},
    "blend_mode": {"BLEND_Opaque": "blend_opaque",
                   "BLEND_Translucent": "blend_translucent",
                   "BLEND_Additive": "blend_additive",
                   "BLEND_Masked": "blend_masked_clip"},
    "shading_model": {"MSM_Unlit": "shading_unlit"},
}


def bad_input_path(p):
    """Anchor source labels must be harvest-root-relative: absolute paths and
    parent traversals both produce addresses validate --harvest-root rejects."""
    if p.startswith("/") or "\\" in p or (len(p) > 1 and p[1] == ":"):
        return "absolute"
    if ".." in p.split("/"):
        return "parent-traversing"
    return None


def is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) \
        and math.isfinite(x)


def unwrap(doc, label, flags):
    if not isinstance(doc, dict) or doc.get("status") != "success" or \
            not isinstance(doc.get("result"), dict) or \
            doc["result"].get("success") is not True or \
            not isinstance(doc["result"].get("data"), dict):
        flags.append({"reason": "dump '%s' is not a successful harvester payload "
                                "(status/result/data envelope) — refusing to derive "
                                "from a partial dump" % label})
        return None
    return doc["result"]["data"]


def norm_vector(v, flags, where):
    comps = None
    if isinstance(v, list) and len(v) == 4:
        comps = v
    elif isinstance(v, dict) and all(k in v for k in ("r", "g", "b", "a")):
        comps = [v["r"], v["g"], v["b"], v["a"]]
    elif isinstance(v, dict) and all(k in v for k in ("R", "G", "B", "A")):
        comps = [v["R"], v["G"], v["B"], v["A"]]
    if comps is not None and all(is_num(x) for x in comps):
        return [float(x) for x in comps]
    flags.append({"reason": "vector value at %s is not four finite numbers — the "
                            "anchor for this parameter must be transcribed by hand "
                            "(transcribed:true, reviewer focus)" % where})
    return None


def validate_kind(short, entry, flags, where):
    """Per-kind value validation: a null/malformed value must never look like a
    successfully derived anchor value."""
    v = entry.get("value")
    if short == "scalar" and not is_num(v):
        flags.append({"reason": "scalar value at %s is not a finite number — "
                                "transcribed:true required" % where})
        return False
    if short == "switch" and not isinstance(v, bool):
        flags.append({"reason": "switch value at %s is not a boolean — "
                                "transcribed:true required" % where})
        return False
    if short == "texture":
        ok = isinstance(entry.get("texture_name"), str) and entry["texture_name"] \
            and isinstance(entry.get("texture_path"), str) and entry["texture_path"] \
            and isinstance(entry.get("width"), int) and isinstance(entry.get("height"), int)
        if not ok:
            flags.append({"reason": "texture entry at %s is missing name/path/size "
                                    "fields — transcribed:true required" % where})
            return False
        # the binding value must be a CANONICAL UE object path
        # (/Root/Dir/Asset.Asset) — a bare basename cannot distinguish
        # same-named assets, which is the whole point of the full identity
        path_v = entry["texture_path"]
        if not CANON_ASSET_RE.match(path_v):
            flags.append({"reason": "texture asset path %r at %s is not a canonical "
                                    "UE object path (/Root/Dir/Asset.Asset) — a "
                                    "basename or malformed identity cannot "
                                    "distinguish same-named assets; DD it or BLOCK"
                                    % (path_v, where), "blocking": True})
            return False
        return True
    return True


def merge_chain(datas, labels, flags):
    """Effective parameters: a non-root entry wins ONLY when overridden is
    true; inherited entries must agree with the parent; everything else is a
    flag, never a silent value."""
    params = {g: {} for g in PARAM_GROUPS}
    for di, (data, label) in enumerate(zip(datas, labels)):
        for group in PARAM_GROUPS:
            entries = data.get(group)
            if not isinstance(entries, list):
                flags.append({"reason": "dump '%s' has no list '%s' — a missing "
                                        "parameter group hides obligations that "
                                        "cannot even be named; DD it or BLOCK"
                                        % (label, group), "blocking": True})
                continue
            for ei, entry in enumerate(entries):
                name = entry.get("name")
                if not isinstance(name, str) or not name:
                    flags.append({"reason": "unnamed entry %s[%d] in '%s'"
                                            % (group, ei, label)})
                    continue
                path = "$.result.data.%s[%d]" % (group, ei)
                where = "%s#%s" % (label, path)
                prev = params[group].get(name)
                if di == 0:
                    params[group][name] = {"entry": entry, "file": label,
                                           "path": path, "origin": "declared"}
                    continue
                overridden = entry.get("overridden")
                if prev is None:
                    flags.append({"reason": "'%s' at %s does not exist on the parent "
                                            "— an instance cannot introduce a "
                                            "parameter; dump set is inconsistent"
                                            % (name, where)})
                    params[group][name] = {"entry": entry, "file": label,
                                           "path": path, "origin": "orphan"}
                elif overridden is True:
                    params[group][name] = {"entry": entry, "file": label,
                                           "path": path, "origin": "override"}
                elif overridden is False:
                    # textures compare by FULL ASSET PATH: a same-named asset
                    # from another folder is a different binding, not inherited
                    parent_val = prev["entry"].get("value") if group != \
                        "texture_parameters" else prev["entry"].get("texture_path")
                    own_val = entry.get("value") if group != "texture_parameters" \
                        else entry.get("texture_path")
                    if own_val != parent_val or \
                            ("default_value" in entry and
                             entry.get("default_value") != parent_val):
                        flags.append({"reason": "'%s' at %s claims inherited but "
                                                "disagrees with the parent's value — "
                                                "instance table is not honest; "
                                                "resolve before anchoring"
                                                % (name, where)})
                    prev["origin"] = "inherited"
                else:
                    flags.append({"reason": "'%s' at %s carries no boolean "
                                            "'overridden' — override truth is "
                                            "unknown; the parent's value is kept and "
                                            "this entry needs resolution before "
                                            "anchoring" % (name, where)})
    return params


def main():
    flags = []
    argc = len(sys.argv)
    if argc < 2:
        print(json.dumps({"tool": TOOL, "error": "usage: <matinfo-root.json> "
                          "[<matinfo-mid.json>] [<matinfo-leaf.json>]"}))
        return 2
    if argc > 4:
        print(json.dumps({"tool": TOOL, "error": "parent chains deeper than 3 dumps "
                          "need a gated widening of this helper — refusing to guess"}))
        return 2
    docs, labels = [], []
    try:
        docs.append(json.load(open(sys.argv[1], encoding="utf-8"),
                              parse_constant=reject_nonfinite))
        labels.append(sys.argv[1])
        if argc > 2:
            docs.append(json.load(open(sys.argv[2], encoding="utf-8"),
                                  parse_constant=reject_nonfinite))
            labels.append(sys.argv[2])
        if argc > 3:
            docs.append(json.load(open(sys.argv[3], encoding="utf-8"),
                                  parse_constant=reject_nonfinite))
            labels.append(sys.argv[3])
    except ValueError as err:
        print(json.dumps({"tool": TOOL, "error": "dump rejected: %s" % err}))
        return 1
    for label in labels:
        kind = bad_input_path(label)
        if kind:
            flags.append({"reason": "dump path '%s' is %s — pass harvest-root-"
                                    "relative paths so emitted source.file labels are "
                                    "anchor-ready for validate --harvest-root"
                                    % (label, kind)})
    datas = []
    for doc, label in zip(docs, labels):
        data = unwrap(doc, label, flags)
        if data is None:
            print(json.dumps({"tool": TOOL, "error": "bad dump", "flags": flags},
                             indent=1))
            return 1
        datas.append(data)
    root_parent = datas[0].get("parent") or datas[0].get("parent_instance")
    if root_parent:
        flags.append({"reason": "first dump '%s' declares a parent (%s) — the chain "
                                "is TRUNCATED and master-only parameters are missing "
                                "from this anchor set; the omission cannot be "
                                "transcribed because its members are unknown; "
                                "DD it or BLOCK" % (labels[0], root_parent),
                      "blocking": True})
    for i in range(1, len(datas)):
        # parent (the master) and parent_instance (the immediate ancestor) are
        # ALTERNATIVE representations — the adjacent dump may match either
        candidates = {datas[i].get("parent"), datas[i].get("parent_instance")}
        candidates.discard(None)
        candidates.discard("")
        parent_path = datas[i - 1].get("path")
        if parent_path not in candidates:
            flags.append({"reason": "chain order: '%s' declares neither parent nor "
                                    "parent_instance equal to '%s' — a discontinuous "
                                    "chain silently drops whatever sits between the "
                                    "links; DD it or BLOCK"
                                    % (labels[i], parent_path), "blocking": True})

    leaf = datas[-1]
    pass_state, features = [], []
    base = leaf.get("base_properties")
    if isinstance(base, dict):
        for prop, kind in BASE_PROPS:
            if prop not in base:
                flags.append({"reason": "base property '%s' missing in leaf dump — "
                                        "no third state: port rule or DD required"
                                        % prop})
                continue
            v = base[prop]
            ok = (isinstance(v, str) and bool(v)) if kind == "str" else \
                 isinstance(v, bool) if kind == "bool" else is_num(v)
            if not ok:
                flags.append({"reason": "base property '%s' has an unusable value "
                                        "(%r; expected %s) — a non-finite or mistyped "
                                        "property is never a derived truth; "
                                        "transcribed:true required"
                                        % (prop, v, kind)})
                continue
            if prop in SUPPORTED_BASE:
                variant = SUPPORTED_BASE[prop].get(v)
                if variant is None:
                    flags.append({"reason": "base property %s='%s' is NOT CERTIFIED "
                                            "by the family matrix (supported: %s) — "
                                            "no third state: the port must DD it or "
                                            "BLOCK"
                                            % (prop, v,
                                               ", ".join(sorted(SUPPORTED_BASE[prop]))),
                                  "blocking": True})
                else:
                    features.append(variant)
            elif prop == "two_sided":
                features.append("two_sided_on" if v else "two_sided_off")
            elif prop == "dithered_lod_transition" and v:
                flags.append({"reason": "dithered_lod_transition is ENABLED — "
                                        "dithered LOD changes rendered behavior and "
                                        "no fixture certifies it in profile v1 "
                                        "(disabled is the supported baseline); the "
                                        "port must DD it or BLOCK",
                              "blocking": True})
            pass_state.append({
                "field": prop, "value": v,
                "source": {"file": labels[-1],
                           "path": "$.result.data.base_properties.%s" % prop}})
        if base.get("shading_model") not in SUPPORTED_SHADING:
            flags.append({"reason": "shading model '%s' is OUTSIDE profile v1 scope "
                                    "(%s only) — the render oracle is not defined "
                                    "for lit models; this port must BLOCK"
                                    % (base.get("shading_model"),
                                       "/".join(SUPPORTED_SHADING)),
                          "blocking": True})
    else:
        flags.append({"reason": "leaf dump has no base_properties object"})

    params = merge_chain(datas, labels, flags)
    out_params = {"scalar": [], "vector": [], "texture": [], "switch": []}
    for group, short in (("scalar_parameters", "scalar"),
                         ("vector_parameters", "vector"),
                         ("texture_parameters", "texture"),
                         ("switch_parameters", "switch")):
        for name in sorted(params[group]):
            rec = params[group][name]
            entry = rec["entry"]
            where = "%s#%s" % (rec["file"], rec["path"])
            item = {"name": name, "origin": rec["origin"]}
            if short == "texture":
                if validate_kind(short, entry, flags, where):
                    # the BINDING VALUE is the full asset path: two textures can
                    # share a basename (/Game/A/T_mask vs /Game/B/T_mask) and a
                    # name-only anchor would accept the wrong asset
                    item["value"] = entry["texture_path"]
                    item["displayName"] = entry["texture_name"]
                    item["sources"] = {
                        "value": {"file": rec["file"],
                                  "path": rec["path"] + ".texture_path"},
                        "displayName": {"file": rec["file"],
                                        "path": rec["path"] + ".texture_name"},
                        "width": {"file": rec["file"],
                                  "path": rec["path"] + ".width"},
                        "height": {"file": rec["file"],
                                   "path": rec["path"] + ".height"}}
                    item["size"] = [entry["width"], entry["height"]]
                else:
                    item["value"] = None
                    item["needsTranscription"] = True
            elif short == "vector":
                item["value"] = norm_vector(entry.get("value"), flags, where)
                item["source"] = {"file": rec["file"], "path": rec["path"] + ".value"}
                if item["value"] is None:
                    item["needsTranscription"] = True
            else:
                if validate_kind(short, entry, flags, where):
                    item["value"] = entry["value"]
                else:
                    item["value"] = None
                    item["needsTranscription"] = True
                item["source"] = {"file": rec["file"], "path": rec["path"] + ".value"}
            out_params[short].append(item)

    print(json.dumps({
        "tool": TOOL,
        "subject": leaf.get("name"),
        "subjectClass": leaf.get("class"),
        "chain": [d.get("name") for d in datas],
        "passState": pass_state,
        "params": out_params,
        "featuresExercised": sorted(set(features)),
        "flags": flags,
    }, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
