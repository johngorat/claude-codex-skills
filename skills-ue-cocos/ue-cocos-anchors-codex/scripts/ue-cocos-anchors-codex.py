#!/usr/bin/env python3
"""ue-cocos-anchors-codex.py — the anchor contract for UE->Cocos FX ports.

Subcommands:
  validate <anchors.json>                      structural + semantic checks, exit 1 on any FAIL
  compare  <anchors.json> <runtime.json>       join by id, tolerance compare, exit 1 on any FAIL
  render   <anchors.json> [-o out.md]          generate the human-readable anchor table (never hand-write it)

Stdlib only. This script — not prose — owns the contract rules:
  - every anchor: id + source (UE dump address) + target (Cocos runtime address)
    + at + expected + tolerance + units; all address fields are typed strings;
  - unique ids; duplicate (node,kind,field,space,at) targets are rejected;
  - numeric expected needs finite abs/rel tolerance >= 0; string/bool expected
    needs exact=true; bool is NEVER a number; NaN/Infinity are rejected anywhere;
  - spatial kinds (particle_*) require 'space'; field-addressed kinds
    (material_uniform, pass_state, texture_binding) require 'field';
  - if a loop period is declared, cycleTime anchors must observe BOTH sides of
    the seam: at least one in [0, period/4) and one in [3*period/4, period];
    a loop with only tick anchors is invalid;
  - a deliberate, USER-approved divergence is representable: anchor.dd =
    {"id": "DD-n", "approvedBy": "USER"} — compare reports it as DD and never
    as PASS; there is no other legitimate way to differ from the source;
  - compare binds the runtime file to the anchors file: fx, sessionId and
    anchorsSha256 (sha256 of the anchors file bytes) must match — a stale or
    foreign runtime file cannot pass;
  - an anchor without a sample, a sample with "error", duplicate or unknown ids
    are all FAILs — silent skips do not exist;
  - a FAIL is resolved by tracing the source address or by a USER-approved DD
    entry, never by adjusting Cocos params, expected values, or tolerances.
    Post-approval edits to expected/tolerance without a re-gate are findings.
"""
import hashlib
import json
import math
import os
import re
import sys

CONTRACT = "ue-cocos-anchors-codex/v1"
RUNTIME_CONTRACT = "ue-cocos-anchors-codex-runtime/v1"
ID_RE = re.compile(r"^[a-z0-9]+(\.[A-Za-z0-9_-]+)+$")
FIELD_KINDS = ("material_uniform", "pass_state", "texture_binding")
NO_TWEAK = ("Resolve each FAIL by tracing its `source` address back to the UE dump, "
            "or record a USER-approved DD entry (anchor.dd). Adjusting Cocos-side "
            "params, expected values, or tolerances to make a check pass is "
            "falsifying the test.")


def is_number(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def is_number_array(x):
    return isinstance(x, list) and len(x) > 0 and all(is_number(v) for v in x)


def is_str(x):
    return isinstance(x, str) and len(x) > 0


def _reject_constant(c):
    raise ValueError(f"non-finite JSON literal '{c}' is rejected by the contract")


def _assert_finite(obj, path="$"):
    if isinstance(obj, float) and not math.isfinite(obj):
        raise ValueError(f"non-finite number at {path} (overflow like 1e999 parses to Infinity "
                         f"silently) — rejected by the contract")
    elif isinstance(obj, dict):
        for k, v in obj.items():
            _assert_finite(v, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            _assert_finite(v, f"{path}[{i}]")


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f, parse_constant=_reject_constant)
    _assert_finite(doc)
    return doc


def validate(doc, fails, harvest_root=None):
    if not isinstance(doc, dict) or doc.get("contract") != CONTRACT:
        fails.append(f"contract must be '{CONTRACT}'")
        return
    for key in ("fx", "sessionId"):
        if not is_str(doc.get(key)):
            fails.append(f"'{key}' must be a non-empty string")
    anchors = doc.get("anchors")
    if not isinstance(anchors, list) or not anchors:
        fails.append("'anchors' must be a non-empty array")
        return
    period = None
    loop = doc.get("loop")
    if loop is not None:
        if isinstance(loop, dict):
            for k in loop:
                if k != "periodSec":
                    fails.append(f"unknown key 'loop.{k}' — the contract has no such field")
        period = loop.get("periodSec") if isinstance(loop, dict) else None
        if not is_number(period) or period <= 0:
            fails.append("'loop.periodSec' must be a finite number > 0 when 'loop' is present")
            period = None

    top_allowed = {"contract", "fx", "sessionId", "loop", "anchors"}
    for k in doc:
        if k not in top_allowed:
            fails.append(f"unknown top-level key '{k}' — the contract has no such field")
    seen_ids, seen_targets, cycle_times, all_emitters = set(), {}, {}, set()
    anchor_allowed = {"id", "source", "target", "at", "expected", "tolerance", "units", "dd", "note"}
    sub_allowed = {"source": {"file", "path", "chain"},
                   "target": {"kind", "node", "space", "field", "extra"},
                   "at": {"cycleTime", "tick"},
                   "tolerance": {"abs", "rel", "exact"},
                   "dd": {"id", "approvedBy"}}
    for i, a in enumerate(anchors):
        where = f"anchors[{i}]"
        if not isinstance(a, dict):
            fails.append(f"{where}: not an object")
            continue
        aid = a.get("id")
        where = f"anchors[{i}] ({aid})" if aid else where
        for k in a:
            if k not in anchor_allowed:
                fails.append(f"{where}: unknown key '{k}' — the contract has no such field")
        for sub, allowed in sub_allowed.items():
            v = a.get(sub)
            if isinstance(v, dict):
                for k in v:
                    if k not in allowed:
                        fails.append(f"{where}: unknown key '{sub}.{k}'")
        if "note" in a and not isinstance(a.get("note"), str):
            fails.append(f"{where}: 'note' must be a string")
        src0 = a.get("source")
        if isinstance(src0, dict) and "chain" in src0 and src0["chain"] is not None and not is_str(src0["chain"]):
            fails.append(f"{where}: 'source.chain' must be a non-empty string or null")
        tgt0 = a.get("target")
        if isinstance(tgt0, dict):
            if "space" in tgt0 and tgt0["space"] not in ("world", "local"):
                fails.append(f"{where}: 'target.space' must be 'world' or 'local'")
            if "field" in tgt0 and not is_str(tgt0["field"]):
                fails.append(f"{where}: 'target.field' must be a non-empty string")
            if "extra" in tgt0 and not isinstance(tgt0["extra"], dict):
                fails.append(f"{where}: 'target.extra' must be an object")
        if not is_str(aid) or not ID_RE.match(aid):
            fails.append(f"{where}: 'id' missing or not matching {ID_RE.pattern}")
        elif aid in seen_ids:
            fails.append(f"{where}: duplicate id")
        else:
            seen_ids.add(aid)
            all_emitters.add(aid.split(".")[0])
        for key in ("id", "source", "target", "at", "expected", "tolerance", "units"):
            if key not in a:
                fails.append(f"{where}: missing required field '{key}'")

        src = a.get("source")
        if not (isinstance(src, dict) and is_str(src.get("file")) and is_str(src.get("path"))):
            fails.append(f"{where}: 'source' needs string 'file' and 'path' (UE dump address)")
        elif harvest_root is not None:
            if os.path.isabs(src["file"]):
                fails.append(f"{where}: source.file must be relative to the harvest root, "
                             f"not absolute: '{src['file']}'")
            else:
                root = os.path.realpath(harvest_root)
                fpath = os.path.realpath(os.path.join(root, src["file"]))
                if not (fpath == root or fpath.startswith(root + os.sep)):
                    fails.append(f"{where}: source.file '{src['file']}' escapes the harvest root")
                elif not os.path.isfile(fpath):
                    fails.append(f"{where}: source.file '{src['file']}' not found under harvest root "
                                 f"'{harvest_root}' — an expectation must trace to an existing dump")

        tgt = a.get("target")
        kind = node = None
        if not isinstance(tgt, dict) or not is_str(tgt.get("kind")) or not is_str(tgt.get("node")):
            fails.append(f"{where}: 'target' needs string 'kind' and 'node' (Cocos runtime address)")
        else:
            kind, node = tgt["kind"], tgt["node"]
            if kind.startswith("particle_") and tgt.get("space") not in ("world", "local"):
                fails.append(f"{where}: spatial kind '{kind}' requires target.space of 'world' or 'local'")
            if kind in FIELD_KINDS and not is_str(tgt.get("field")):
                fails.append(f"{where}: kind '{kind}' requires target.field — two values on one node "
                             f"must have distinguishable addresses")

        at = a.get("at")
        at_key = None
        if not isinstance(at, dict):
            fails.append(f"{where}: 'at' must be an object with 'cycleTime' or 'tick'")
        else:
            ct, tick = at.get("cycleTime"), at.get("tick")
            if ct is not None and (not is_number(ct) or ct < 0):
                fails.append(f"{where}: 'at.cycleTime' must be a finite number >= 0")
                ct = None
            if tick is not None and (isinstance(tick, bool) or not isinstance(tick, int) or tick < 0):
                fails.append(f"{where}: 'at.tick' must be an integer >= 0")
                tick = None
            if "cycleTime" in at and "tick" in at:
                fails.append(f"{where}: 'at' must carry EITHER the cycleTime key OR the tick key, "
                             f"never both (even null-valued) — ambiguous sampling time")
            if ct is not None and period is not None and ct > period:
                fails.append(f"{where}: 'at.cycleTime'={ct} exceeds loop.periodSec={period}")
            if ct is None and tick is None:
                fails.append(f"{where}: 'at' needs a valid 'cycleTime' or 'tick'")
            else:
                ctn = None if ct is None else (0.0 if float(ct) == 0 else float(ct))
                at_key = f"ct={ctn}" if ctn is not None else f"tick={int(tick)}"
                if ctn is not None and is_str(aid):
                    cycle_times.setdefault(aid.split(".")[0], []).append(ctn)
        if kind and node and at_key:
            fld = tgt.get("field") if is_str(tgt.get("field")) else None
            spc = tgt.get("space") if tgt.get("space") in ("world", "local") else None
            tkey = (node, kind, fld, spc, at_key)
            if tkey in seen_targets:
                fails.append(f"{where}: target collides with {seen_targets[tkey]} — "
                             f"same (node, kind, field, space, at); addresses must be distinguishable")
            else:
                seen_targets[tkey] = aid or where

        exp, tol = a.get("expected"), a.get("tolerance")
        if isinstance(tol, dict):
            if "exact" in tol and not isinstance(tol["exact"], bool):
                fails.append(f"{where}: 'tolerance.exact' must be a boolean")
            for tk in ("abs", "rel"):
                if tk in tol and not (is_number(tol[tk]) and tol[tk] >= 0):
                    fails.append(f"{where}: 'tolerance.{tk}' must be a finite number >= 0")
        elif "tolerance" in a:
            fails.append(f"{where}: 'tolerance' must be an object")
        if isinstance(exp, bool) or isinstance(exp, str):
            if not (isinstance(tol, dict) and tol.get("exact") is True):
                fails.append(f"{where}: string/bool expected requires tolerance {{\"exact\": true}}")
        elif is_number(exp) or is_number_array(exp):
            ok_tol = False
            if isinstance(tol, dict):
                a_ok = "abs" not in tol or (is_number(tol["abs"]) and tol["abs"] >= 0)
                r_ok = "rel" not in tol or (is_number(tol["rel"]) and tol["rel"] >= 0)
                has = is_number(tol.get("abs")) or is_number(tol.get("rel"))
                ok_tol = a_ok and r_ok and has
            if not ok_tol:
                fails.append(f"{where}: numeric expected requires tolerance with finite 'abs' and/or "
                             f"'rel' >= 0 (NaN/Infinity/negative rejected)")
        else:
            fails.append(f"{where}: 'expected' must be a finite number, finite number array, string, "
                         f"or bool (bool is not a number; NaN/Infinity rejected)")

        if not is_str(a.get("units")):
            fails.append(f"{where}: 'units' must be a non-empty string (use 'enum'/'flag' for non-physical)")

        dd = a.get("dd")
        if dd is not None and not (isinstance(dd, dict) and is_str(dd.get("id"))
                                   and dd.get("approvedBy") == "USER"):
            fails.append(f"{where}: 'dd' must be {{\"id\": \"DD-n\", \"approvedBy\": \"USER\"}}")

    if period is not None:
        if not cycle_times:
            fails.append("loop declared but no cycleTime anchors exist — tick-only anchors "
                         "cannot verify loop behavior")
        for emitter in sorted(all_emitters - set(cycle_times)):
            fails.append(f"emitter '{emitter}' has only tick anchors in a looping system — its "
                         f"loop behavior is unverified; add cycleTime anchors on both sides of "
                         f"the seam")
        for emitter, cts in sorted(cycle_times.items()):
            if min(cts) >= period / 4:
                fails.append(f"loop seam not observed from the start side for emitter '{emitter}': "
                             f"need an anchor with cycleTime < {period / 4} — global coverage by "
                             f"other emitters does not verify this emitter's loop")
            if max(cts) < 3 * period / 4:
                fails.append(f"loop seam not observed from the end side for emitter '{emitter}': "
                             f"need an anchor with cycleTime >= {3 * period / 4}")


def emitter_counts(anchors):
    counts = {}
    for a in anchors:
        if isinstance(a, dict) and is_str(a.get("id")):
            counts[a["id"].split(".")[0]] = counts.get(a["id"].split(".")[0], 0) + 1
    return counts


def num_close(actual, expected, tol):
    if not is_number(actual):
        return False
    ok = False
    if is_number(tol.get("abs")):
        ok = ok or abs(actual - expected) <= tol["abs"]
    if is_number(tol.get("rel")):
        ok = ok or abs(actual - expected) <= tol["rel"] * abs(expected)
    return ok


def compare_one(a, sample):
    exp, tol = a["expected"], a["tolerance"]
    act = sample.get("actual")
    if isinstance(exp, bool) or isinstance(exp, str):
        return (type(act) is type(exp) and act == exp,
                f"expected {exp!r}, actual {act!r} (exact)")
    if is_number(exp):
        return (num_close(act, exp, tol), f"expected {exp} ±{tol}, actual {act}")
    if is_number_array(exp):
        if not isinstance(act, list) or len(act) != len(exp):
            return (False, f"expected array of {len(exp)}, actual {act!r}")
        ok = all(num_close(av, ev, tol) for av, ev in zip(act, exp))
        return (ok, f"expected {exp} ±{tol}, actual {act}")
    return (False, "unsupported expected type")


def cmd_validate(argv):
    doc = load(argv[0])
    harvest_root, no_harvest = None, False
    if len(argv) >= 3 and argv[1] == "--harvest-root":
        harvest_root = argv[2]
    elif len(argv) >= 2 and argv[1] == "--no-harvest":
        no_harvest = True
    fails = []
    if harvest_root is None and not no_harvest:
        fails.append("validate requires --harvest-root <dir> (or an explicit --no-harvest "
                     "opt-out, which a Stage-2 gate must treat as a finding)")
    validate(doc, fails, harvest_root)
    for f in fails:
        print(f"FAIL {f}")
    anchors = doc.get("anchors") if isinstance(doc, dict) else None
    if not isinstance(anchors, list):
        anchors = []
    for emitter, n in sorted(emitter_counts(anchors).items()):
        print(f"  coverage: {emitter} — {n} anchor(s)")
    print("  NOTE: this script proves 'everything anchored is verified' and CANNOT prove "
          "'everything is anchored'. Completeness against the harvest is contract item #1 "
          "of the Stage-2 adversarial review; these counts are evidence for it.")
    status = "INVALID" if fails else "VALID"
    if not fails and no_harvest:
        status = "VALID (SOURCES UNVERIFIED — --no-harvest; a Stage-2 gate treats this as a finding)"
    print(f"{status}: {len(anchors)} anchors, {len(fails)} problems")
    return 1 if fails else 0


def cmd_compare(argv):
    anchors_path, runtime_path = argv[0], argv[1]
    approved_sha = None
    if len(argv) >= 4 and argv[2] == "--approved-sha":
        approved_sha = argv[3].lower()
    anchors_doc, runtime_doc = load(anchors_path), load(runtime_path)
    fails = []
    validate(anchors_doc, fails)
    if fails:
        for f in fails:
            print(f"FAIL(anchors) {f}")
        print("INVALID anchors file — fix it before comparing")
        return 1
    binding_fails = []
    if not isinstance(runtime_doc, dict):
        print(f"FAIL runtime root must be a JSON object, got {type(runtime_doc).__name__}")
        return 1
    if not isinstance(runtime_doc.get("samples"), list):
        binding_fails.append("runtime 'samples' must be an array")
    if runtime_doc.get("contract") != RUNTIME_CONTRACT:
        binding_fails.append(f"runtime contract must be '{RUNTIME_CONTRACT}'")
    for key in ("fx", "sessionId"):
        if runtime_doc.get(key) != anchors_doc.get(key):
            binding_fails.append(f"runtime '{key}'={runtime_doc.get(key)!r} does not match "
                                 f"anchors '{key}'={anchors_doc.get(key)!r}")
    with open(anchors_path, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    if approved_sha is not None and sha != approved_sha:
        binding_fails.append(f"anchors file sha {sha[:16]}… does not match the Stage-2 approved "
                             f"sha {approved_sha[:16]}… — expectations changed after approval; "
                             f"re-open Stage-2 before comparing")
    if runtime_doc.get("anchorsSha256") != sha:
        binding_fails.append(f"runtime anchorsSha256 does not match this anchors file "
                             f"(expected {sha[:16]}…) — stale or foreign runtime output")
    if binding_fails:
        for f in binding_fails:
            print(f"FAIL {f}")
        print("Runtime file is not bound to this anchors file — re-run the probe.")
        return 1

    samples, dupes, malformed = {}, set(), 0
    for s in runtime_doc.get("samples") or []:
        if not isinstance(s, dict) or not is_str(s.get("id")):
            malformed += 1
            continue
        sid = s["id"]
        if sid in samples:
            dupes.add(sid)
        samples[sid] = s
    results, n_dd = [], 0
    for a in anchors_doc["anchors"]:
        aid = a["id"]
        s = samples.pop(aid, None)
        if s is None:
            results.append((aid, False, "NOT SAMPLED by the probe — coverage gap, not a skip "
                                        "(DD anchors are still sampled for the record)"))
        elif "error" in s:
            results.append((aid, False, f"probe error: {s['error']} (a DD anchor does not excuse "
                                        f"a probe failure)"))
        elif a.get("dd"):
            act = s.get("actual")
            measured = (isinstance(act, (str,)) and act != "") or \
                       (isinstance(act, bool)) or is_number(act) or is_number_array(act)
            if not measured:
                results.append((aid, False, f"DD anchor's 'actual' is not a measurement "
                                            f"({act!r}) — a divergence is approved, not unmeasured"))
            else:
                n_dd += 1
                results.append((aid, True, f"DD({a['dd']['id']}) — USER-approved divergence; actual "
                                           f"{act!r} recorded, not compared"))
        else:
            ok, detail = compare_one(a, s)
            results.append((aid, ok, detail))
    for sid in dupes:
        results.append((sid, False, "duplicate sample id in runtime file"))
    for sid in samples:
        results.append((sid, False, "unknown id in runtime file — probe/anchors drift"))
    if malformed:
        results.append(("(malformed)", False, f"{malformed} sample(s) are not objects with a "
                                              f"string id — probe output is corrupt"))
    n_fail = 0
    for aid, ok, detail in results:
        tag = "DD  " if detail.startswith("DD(") else ("PASS" if ok else "FAIL")
        print(f"{tag} {aid}: {detail}")
        n_fail += 0 if ok else 1
    n_pass = len(results) - n_fail - n_dd
    gate = "GATED" if approved_sha is not None else "UNGATED (no --approved-sha — a Stage-3 gate requires it)"
    print(f"{n_pass} PASS, {n_dd} DD, {n_fail} FAIL of {len(results)} [{gate}]")
    if n_fail:
        print(NO_TWEAK)
    return 1 if n_fail else 0


def build_table(doc, src, src_sha):
    lines = [f"<!-- GENERATED from {src} sha256:{src_sha} by ue-cocos-anchors-codex.py render — DO NOT EDIT BY HAND -->",
             f"### Anchors — {doc['fx']} ({doc['sessionId']})", "",
             "| id | at | expected | tolerance | units | UE source | DD |",
             "|---|---|---|---|---|---|---|"]
    for a in doc["anchors"]:
        at = a["at"]
        ct = at.get("cycleTime")
        at_s = f"t={ct}" if ct is not None else f"tick={at.get('tick')}"
        tol = a["tolerance"]
        tol_s = "exact" if tol.get("exact") else " ".join(
            f"{k}={tol[k]}" for k in ("abs", "rel") if is_number(tol.get(k)))
        dd_s = a["dd"]["id"] if a.get("dd") else ""
        lines.append(f"| `{a['id']}` | {at_s} | `{json.dumps(a['expected'])}` | {tol_s} "
                     f"| {a['units']} | `{a['source']['file']}#{a['source']['path']}` | {dd_s} |")
    return "\n".join(lines) + "\n"


def cmd_render(argv):
    src = argv[0]
    out = check = None
    if len(argv) >= 3 and argv[1] == "-o":
        out = argv[2]
    elif len(argv) >= 3 and argv[1] == "--check":
        check = argv[2]
    with open(src, "rb") as f:
        src_sha = hashlib.sha256(f.read()).hexdigest()
    doc = load(src)
    fails = []
    validate(doc, fails)
    if fails:
        for f in fails:
            print(f"FAIL {f}", file=sys.stderr)
        return 1
    expected_text = build_table(doc, src, src_sha)
    if check is not None:
        try:
            actual_text = open(check, "r", encoding="utf-8").read()
        except OSError as e:
            print(f"FAIL cannot read generated table: {e}")
            return 1
        if actual_text == expected_text:
            print(f"CURRENT: generated table is byte-identical to a fresh render "
                  f"(anchors sha {src_sha[:16]}…)")
            return 0
        print(f"FAIL generated table is STALE or hand-made: content differs from a fresh render "
              f"of the current anchors file (sha {src_sha[:16]}…) — copying the header digest "
              f"does not help; re-run render")
        return 1
    text = expected_text
    if out:
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"rendered {len(doc['anchors'])} anchors -> {out}")
    else:
        print(text, end="")
    return 0


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cmd, argv = sys.argv[1], sys.argv[2:]
    try:
        if cmd == "validate":
            return cmd_validate(argv)
        if cmd == "compare" and len(argv) >= 2:
            return cmd_compare(argv)
        if cmd == "render":
            return cmd_render(argv)
    except (ValueError, json.JSONDecodeError) as e:
        print(f"FAIL input file rejected: {e}")
        return 1
    except OSError as e:
        print(f"FAIL cannot read input: {e}")
        return 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
