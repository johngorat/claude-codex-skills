#!/usr/bin/env python3
"""derive-sampler-anchors.py — realized-sampler anchors (PORT-V2 B2).

Usage: derive-sampler-anchors.py <texture.samplerinfo.json> <slotName>

Consumes the realized sampler artifact defined by PROFILE.md §1
({textureGroup, filter, addressU, addressV, sRGB, mipGenSettings, lodBias},
measured for the texture's ACTUAL TextureGroup) and emits anchor-ready
materials.pass_state values with field `sampler.<slotName>.<state>` — hands
never copy sampler states. A missing or mistyped field is FLAGGED (the anchor
must then be transcribed by hand: transcribed:true, mandatory reviewer
focus). Written under the B1 pack-code contract (CLI-input read form).
"""
import json
import math
import re
import sys

TOOL = "derive-sampler-anchors/v1"
SLOT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# field → (expected type check, anchor units)
FIELDS = (
    ("textureGroup", "str", "enum"),
    ("filter", "str", "enum"),
    ("addressU", "str", "enum"),
    ("addressV", "str", "enum"),
    ("sRGB", "bool", "flag"),
    ("mipGenSettings", "str", "enum"),
    ("lodBias", "num", "level"),
)
# enum value → the CERTIFIED feature variant it exercises. A value outside
# these maps is NOT CERTIFIED by the family matrix: no third state, the port
# must DD it or block (profile PROFILE.md §5).
SUPPORTED_ENUMS = {
    "filter": {"TF_Nearest": "sampler_filter_point",
               "TF_Bilinear": "sampler_filter_linear"},
    "addressU": {"TA_Wrap": "sampler_address_wrap",
                 "TA_Clamp": "sampler_address_clamp"},
    "addressV": {"TA_Wrap": "sampler_address_wrap",
                 "TA_Clamp": "sampler_address_clamp"},
    "mipGenSettings": {"TMGS_NoMipmaps": "sampler_mips_none",
                       "TMGS_FromTextureGroup": "sampler_mips_default"},
}


def reject_nonfinite(c):
    raise ValueError("non-finite JSON literal '%s' — a NaN/Infinity dump value can "
                     "never be a derived truth" % c)


def bad_input_path(p):
    """Anchor source labels must be harvest-root-relative: absolute paths and
    parent traversals both produce addresses validate --harvest-root rejects."""
    if p.startswith("/") or "\\" in p or (len(p) > 1 and p[1] == ":"):
        return "absolute"
    if ".." in p.split("/"):
        return "parent-traversing"
    return None


def type_ok(kind, v):
    if kind == "str":
        return isinstance(v, str) and bool(v)
    if kind == "bool":
        return isinstance(v, bool)
    return isinstance(v, (int, float)) and not isinstance(v, bool) \
        and math.isfinite(v)


def main():
    if len(sys.argv) != 3:
        print(json.dumps({"tool": TOOL, "error": "usage: <texture.samplerinfo.json> "
                          "<slotName>"}))
        return 2
    slot = sys.argv[2]
    if not SLOT_RE.fullmatch(slot):
        print(json.dumps({"tool": TOOL, "error": "slotName must be a simple "
                          "identifier matching %s — it becomes the anchor field "
                          "segment" % SLOT_RE.pattern}))
        return 2
    try:
        doc = json.load(open(sys.argv[1], encoding="utf-8"),
                        parse_constant=reject_nonfinite)
    except ValueError as err:
        print(json.dumps({"tool": TOOL, "error": "dump rejected: %s" % err}))
        return 1
    if not isinstance(doc, dict) or doc.get("status") != "success" or \
            not isinstance(doc.get("result"), dict) or \
            doc["result"].get("success") is not True or \
            not isinstance(doc["result"].get("data"), dict):
        print(json.dumps({"tool": TOOL, "error": "not a successful samplerinfo "
                          "payload (status/result/data envelope)"}))
        return 1
    data = doc["result"]["data"]
    anchors, flags = [], []
    kind_bad = bad_input_path(sys.argv[1])
    if kind_bad:
        flags.append({"reason": "dump path '%s' is %s — pass harvest-root-relative "
                                "paths so emitted source.file labels are anchor-ready "
                                "for validate --harvest-root"
                                % (sys.argv[1], kind_bad)})
    features = []
    for name, kind, units in FIELDS:
        if name not in data:
            flags.append({"reason": "samplerinfo field '%s' is missing — the profile "
                                    "artifact is incomplete; this state must be "
                                    "measured (never ini claims) or the anchor "
                                    "transcribed by hand (transcribed:true, reviewer "
                                    "focus)" % name})
            continue
        v = data[name]
        if not type_ok(kind, v):
            flags.append({"reason": "samplerinfo field '%s' has an unusable value "
                                    "(%r) — transcribed:true required" % (name, v)})
            continue
        if name in SUPPORTED_ENUMS:
            variant = SUPPORTED_ENUMS[name].get(v)
            if variant is None:
                flags.append({"reason": "sampler state %s='%s' is NOT CERTIFIED by "
                                        "the family matrix (supported: %s) — no third "
                                        "state: the port must DD it or BLOCK"
                                        % (name, v,
                                           ", ".join(sorted(SUPPORTED_ENUMS[name]))),
                              "blocking": True})
            else:
                features.append(variant)
        elif name == "sRGB":
            features.append("sampler_srgb_on" if v else "sampler_srgb_off")
        elif name == "lodBias":
            features.append("sampler_lodbias_zero" if v == 0
                            else "sampler_lodbias_nonzero")
        anchors.append({
            "field": "sampler.%s.%s" % (slot, name),
            "value": v,
            "units": units,
            "source": {"file": sys.argv[1],
                       "path": "$.result.data.%s" % name}})
    print(json.dumps({
        "tool": TOOL,
        "slot": slot,
        "passState": anchors,
        "featuresExercised": sorted(set(features)),
        "flags": flags,
    }, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
