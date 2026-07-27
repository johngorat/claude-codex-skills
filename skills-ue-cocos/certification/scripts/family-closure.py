#!/usr/bin/env python3
"""family-closure.py — family-pack certification closure (PORT-V2 design §2).

Subcommands:
  hash   <pack.json> [-o certification.json]        compute closure manifest + sha256
                                                    (coverage matrix must pass first)
  verify <pack.json> <certification.json>           recompute and compare component-by-
         [--approved-closure <sha256>]              component; CURRENT or STALE, exit 1
                                                    on STALE/FAIL; --approved-closure
                                                    binds to the sha recorded in the
                                                    gate report (GATED), else UNGATED
  matrix <pack.json>                                 feature×fixture coverage, exit 1 on gaps

Stdlib only. This script — not prose — owns the certification rules.

THE CLOSURE covers everything that can change what the oracle means: profile
doc, features file, data files, every fixture's bytes, executed code, the
pack identity (contract + family), declared entrypoints and invocation
templates, declared source/target identities, interpreter identity (version +
binary sha256), and privacy-safe env VALUE digests (domain-separated from
"unset") for the declared variables PLUS the pinned interpreter-state set
(PYTHONPATH, PYTHONHASHSEED, PYTHONUTF8, PYTHONSTARTUP, LANG, LC_ALL,
LC_CTYPE) — a
certification run additionally requires a pinned PYTHONHASHSEED.

PACK CODE IS ALLOWLISTED, not denylisted — everything not explicitly
recognized fails closed:
  - importable stdlib modules: json, os, sys, re, math, hashlib, itertools,
    collections, functools, struct; anything else — importlib, pathlib, io,
    runpy, builtins, ctypes, subprocess, third-party, unresolvable — FAILS.
    Widening this list is a gated edit;
  - NO import aliasing anywhere (`import x as y`, `from m import n as k`) and
    NO from-imports of stdlib modules (qualified access only) — aliases make
    static tracking unsound;
  - the code walk runs PER ENTRYPOINT, with that entrypoint's own directory
    as the single import root (the sys.path[0] model of its invocation) —
    imports never resolve into another entrypoint's directory; every walked
    file must be symlink-contained under the pack root; relative imports
    FAIL; `import pkg.mod` / `from pkg import name` pull every parent
    __init__.py plus the submodule into the closure;
  - file reads: ONLY read-only `open(os.path.join(os.path.dirname(__file__),
    <literals...>), 'r'|'rb')` resolving to a declared, EXISTING file, with
    at most two positional arguments; text mode REQUIRES a literal encoding
    (locale independence); write modes FAIL (derived output must never
    overwrite the oracle); `open` used as a value FAILS; `__file__` is legal
    ONLY inside that read expression; os.path pure string functions (join,
    dirname, basename, normpath, split, splitext — called directly; relpath
    is NOT allowlisted, it consults the cwd) are the only allowlisted os
    surface besides the environ forms below;
  - environment: ONLY `os.environ['LIT']`, `os.environ.get('LIT')`,
    `os.getenv('LIT')` with literal declared names; enumeration, membership,
    aliasing (`from os import environ`, `e = os.environ`, `import os as o`,
    `getattr(os, ...)`) FAIL; banned builtins include exec/eval/compile/
    __import__/input/breakpoint, the introspection family, and hash/id
    (hash-seed-dependent); sys is positively allowlisted (argv, exit,
    version ONLY — no stdin/stdout/stderr ambient queries, no import state,
    no executable path);
  - processes: NOT SUPPORTED in this contract — any subprocess import,
    os.system/os.popen, or 'subprocesses' manifest key FAILS closed; process
    launch returns with the runtime-enforcement layer (phase 2+), which can
    bind inherited stdin/env/PATH and interpreter semantics that static
    analysis cannot. Invocation cwds must exist inside the pack without
    symlinks.

CERTIFICATION DISCIPLINE: a certification is issued only over a pack whose
coverage matrix passes (every declared feature exercised by >=1 fixture,
every DECLARED interacting pair covered, no undeclared features, features
file schema-closed). verify authenticates the certificate itself (components
must reproduce closureSha256), reports CURRENT only on full map equality, and
carries the GATED/UNGATED marker for --approved-closure (same discipline as
the anchors contract's --approved-sha). Execution-world identity beyond the
closure (OS/driver class) is RECORDED but EXCLUDED from the invalidating
hash — USER decision 2026-07-24 on design ledger #6; the mitigation for the
residual is the per-port UE-capture escalation.
"""
import ast
import hashlib
import json
import os
import re
import sys

PACK_CONTRACT = "ue-cocos-family-pack/v1"
CERT_CONTRACT = "ue-cocos-family-certification/v1"
NAME_RE = re.compile(r"^[a-z0-9_]+$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
ALLOWED_STDLIB = {"json", "os", "sys", "re", "math", "hashlib", "itertools",
                  "collections", "functools", "struct"}
ALLOWED_OS_ATTRS = {"path", "environ", "getenv"}
SAFE_OS_PATH = {"join", "dirname", "basename", "normpath", "split",
                "splitext"}  # pure string functions only — no filesystem queries,
                             # no cwd (relpath consults it), no env expansion
SAFE_SYS_ATTRS = {"argv", "exit", "version"}  # stdout/stderr excluded: isatty()
                                              # etc. are ambient inputs; print()
                                              # remains the output mechanism
BANNED_BUILTINS = {"exec", "eval", "compile", "__import__", "input", "breakpoint",
                   "globals", "locals", "vars", "getattr", "setattr", "delattr",
                   "hash", "id"}  # hash/id depend on the per-process hash seed /
                                  # object identity — nondeterministic oracle inputs
SAFE_OPEN_MODES = {"r", "rb"}
# Interpreter-state env vars pinned into EVERY closure: they change import
# resolution, text decoding, locale-dependent matching, and hash iteration
# order without touching any file. LC_CTYPE outranks LANG when LC_ALL is unset.
PINNED_ENV = ("PYTHONPATH", "PYTHONHASHSEED", "PYTHONUTF8", "PYTHONSTARTUP",
              "LANG", "LC_ALL", "LC_CTYPE")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_json(path):
    def _reject(c):
        raise ValueError(f"non-finite JSON literal '{c}' rejected")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f, parse_constant=_reject)


def load_pack(path, fails):
    try:
        doc = load_json(path)
    except (OSError, ValueError) as e:
        fails.append(f"pack manifest unreadable/malformed: {e}")
        return None
    if not isinstance(doc, dict) or doc.get("pack") != PACK_CONTRACT:
        fails.append(f"pack manifest must declare \"pack\": \"{PACK_CONTRACT}\"")
        return None
    allowed = {"pack", "family", "profileDoc", "featuresFile", "entrypoints", "dataFiles",
               "fixturesDir", "sourceIdentity", "targetIdentity", "env", "invocations"}
    if "subprocesses" in doc:
        fails.append("'subprocesses' — process launch was REMOVED from this contract "
                     "pending the runtime-enforcement phase (static analysis cannot "
                     "bind inherited stdin/env/PATH or interpreter semantics); any "
                     "subprocess use in pack code fails closed")
    for k in doc:
        if k not in allowed and k != "subprocesses":
            fails.append(f"unknown pack key '{k}' — the manifest has no such field")
    fam = doc.get("family")
    if not isinstance(fam, str) or not NAME_RE.match(fam):
        fails.append(f"'family' must match {NAME_RE.pattern}")
    for key in ("profileDoc", "featuresFile", "fixturesDir"):
        if not isinstance(doc.get(key), str) or not doc.get(key):
            fails.append(f"'{key}' must be a non-empty relative path")
    for key in ("entrypoints", "dataFiles"):
        v = doc.get(key)
        if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
            fails.append(f"'{key}' must be a list of relative paths")
        elif key == "entrypoints" and not v:
            fails.append("'entrypoints' must not be empty — the executed-code closure "
                         "walks from here")
    for key in ("sourceIdentity", "targetIdentity"):
        v = doc.get(key)
        if not isinstance(v, dict) or not v or \
                not all(isinstance(x, str) and x for x in v.values()):
            fails.append(f"'{key}' must be a non-empty object of non-empty strings "
                         f"(fixtures certify a specific pair of worlds)")
    env = doc.get("env", [])
    if not isinstance(env, list) or not all(isinstance(x, str) and x for x in env):
        fails.append("'env' must be a list of environment variable names")
    def bad_rel(p):
        # forward-relative POSIX paths only: absolute, backslash, drive/UNC forms,
        # and ANY raw '..' component (checked BEFORE normalization — normpath would
        # silently swallow internal 'a/../b' traversals) all fail
        return (os.path.isabs(p) or "\\" in p or ":" in p
                or ".." in p.split("/"))
    for field, values in (("profileDoc", [doc.get("profileDoc")]),
                          ("featuresFile", [doc.get("featuresFile")]),
                          ("fixturesDir", [doc.get("fixturesDir")]),
                          ("dataFiles", doc.get("dataFiles", [])),
                          ("entrypoints", doc.get("entrypoints", []))):
        for v in values:
            if isinstance(v, str) and v and bad_rel(v):
                fails.append(f"'{field}' path '{v}' must stay INSIDE the pack (no "
                             f"absolute paths, no '..') — external content would leak "
                             f"foreign path names into component keys and break "
                             f"containment; fails closed")
    inv = doc.get("invocations")
    ok_inv = isinstance(inv, list) and inv and all(
        isinstance(i, dict) and set(i) <= {"entrypoint", "argv", "cwd"}
        and isinstance(i.get("entrypoint"), str)
        and isinstance(i.get("argv", []), list)
        and all(isinstance(a, str) for a in i.get("argv", []))
        and isinstance(i.get("cwd", "."), str)
        for i in inv)
    if not ok_inv:
        fails.append("'invocations' is REQUIRED: a non-empty list of {entrypoint, argv?, "
                     "cwd?} — running the same hashed entrypoint with different arguments "
                     "changes oracle output, so the invocation contract is part of the "
                     "closure (design §2)")
    elif isinstance(doc.get("entrypoints"), list):
        invoked = {i["entrypoint"] for i in inv}
        for i in inv:
            if i["entrypoint"] not in doc["entrypoints"]:
                fails.append(f"invocation entrypoint '{i['entrypoint']}' is not in "
                             f"'entrypoints'")
            cwd = i.get("cwd", ".")
            if bad_rel(cwd):
                fails.append(f"invocation cwd '{cwd}' must stay inside the pack (no "
                             f"absolute paths, no '..') — fails closed")
        for e in doc["entrypoints"]:
            if e not in invoked:
                fails.append(f"entrypoint '{e}' has no invocation — an executable root "
                             f"without an invocation contract is an undeclared way to "
                             f"run the pack")
    return None if fails else doc


def contained(path, pack_dir, what, fails):
    """Symlink-resolved containment: hashed content must live under the pack."""
    rp, root = os.path.realpath(path), os.path.realpath(pack_dir)
    if rp == root or rp.startswith(root + os.sep):
        return True
    fails.append(f"{what} escapes the pack root after symlink resolution — external "
                 f"content in the closure breaks containment; fails closed")
    return False


def is_declared_read(rel, pack):
    rel = os.path.normpath(rel)
    declared = {os.path.normpath(p) for p in pack.get("dataFiles", [])}
    declared.add(os.path.normpath(pack["profileDoc"]))
    declared.add(os.path.normpath(pack["featuresFile"]))
    if rel in declared:
        return True
    fdir = os.path.normpath(pack["fixturesDir"])
    return rel == fdir or rel.startswith(fdir + os.sep)


# Sourceless bytecode + native extensions: CPython can execute them, the walker
# cannot read them. Taken from the running interpreter's own machinery so
# ABI-tagged forms (e.g. .cpython-XY-darwin.so, .abi3.so) are covered exactly.
import importlib.machinery as _machinery  # tool-side import; pack code still
                                          # cannot import importlib (allowlist)
NONSOURCE_SUFFIXES = tuple(sorted(
    set(_machinery.EXTENSION_SUFFIXES) | set(_machinery.BYTECODE_SUFFIXES),
    key=len, reverse=True))


def resolve_local_module(name, root):
    """Package-aware resolve of a dotted name against ONE entrypoint root (the
    sys.path[0] model of the invocation that reaches this module — never the
    importer's own directory). Returns the list of executed files (parent
    __init__.py chain + module), None when the name is not local to root,
    'ambiguous' on a package/module clash, or 'nonsource' when any bytecode/
    native candidate exists for the name (fails closed: FileFinder could
    execute it in preference to — or in the absence of — the hashed source)."""
    parts = name.split(".")
    files = []
    for depth in range(1, len(parts) + 1):
        prefix = parts[:depth]
        stem = os.path.join(root, *prefix)
        for suf in NONSOURCE_SUFFIXES:
            if os.path.isfile(stem + suf) or \
                    os.path.isfile(os.path.join(stem, "__init__" + suf)):
                return "nonsource"
        pkg_init = os.path.join(root, *prefix, "__init__.py")
        mod_py = os.path.join(root, *prefix) + ".py"
        if depth < len(parts):
            if os.path.isfile(pkg_init):
                files.append(os.path.realpath(pkg_init))
            else:
                return None
        else:
            has_pkg, has_mod = os.path.isfile(pkg_init), os.path.isfile(mod_py)
            if has_pkg and has_mod:
                # CPython's FileFinder prefers the package; a coexisting module
                # is a latent divergence between hashed and executed code
                return "ambiguous"
            if has_pkg:
                files.append(os.path.realpath(pkg_init))
            elif has_mod:
                files.append(os.path.realpath(mod_py))
            else:
                return None
    return files


def _const_str(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _is_os_attr(node, attr):
    return isinstance(node, ast.Attribute) and node.attr == attr and \
        isinstance(node.value, ast.Name) and node.value.id == "os"


def _is_os_path_attr(node):
    return isinstance(node, ast.Attribute) and node.attr == "path" and \
        isinstance(node.value, ast.Name) and node.value.id == "os"


def _is_dirname_file(node):
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "dirname" and _is_os_path_attr(node.func.value)
            and len(node.args) == 1 and isinstance(node.args[0], ast.Name)
            and node.args[0].id == "__file__")


def resolve_read_arg(node, file_dir, pack_dir):
    """The ONLY accepted open() path form:
    os.path.join(os.path.dirname(__file__), <literals...>) — cwd-independent
    by construction. Returns ('rel', relpath) | ('fail', reason)."""
    if _const_str(node) is not None:
        return "fail", ("bare literal path is cwd-dependent (the declared invocation "
                        "cwd can move it); use "
                        "open(os.path.join(os.path.dirname(__file__), <literals>))")
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and \
            node.func.attr == "join" and _is_os_path_attr(node.func.value):
        args = node.args
        if args and _is_dirname_file(args[0]):
            parts = []
            for a in args[1:]:
                s = _const_str(a)
                if s is None:
                    return "fail", "join() with a non-literal component"
                parts.append(s)
            resolved = os.path.realpath(os.path.join(file_dir, *parts))
            root = os.path.realpath(pack_dir)
            if resolved == root or resolved.startswith(root + os.sep):
                return "rel", os.path.relpath(resolved, root)
            return "fail", "resolved path escapes the pack root"
    return "fail", "path expression is not statically resolvable"


def _is_call_func(node, parents):
    par = parents.get(node)
    return isinstance(par, ast.Call) and par.func is node


def scan_module(tree, rel, file_dir, pack_dir, pack, fails):
    """Allowlist enforcement over one module's execution surface (design §2).
    Sensitive names are accepted ONLY in explicitly recognized contexts —
    used as values, aliased, or reached through unknown attributes they fail
    closed. Everything not explicitly recognized fails closed."""
    declared_env = set(pack.get("env", []))
    parents = {}
    for node in ast.walk(tree):
        for child in ast.iter_child_nodes(node):
            parents[child] = node
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            for a in node.names:
                if a.asname is not None:
                    fails.append(f"{rel}: import aliasing ('{a.name} as {a.asname}') "
                                 f"makes static tracking unsound; fails closed")
        if isinstance(node, ast.ImportFrom) and node.module and \
                node.module.split(".")[0] == "os":
            fails.append(f"{rel}: 'from os import …' — aliased os access fails closed "
                         f"(qualified os.… forms only)")
        if isinstance(node, ast.Name):
            nid = node.id
            if nid == "open" and not _is_call_func(node, parents):
                fails.append(f"{rel}: builtin 'open' used as a value — aliased file IO "
                             f"is opaque; fails closed")
            elif nid in BANNED_BUILTINS:
                fails.append(f"{rel}: builtin '{nid}' is banned in pack code — dynamic "
                             f"execution/introspection/stdin surfaces break the "
                             f"closure; fails closed")
            elif nid == "__file__":
                ok = False
                par = parents.get(node)
                if isinstance(par, ast.Call) and _is_dirname_file(par):
                    join_call = parents.get(par)
                    if isinstance(join_call, ast.Call) and \
                            isinstance(join_call.func, ast.Attribute) and \
                            join_call.func.attr == "join" and \
                            _is_os_path_attr(join_call.func.value) and \
                            join_call.args and join_call.args[0] is par:
                        open_call = parents.get(join_call)
                        ok = (isinstance(open_call, ast.Call)
                              and isinstance(open_call.func, ast.Name)
                              and open_call.func.id == "open"
                              and open_call.args and open_call.args[0] is join_call)
                if not ok:
                    fails.append(f"{rel}: __file__ outside the FULL recognized "
                                 f"declared-read chain open(os.path.join(os.path."
                                 f"dirname(__file__), …)) — a path-valued input makes "
                                 f"identical packs behave differently by location; "
                                 f"fails closed")
            elif nid in ("os", "sys"):
                par = parents.get(node)
                is_attr_base = isinstance(par, ast.Attribute) and par.value is node
                is_import = isinstance(par, (ast.Import, ast.ImportFrom))
                if not (is_attr_base or is_import):
                    fails.append(f"{rel}: module '{nid}' used as a value — aliasing "
                                 f"makes static tracking unsound; fails closed")
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
            base, attr = node.value.id, node.attr
            if base == "os":
                if attr not in ALLOWED_OS_ATTRS:
                    fails.append(f"{rel}: os.{attr} is not an allowlisted os surface "
                                 f"(allowed: os.path.<pure string fns>, os.environ "
                                 f"literal forms, os.getenv) — fails closed")
                elif attr == "getenv" and not _is_call_func(node, parents):
                    fails.append(f"{rel}: os.getenv used as a value — aliasing fails "
                                 f"closed")
                elif attr == "path":
                    par = parents.get(node)
                    if not (isinstance(par, ast.Attribute) and par.value is node
                            and par.attr in SAFE_OS_PATH):
                        got = par.attr if isinstance(par, ast.Attribute) else "a value"
                        fails.append(f"{rel}: os.path.{got} — only the pure string "
                                     f"functions ({', '.join(sorted(SAFE_OS_PATH))}) "
                                     f"are allowlisted; filesystem queries, cwd, and "
                                     f"env expansion are undeclared semantic inputs; "
                                     f"fails closed")
                    else:
                        grand = parents.get(par)
                        if not (isinstance(grand, ast.Call) and grand.func is par):
                            fails.append(f"{rel}: os.path.{par.attr} used as a value — "
                                         f"aliasing fails closed")
            elif base == "sys" and attr not in SAFE_SYS_ATTRS:
                fails.append(f"{rel}: sys.{attr} is not an allowlisted sys surface "
                             f"({', '.join(sorted(SAFE_SYS_ATTRS))}) — stdin, import "
                             f"state, module tables, and path-valued executables are "
                             f"outside the closure; fails closed")
        if _is_os_attr(node, "environ"):
            par = parents.get(node)
            ok = isinstance(par, ast.Subscript) and par.value is node
            if isinstance(par, ast.Attribute) and par.value is node and par.attr == "get":
                ok = _is_call_func(par, parents)
            if not ok:
                fails.append(f"{rel}: os.environ used outside the literal-key read forms "
                             f"(subscript / .get('LIT')) — enumeration, membership, or "
                             f"aliasing is opaque; fails closed")
        if isinstance(node, ast.Assign):
            vals = node.value.elts if isinstance(node.value, ast.Tuple) else [node.value]
            if any(_is_os_attr(v, "environ") for v in vals):
                fails.append(f"{rel}: assigning os.environ itself to a name — aliasing "
                             f"makes environment access opaque; fails closed")
        if isinstance(node, ast.Call):
            fn = node.func
            if isinstance(fn, ast.Attribute) and fn.attr == "__import__":
                fails.append(f"{rel}: __import__ found — dynamic import fails closed")
            if isinstance(fn, ast.Name) and fn.id == "open":
                kind, val = resolve_read_arg(node.args[0], file_dir, pack_dir) \
                    if node.args else ("fail", "open() with no arguments")
                if len(node.args) > 2:
                    fails.append(f"{rel}: open() with more than two positional "
                                 f"arguments — positional buffering/opener parameters "
                                 f"can redirect IO (e.g. an opener returning fd 0); "
                                 f"fails closed")
                mode = _const_str(node.args[1]) if len(node.args) > 1 else "r"
                has_encoding = False
                for k in node.keywords:
                    if k.arg == "mode":
                        mode = _const_str(k.value)
                    elif k.arg == "encoding" and _const_str(k.value) is not None:
                        has_encoding = True
                    else:
                        fails.append(f"{rel}: open() keyword '{k.arg}' — only a "
                                     f"literal encoding is accepted (openers/buffering "
                                     f"change IO semantics); fails closed")
                if mode == "r" and not has_encoding:
                    fails.append(f"{rel}: open() in text mode without a literal "
                                 f"encoding — decoding would depend on locale/"
                                 f"PYTHONUTF8 state outside the closure; pass "
                                 f"encoding='…' or use 'rb'; fails closed")
                if mode not in SAFE_OPEN_MODES:
                    fails.append(f"{rel}: open() mode {mode!r} — pack code may only "
                                 f"READ ({'/'.join(sorted(SAFE_OPEN_MODES))}); writing "
                                 f"could overwrite the independent oracle with derived "
                                 f"output; fails closed")
                if kind == "fail":
                    fails.append(f"{rel}: open() — {val}; reading outside the manifest "
                                 f"fails closed")
                elif not is_declared_read(val, pack):
                    fails.append(f"{rel}: open() resolves to '{val}' which is not "
                                 f"declared (dataFiles/profileDoc/featuresFile/"
                                 f"fixturesDir) — fails closed")
                elif not os.path.isfile(os.path.join(pack_dir, val)):
                    fails.append(f"{rel}: open() resolves to '{val}' which does not "
                                 f"exist at certification time — it cannot be in the "
                                 f"component map; fails closed")
            if isinstance(fn, ast.Attribute) and fn.attr == "get" and \
                    _is_os_attr(fn.value, "environ"):
                key = _const_str(node.args[0]) if node.args else None
                _check_env(key, rel, declared_env, fails, "os.environ.get")
            if isinstance(fn, ast.Attribute) and fn.attr == "getenv" and \
                    isinstance(fn.value, ast.Name) and fn.value.id == "os":
                key = _const_str(node.args[0]) if node.args else None
                _check_env(key, rel, declared_env, fails, "os.getenv")
        if isinstance(node, ast.Subscript) and _is_os_attr(node.value, "environ"):
            key = _const_str(node.slice)
            _check_env(key, rel, declared_env, fails, "os.environ[...]")


def _check_env(key, rel, declared_env, fails, how):
    if key is None:
        fails.append(f"{rel}: {how} with a non-literal key — opaque environment access "
                     f"fails closed (declare and read literal names)")
    elif key not in declared_env:
        fails.append(f"{rel}: {how}('{key}') is not declared in the pack manifest 'env' "
                     f"list — reading outside the manifest fails closed")


def walk_code(pack_dir, pack, fails):
    """Transitive package-aware import walk, run SEPARATELY per entrypoint with
    that entrypoint's own directory as the single import root (the sys.path[0]
    model of its invocation — one entrypoint's imports never resolve into
    another entrypoint's directory). Returns ({rel: sha}, stdlib)."""
    root_realpath = os.path.realpath(pack_dir)
    seen, stdlib_used, scanned = {}, set(), set()
    for e in pack["entrypoints"]:
        start = os.path.realpath(os.path.join(pack_dir, e))
        if not os.path.isfile(start):
            fails.append(f"entrypoint '{e}' not found")
            continue
        if not start.startswith(root_realpath + os.sep):
            fails.append(f"entrypoint '{e}' escapes the pack root — fails closed")
            continue
        root = os.path.dirname(start)
        queue, visited = [start], set()
        while queue:
            path = queue.pop()
            if path in visited:
                continue
            visited.add(path)
            if not contained(path, pack_dir,
                             f"imported code file '{os.path.basename(path)}'", fails):
                continue
            rel = os.path.relpath(path, pack_dir)
            seen[rel] = sha256_file(path)
            try:
                tree = ast.parse(open(path, "r", encoding="utf-8").read(), filename=rel)
            except SyntaxError as err:
                if rel not in scanned:
                    scanned.add(rel)
                    fails.append(f"{rel}: unparseable ({err}) — no closure over code "
                                 f"that cannot be read")
                continue
            if rel not in scanned:
                scanned.add(rel)
                scan_module(tree, rel, os.path.dirname(path), pack_dir, pack, fails)
            for node in ast.walk(tree):
                targets = []
                if isinstance(node, ast.Import):
                    targets = [(a.name, None) for a in node.names]
                elif isinstance(node, ast.ImportFrom):
                    if node.level and node.level > 0:
                        fails.append(f"{rel}: relative import — pack code uses absolute "
                                     f"module names resolvable from its entrypoint "
                                     f"root; fails closed")
                        continue
                    targets = [(node.module or "", [a.name for a in node.names])]
                for name, from_names in targets:
                    if not name:
                        continue
                    top = name.split(".")[0]
                    local = resolve_local_module(name, root)
                    if local == "ambiguous":
                        fails.append(f"{rel}: import '{name}' matches BOTH a package "
                                     f"and a module under this root — hashed code "
                                     f"could diverge from executed code; fails closed")
                        continue
                    if local == "nonsource":
                        fails.append(f"{rel}: import '{name}' has bytecode/native-"
                                     f"extension candidates "
                                     f"({'/'.join(NONSOURCE_SUFFIXES)}) under this "
                                     f"root — CPython could execute what the walker "
                                     f"cannot read; only source .py files enter the "
                                     f"closure; fails closed")
                        continue
                    if local is not None:
                        queue.extend(local)
                        if from_names and local[-1].endswith("__init__.py"):
                            for fn_name in from_names:
                                sub = resolve_local_module(f"{name}.{fn_name}", root)
                                if isinstance(sub, list):
                                    queue.extend(sub)
                                elif sub in ("ambiguous", "nonsource"):
                                    fails.append(f"{rel}: 'from {name} import "
                                                 f"{fn_name}' resolves to an "
                                                 f"{sub} candidate — fails closed")
                        continue
                    if from_names is not None:
                        fails.append(f"{rel}: 'from {name} import …' does not resolve "
                                     f"to pack code from root '{os.path.relpath(root, pack_dir)}' "
                                     f"— from-imports of stdlib/external modules are "
                                     f"aliasing; qualified access only; fails closed")
                        continue
                    if top == "subprocess":
                        fails.append(f"{rel}: imports subprocess — process launch was "
                                     f"REMOVED from this contract pending the "
                                     f"runtime-enforcement phase (inherited stdin/env/"
                                     f"PATH and interpreter semantics cannot be bound "
                                     f"statically); fails closed")
                        continue
                    if top in ALLOWED_STDLIB:
                        stdlib_used.add(top)
                    else:
                        fails.append(f"{rel}: import of '{name}' — module '{top}' does "
                                     f"not resolve to pack code from this entrypoint's "
                                     f"root and is not in the allowlisted stdlib set "
                                     f"({', '.join(sorted(ALLOWED_STDLIB))}); "
                                     f"everything else is opaque to the closure walker "
                                     f"and fails closed (widening the list is a gated "
                                     f"edit)")
    return seen, sorted(stdlib_used)


def run_matrix(pack_dir, pack):
    """Feature×fixture coverage. Returns (problems, report_lines)."""
    problems, lines = [], []
    fpath = os.path.join(pack_dir, pack["featuresFile"])
    fdir = os.path.join(pack_dir, pack["fixturesDir"])
    if not contained(fpath, pack_dir, f"features file '{pack['featuresFile']}'",
                     problems) or \
            not contained(fdir, pack_dir, f"fixturesDir '{pack['fixturesDir']}'",
                          problems):
        return problems, lines
    try:
        feats_doc = load_json(fpath)
    except (OSError, ValueError) as e:
        return [f"features file unreadable/malformed: {e}"], lines
    if not isinstance(feats_doc, dict):
        return ["features file must be a JSON object"], lines
    for k in feats_doc:
        if k not in ("features", "interactions"):
            problems.append(f"features file: unknown key '{k}' — the contract has no "
                            f"such field (a typo here silently drops declarations)")
    features = feats_doc.get("features")
    inter = feats_doc.get("interactions", [])
    if not isinstance(features, list) or not features or \
            not all(isinstance(x, str) and NAME_RE.match(x) for x in features):
        problems.append(f"'features' must be a non-empty list of names matching "
                        f"{NAME_RE.pattern}")
        return problems, lines
    if len(set(features)) != len(features):
        problems.append("'features' contains duplicates")
    if not isinstance(inter, list) or not all(
            isinstance(p, list) and len(p) == 2 and p[0] != p[1]
            and all(x in features for x in p) for p in inter):
        problems.append("'interactions' must be pairs of two DISTINCT declared features")
        return problems, lines
    pairs = [tuple(sorted(p)) for p in inter]
    if len(set(pairs)) != len(pairs):
        problems.append("'interactions' contains duplicate pairs")
    covered = {f: [] for f in features}
    pair_covered = {p: [] for p in pairs}
    n_fix = 0
    for root, _, files in os.walk(fdir):
        for name in sorted(files):
            if name != "fixture.json":
                continue
            n_fix += 1
            rel = os.path.relpath(os.path.join(root, name), pack_dir)
            if not contained(os.path.join(root, name), pack_dir,
                             f"fixture manifest '{rel}'", problems):
                continue
            try:
                fx = load_json(os.path.join(root, name))
            except (OSError, ValueError) as e:
                problems.append(f"{rel}: unreadable/malformed: {e}")
                continue
            covers = fx.get("covers") if isinstance(fx, dict) else None
            if not isinstance(covers, list) or not covers:
                problems.append(f"{rel}: 'covers' must be a non-empty list of declared "
                                f"features")
                continue
            for c in covers:
                if c not in covered:
                    problems.append(f"{rel}: covers undeclared feature '{c}' — features "
                                    f"are declared in {pack['featuresFile']}, never ad "
                                    f"hoc (no third state)")
                else:
                    covered[c].append(rel)
            for pair in pair_covered:
                if pair[0] in covers and pair[1] in covers:
                    pair_covered[pair].append(rel)
    if n_fix == 0:
        problems.append(f"no fixture.json found under '{pack['fixturesDir']}'")
    for f, by in sorted(covered.items()):
        if not by:
            problems.append(f"feature '{f}' is not exercised by any fixture — an "
                            f"unexercised feature is NOT CERTIFIED; a port touching it "
                            f"must DD or block")
        else:
            lines.append(f"  coverage: {f} — {len(by)} fixture(s)")
    for pair, by in sorted(pair_covered.items()):
        if not by:
            problems.append(f"declared interaction {pair[0]}×{pair[1]} has no fixture "
                            f"covering both — pairwise coverage of DECLARED interactions "
                            f"is the floor")
        else:
            lines.append(f"  interaction: {pair[0]}×{pair[1]} — {len(by)} fixture(s)")
    lines.append("  NOTE: full combinatorial coverage is explicitly NOT claimed; "
                 "undeclared interactions found later become blocking additions with "
                 "n-ary fixtures.")
    return problems, lines


def collect_components(pack_dir, pack, fails):
    """Everything semantic → {kind/relpath: sha256}. Matrix must pass first."""
    problems, _ = run_matrix(pack_dir, pack)
    for p in problems:
        fails.append(f"matrix: {p} — a certification is never issued over an "
                     f"unverified coverage matrix")
    if os.environ.get("PYTHONPATH"):
        fails.append("PYTHONPATH is set — the single-root import contract forbids "
                     "external import roots (an injected module could shadow an "
                     "allowlisted stdlib name with code outside the closure); unset "
                     "it for certification runs")
    comp = {"declared:pack": sha256_text(json.dumps(
        {"pack": PACK_CONTRACT, "family": pack["family"]}, sort_keys=True)),
            # file ROLES are semantic: swapping profileDoc with a data file must
            # flip the closure even when the same byte sets are hashed
            "declared:files": sha256_text(json.dumps(
                {"profileDoc": pack["profileDoc"],
                 "featuresFile": pack["featuresFile"],
                 "fixturesDir": pack["fixturesDir"],
                 "dataFiles": sorted(pack.get("dataFiles", []))}, sort_keys=True))}
    for key in ("profileDoc", "featuresFile"):
        p = os.path.join(pack_dir, pack[key])
        if not os.path.isfile(p):
            fails.append(f"'{key}' file '{pack[key]}' not found")
        elif contained(p, pack_dir, f"'{key}' file '{pack[key]}'", fails):
            comp[f"file:{pack[key]}"] = sha256_file(p)
    for d in pack.get("dataFiles", []):
        p = os.path.join(pack_dir, d)
        if not os.path.isfile(p):
            fails.append(f"dataFiles entry '{d}' not found")
        elif contained(p, pack_dir, f"dataFiles entry '{d}'", fails):
            comp[f"file:{d}"] = sha256_file(p)
    fdir = os.path.join(pack_dir, pack["fixturesDir"])
    if not os.path.isdir(fdir):
        fails.append(f"fixturesDir '{pack['fixturesDir']}' not found")
    else:
        n = 0
        for root, _, files in os.walk(fdir):
            for name in sorted(files):
                p = os.path.join(root, name)
                rel = os.path.relpath(p, pack_dir)
                if contained(p, pack_dir, f"fixture file '{rel}'", fails):
                    comp[f"fixture:{rel}"] = sha256_file(p)
                n += 1
        if n == 0:
            fails.append(f"fixturesDir '{pack['fixturesDir']}' is empty — an oracle "
                         f"with no fixtures certifies nothing")
    code, stdlib_used = walk_code(pack_dir, pack, fails)
    for rel, sha in code.items():
        comp[f"code:{rel}"] = sha
    comp["declared:entrypoints"] = sha256_text(json.dumps(sorted(pack["entrypoints"])))
    comp["identity:source"] = sha256_text(json.dumps(pack["sourceIdentity"],
                                                     sort_keys=True))
    comp["identity:target"] = sha256_text(json.dumps(pack["targetIdentity"],
                                                     sort_keys=True))
    comp["identity:interpreter"] = sha256_text(json.dumps({
        "version": sys.version.split()[0],
        "binarySha256": sha256_file(os.path.realpath(sys.executable)),
        # execution flags change accepted-code semantics (assert/__debug__ under
        # -O, sys.path composition under -P, env trust under -E/-I) without
        # touching any file — bind EVERY public integer flag this interpreter
        # exposes (the set itself varies by version, which the version field
        # already distinguishes)
        "flags": {k: int(getattr(sys.flags, k)) for k in dir(sys.flags)
                  if not k.startswith("_") and k not in ("count", "index")
                  and isinstance(getattr(sys.flags, k), int)},
    }, sort_keys=True))
    if sys.flags.ignore_environment or sys.flags.isolated:
        fails.append("the interpreter runs with -E/-I (ignore_environment/isolated) — "
                     "environment variables CANNOT pin the hash seed in these modes, "
                     "so the recorded env components would not describe actual "
                     "execution; run certification without -E/-I")
    for i in pack["invocations"]:
        cwd = i.get("cwd", ".")
        cdir = os.path.join(pack_dir, cwd)
        expected = os.path.normpath(os.path.join(os.path.realpath(pack_dir), cwd))
        if not os.path.isdir(cdir):
            fails.append(f"invocation cwd '{cwd}' does not exist — an invocation "
                         f"contract over a missing directory certifies nothing")
        elif os.path.realpath(cdir) != expected:
            fails.append(f"invocation cwd '{cwd}' resolves through a symlink — the "
                         f"canonical directory must be the declared one (a retargeted "
                         f"link would move execution without changing the closure); "
                         f"fails closed")
    comp["declared:invocations"] = sha256_text(json.dumps(
        [[i["entrypoint"], i.get("argv", []), i.get("cwd", ".")]
         for i in pack["invocations"]], sort_keys=True))
    comp["declared:env"] = sha256_text(json.dumps(sorted(pack.get("env", []))))
    seed = os.environ.get("PYTHONHASHSEED")
    # CPython treats unset, 'random', AND an empty value as randomized; only a
    # decimal integer in 0..4294967295 actually pins the seed
    if seed is None or not seed.isdigit() or int(seed) > 4294967295:
        fails.append("PYTHONHASHSEED is not pinned in this environment (unset, "
                     "'random', empty, or out of range) — hash()/set iteration order "
                     "would be nondeterministic across certification and port runs; "
                     "export a fixed decimal seed in 0..4294967295 (e.g. "
                     "PYTHONHASHSEED=0) before hashing or verifying")
    for name in sorted(set(pack.get("env", [])) | set(PINNED_ENV)):
        value = os.environ.get(name)
        # domain separation: an unset variable can never collide with any value
        comp[f"env:{name}"] = sha256_text("unset" if value is None else "set:" + value)
    comp["meta:stdlib"] = sha256_text(json.dumps(stdlib_used))
    return comp


def closure_sha(components):
    return sha256_text(json.dumps(components, sort_keys=True))


def world_record(fails):
    """Execution-world info RECORDED for the certification, NOT hashed
    (USER decision on design ledger #6). The driver class cannot be discovered
    portably, so the certifying environment SUPPLIES it — record-only, but its
    absence fails closed (an empty world record would violate the ledger)."""
    import platform
    driver = os.environ.get("CERT_DRIVER_CLASS")
    if not driver:
        fails.append("CERT_DRIVER_CLASS is not set — design ledger #6 requires the "
                     "OS/driver class RECORDED in every certification (excluded from "
                     "the hash); export it, e.g. CERT_DRIVER_CLASS='metal-m2' — it "
                     "cannot be discovered portably")
    return {
        "osClass": f"{platform.system()} {platform.release()} {platform.machine()}",
        "driverClass": driver or "",
        "recordedOnly": True,
        "note": "excluded from closureSha256 by USER decision (ledger #6); "
                "mitigation for the residual is the per-port UE-capture escalation",
    }


def parse_flags(argv, value_flags=()):
    pos, flags, i = [], {}, 0
    while i < len(argv):
        arg = argv[i]
        if arg in value_flags:
            if i + 1 >= len(argv):
                return None, None, f"flag {arg} needs a value"
            flags[arg] = argv[i + 1]
            i += 2
        elif arg.startswith("-"):
            return None, None, f"unknown flag '{arg}'"
        else:
            pos.append(arg)
            i += 1
    return pos, flags, None


def cmd_hash(argv):
    pos, flags, err = parse_flags(argv, value_flags=("-o",))
    if err or len(pos) != 1:
        print(f"FAIL {err or 'hash takes exactly one pack.json'}")
        return 2
    fails = []
    pack = load_pack(pos[0], fails)
    comp = collect_components(os.path.dirname(os.path.realpath(pos[0])), pack, fails) \
        if pack else {}
    world = world_record(fails)
    if fails:
        for f in fails:
            print(f"FAIL {f}")
        print(f"INVALID: closure not computed, {len(fails)} problems")
        return 1
    cert = {
        "certification": CERT_CONTRACT,
        "family": pack["family"],
        "closureSha256": closure_sha(comp),
        "components": comp,
        "world": world,
    }
    text = json.dumps(cert, indent=1, sort_keys=True) + "\n"
    out = flags.get("-o")
    if out:
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"closure {cert['closureSha256'][:16]}… over {len(comp)} components -> {out}")
    else:
        print(text, end="")
    return 0


def cmd_verify(argv):
    pos, flags, err = parse_flags(argv, value_flags=("--approved-closure",))
    if err or len(pos) != 2:
        print(f"FAIL {err or 'verify takes pack.json and certification.json'}")
        return 2
    approved = flags.get("--approved-closure")
    if approved is not None and not SHA_RE.match(approved.lower()):
        print("FAIL --approved-closure must be a lowercase sha256 hex")
        return 2
    fails = []
    pack = load_pack(pos[0], fails)
    try:
        cert = load_json(pos[1])
    except (OSError, ValueError) as e:
        print(f"FAIL certification unreadable/malformed: {e}")
        return 1
    if not isinstance(cert, dict) or cert.get("certification") != CERT_CONTRACT:
        print(f"FAIL certification must declare \"certification\": \"{CERT_CONTRACT}\"")
        return 1
    if set(cert) != {"certification", "family", "closureSha256", "components", "world"}:
        print("FAIL certification envelope is not schema-closed — it must carry "
              "exactly certification/family/closureSha256/components/world "
              "(a stripped or extended certificate is not the issued artifact)")
        return 1
    w = cert.get("world")
    if not (isinstance(w, dict) and isinstance(w.get("osClass"), str) and w["osClass"]
            and isinstance(w.get("driverClass"), str) and w["driverClass"]
            and w.get("recordedOnly") is True):
        print("FAIL certification 'world' record missing or malformed — design ledger "
              "#6 requires the OS/driver class RECORDED (excluded from the hash, but "
              "never absent)")
        return 1
    old = cert.get("components")
    if not isinstance(old, dict) or not all(
            isinstance(k, str) and isinstance(v, str) and SHA_RE.match(v)
            for k, v in old.items()):
        print("FAIL certification components map missing or malformed")
        return 1
    if closure_sha(old) != cert.get("closureSha256"):
        print("FAIL certification is internally inconsistent: its components map does "
              "not reproduce its closureSha256 — a tampered or hand-edited certificate")
        return 1
    comp = collect_components(os.path.dirname(os.path.realpath(pos[0])), pack, fails) \
        if pack else {}
    if fails:
        for f in fails:
            print(f"FAIL {f}")
        print("INVALID: closure not computable — fix the pack before verifying")
        return 1
    if pack["family"] != cert.get("family"):
        print(f"FAIL family mismatch: pack '{pack['family']}' vs certification "
              f"'{cert.get('family')}'")
        return 1
    gate = "GATED" if approved is not None else \
        "UNGATED (no --approved-closure — a gate passes the sha recorded in the gate " \
        "report; the pack path on this CLI is caller-selected and proves nothing alone)"
    if approved is not None and closure_sha(comp) != approved.lower():
        print(f"FAIL recomputed closure {closure_sha(comp)[:16]}… does not match the "
              f"gate-approved closure {approved[:16]}… — the canonical certified pack "
              f"is not what this path points at; a stale copy cannot pass a gate")
        return 1
    if comp == old:
        print(f"CURRENT: closure {closure_sha(comp)[:16]}… matches the certification "
              f"({len(comp)} components) [{gate}]")
        return 0
    drift = sorted((set(comp) ^ set(old)) |
                   {k for k in set(comp) & set(old) if comp[k] != old[k]})
    for k in drift:
        state = "added" if k not in old else ("removed" if k not in comp else "changed")
        print(f"STALE {k}: {state}")
    print(f"STALE certification: {len(drift)} component(s) drifted — nothing semantic "
          f"sits outside the hash, so re-certify before porting [{gate}]")
    return 1


def cmd_matrix(argv):
    pos, flags, err = parse_flags(argv)
    if err or len(pos) != 1:
        print(f"FAIL {err or 'matrix takes exactly one pack.json'}")
        return 2
    fails = []
    pack = load_pack(pos[0], fails)
    if fails:
        for f in fails:
            print(f"FAIL {f}")
        return 1
    problems, lines = run_matrix(os.path.dirname(os.path.realpath(pos[0])), pack)
    for p in problems:
        print(f"FAIL {p}")
    for line in lines:
        print(line)
    status = "INCOMPLETE" if problems else "COVERED"
    print(f"{status}: {len(problems)} problems")
    return 1 if problems else 0


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cmd, argv = sys.argv[1], sys.argv[2:]
    try:
        if cmd == "hash":
            return cmd_hash(argv)
        if cmd == "verify":
            return cmd_verify(argv)
        if cmd == "matrix":
            return cmd_matrix(argv)
    except (ValueError, json.JSONDecodeError) as e:
        print(f"FAIL input rejected: {e}")
        return 1
    except OSError as e:
        print(f"FAIL cannot read input: {e}")
        return 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
