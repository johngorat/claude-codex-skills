#!/usr/bin/env python3
"""Fixture suite for family-closure.py. Stdlib only.

Run: python3 tests/run-fixtures.py            (exit 0 = all green)

tests/fixtures/minipack is a tiny but complete family pack (local + package
import chains, declared env/file-read/invocations). Each case copies it into
a mktemp dir and applies at most ONE mutation, so every FAIL mode is
demonstrated by a fixture that fails while the defect is present and passes
without it.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "scripts", "family-closure.py")
MINIPACK = os.path.join(HERE, "fixtures", "minipack")
TMP = tempfile.mkdtemp(prefix="closure-fixtures-")
WRONG_SHA = "0" * 64
n_pass, n_fail = 0, 0
_seq = 0


def pack_copy(mutate=None):
    global _seq
    _seq += 1
    dst = os.path.join(TMP, f"pack{_seq}")
    shutil.copytree(MINIPACK, dst)
    if mutate:
        mutate(dst)
    return dst


def run(args, env=None):
    # deterministic base environment: MINI_ENV is set ONLY by the drift cases;
    # PYTHONPATH is normalized out; PYTHONHASHSEED is pinned (the tool itself
    # requires a pinned seed for any certification run)
    base = dict(os.environ)
    base.pop("MINI_ENV", None)
    base.pop("PYTHONPATH", None)
    base["PYTHONHASHSEED"] = "0"
    base["CERT_DRIVER_CLASS"] = "test-driver"
    if env:
        base.update(env)
    p = subprocess.run([sys.executable, SCRIPT] + args,
                       capture_output=True, text=True, env=base)
    return p.returncode, p.stdout + p.stderr


def case(name, args, expect_exit, contains=(), forbids=(), env=None):
    global n_pass, n_fail
    code, out = run(args, env=env)
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


def write(pack_dir, rel, text):
    with open(os.path.join(pack_dir, rel), "w", encoding="utf-8") as f:
        f.write(text)


def append(pack_dir, rel, text):
    with open(os.path.join(pack_dir, rel), "a", encoding="utf-8") as f:
        f.write(text)


def edit_json(pack_dir, rel, mutate):
    p = os.path.join(pack_dir, rel)
    doc = json.load(open(p, encoding="utf-8"))
    mutate(doc)
    json.dump(doc, open(p, "w", encoding="utf-8"), indent=1)


def certify(pack_dir):
    c = os.path.join(pack_dir, "cert.json")
    code, out = run(["hash", os.path.join(pack_dir, "pack.json"), "-o", c])
    if code != 0:
        print(f"FATAL certify() failed unexpectedly:\n{out}")
        sys.exit(1)
    return c


# ---- hash + verify: the happy path ------------------------------------------
clean = pack_copy()
cert = certify(clean)
case("hash-ok-and-cert-written", ["verify", os.path.join(clean, "pack.json"), cert], 0,
     contains=["CURRENT", "UNGATED"])
cert_doc = json.load(open(cert, encoding="utf-8"))
required = ("identity:interpreter", "identity:source", "identity:target",
            "declared:env", "declared:invocations", "declared:pack",
            "declared:entrypoints", "declared:files", "env:MINI_ENV",
            "env:PYTHONHASHSEED", "env:PYTHONPATH", "env:LANG", "env:LC_CTYPE",
            "meta:stdlib",
            "code:scripts/pkg/__init__.py", "code:scripts/pkg/util.py",
            "code:scripts/helper.py", "code:scripts/main.py")
missing = [k for k in required if k not in cert_doc["components"]]
world_hashed = any(k.startswith("world") for k in cert_doc["components"])
world = cert_doc.get("world", {})
if not missing and world.get("recordedOnly") is True and not world_hashed and \
        world.get("driverClass") == "test-driver" and world.get("osClass"):
    n_pass += 1
    print("PASS cert-structure (roles+pins hashed; world w/ driver class recorded "
          "NOT hashed — ledger #6)")
else:
    n_fail += 1
    print(f"FAIL cert-structure — missing {missing}, world_hashed={world_hashed}, "
          f"world={world}")

case("verify-gated-pass",
     ["verify", os.path.join(clean, "pack.json"), cert,
      "--approved-closure", cert_doc["closureSha256"]], 0, contains=["[GATED]"])
case("verify-gated-wrong-sha",
     ["verify", os.path.join(clean, "pack.json"), cert,
      "--approved-closure", WRONG_SHA], 1,
     contains=["stale copy cannot pass a gate"])

# byte-identical rewrite must stay CURRENT (content hash, not mtime)
p = os.path.join(clean, "data", "lut.json")
content = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(content)
case("verify-touch-still-current", ["verify", os.path.join(clean, "pack.json"), cert], 0,
     contains=["CURRENT"])

# ---- verify: every drifted component class surfaces STALE -------------------
for label, rel, key in (
        ("verify-stale-data", "data/lut.json", "file:data/lut.json"),
        ("verify-stale-fixture", "fixtures/fx1/expected.json",
         "fixture:fixtures/fx1/expected.json"),
        ("verify-stale-code", "scripts/helper.py", "code:scripts/helper.py"),
        ("verify-stale-pkg-init", "scripts/pkg/__init__.py",
         "code:scripts/pkg/__init__.py"),
        ("verify-stale-pkg-submodule", "scripts/pkg/util.py",
         "code:scripts/pkg/util.py"),
        ("verify-stale-profile", "PROFILE.md", "file:PROFILE.md")):
    d = pack_copy()
    c = certify(d)
    append(d, rel, "\n# drift\n" if rel.endswith((".py", ".md")) else "\n")
    case(label, ["verify", os.path.join(d, "pack.json"), c], 1,
         contains=[f"STALE {key}: changed", "re-certify"])

d = pack_copy()
c = certify(d)
edit_json(d, "pack.json", lambda doc: doc["sourceIdentity"].update(ueBuild="5.4.1-other"))
case("verify-stale-source-identity", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["STALE identity:source: changed"])

d = pack_copy()
c = certify(d)
case("verify-stale-env-value", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["STALE env:MINI_ENV: changed"], env={"MINI_ENV": "raw"})
d = pack_copy()
c = certify(d)
case("verify-env-unset-vs-literal-unset", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["STALE env:MINI_ENV: changed"], env={"MINI_ENV": "<unset>"})

d = pack_copy()
c = certify(d)
edit_json(d, "pack.json", lambda doc: doc["invocations"][0].update(argv=["--other"]))
case("verify-stale-invocation", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["STALE declared:invocations: changed"])

d = pack_copy()
c = certify(d)
edit_json(d, "cert.json", lambda doc: doc.update(family="meshes"))
case("verify-family-mismatch", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["family mismatch"])

# ---- verify authenticates the certificate itself ----------------------------
d = pack_copy()
c = certify(d)
edit_json(d, "cert.json", lambda doc: doc["components"].pop("file:PROFILE.md"))
case("verify-cert-tampered-components", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["internally inconsistent"])
d = pack_copy()
c = certify(d)
edit_json(d, "cert.json", lambda doc: doc.pop("components"))
case("verify-cert-components-stripped", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["envelope is not schema-closed"])
d = pack_copy()
c = certify(d)
edit_json(d, "cert.json", lambda doc: doc.pop("world"))
case("verify-cert-world-stripped", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["envelope is not schema-closed"])
d = pack_copy()
c = certify(d)
edit_json(d, "cert.json", lambda doc: doc["world"].update(driverClass=""))
case("verify-cert-world-malformed", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["'world' record missing or malformed", "ledger"])
d = pack_copy()
c = certify(d)
edit_json(d, "pack.json", lambda doc: doc.update(
    profileDoc="data/lut.json", dataFiles=["PROFILE.md"]))
case("verify-stale-file-roles", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["STALE declared:files: changed"])

# ---- executed-code closure: allowlist fail-closed modes ----------------------
case("hash-not-allowlisted-importlib",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import importlib\n")), "pack.json")], 1,
     contains=["'importlib'", "not in the allowlisted stdlib set"])
case("hash-not-allowlisted-pathlib",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import pathlib\n")), "pack.json")], 1,
     contains=["'pathlib'", "opaque to the closure walker"])
case("hash-not-allowlisted-runpy",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import runpy\n")), "pack.json")], 1,
     contains=["'runpy'", "not in the allowlisted stdlib set"])
case("hash-not-allowlisted-io",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import io\n")), "pack.json")], 1,
     contains=["'io'", "not in the allowlisted stdlib set"])
case("hash-import-alias",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os as o\n")), "pack.json")], 1,
     contains=["import aliasing", "unsound"])
case("hash-from-stdlib-import",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "from json import loads\n")), "pack.json")], 1,
     contains=["from-imports of stdlib/external modules are aliasing"])
case("hash-open-as-value",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "reader = open\n")), "pack.json")], 1,
     contains=["'open' used as a value"])
case("hash-sys-path-manipulation",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nsys.path.append('x')\n")), "pack.json")], 1,
     contains=["sys.path", "fails closed"])
case("hash-value-alias-getenv",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nread_env = os.getenv\n")), "pack.json")], 1,
     contains=["os.getenv used as a value"])
case("hash-banned-input",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "X = input()\n")), "pack.json")], 1,
     contains=["builtin 'input' is banned"])
case("hash-sys-stdin",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nX = sys.stdin.read()\n")), "pack.json")], 1,
     contains=["sys.stdin", "not an allowlisted sys surface"])
case("hash-os-path-exists",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nX = os.path.exists('/etc/hosts')\n")), "pack.json")], 1,
     contains=["os.path.exists", "only the pure string functions"])
case("hash-os-path-relpath-rejected",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nX = os.path.relpath('/fixed', 'base')\n")), "pack.json")], 1,
     contains=["os.path.relpath", "only the pure string functions"])
case("hash-file-as-value",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "def derive(lut, mode):\n    return __file__\n")), "pack.json")], 1,
     contains=["__file__ outside the FULL recognized declared-read chain"])
case("hash-sys-executable-rejected",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nX = sys.executable\n")), "pack.json")], 1,
     contains=["sys.executable", "not an allowlisted sys surface"])
case("hash-sys-stdout-rejected",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nX = sys.stdout.isatty()\n")), "pack.json")], 1,
     contains=["sys.stdout", "not an allowlisted sys surface"])
case("hash-dirname-as-value",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nHERE = os.path.dirname(__file__)\n")), "pack.json")], 1,
     contains=["__file__ outside the FULL recognized declared-read chain"])
case("hash-banned-hash-builtin",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "X = hash('alpha')\n")), "pack.json")], 1,
     contains=["'hash' is banned"])
case("hash-open-too-many-positional",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\n\ndef derive(lut, mode):\n    return open(os.path.join("
        "os.path.dirname(__file__), '..', 'data', 'lut.json'), 'rb', -1)\n")),
      "pack.json")], 1,
     contains=["more than two positional arguments"])
case("hash-open-text-no-encoding",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\n\ndef derive(lut, mode):\n    return open(os.path.join("
        "os.path.dirname(__file__), '..', 'data', 'lut.json'))\n")),
      "pack.json")], 1,
     contains=["text mode without a literal encoding", "locale"])
for label, bad_seed in (("hash-requires-pinned-hashseed", "random"),
                        ("hash-rejects-empty-hashseed", "")):
    d = pack_copy()
    code, out = run(["hash", os.path.join(d, "pack.json")],
                    env={"PYTHONHASHSEED": bad_seed})
    if code == 1 and "PYTHONHASHSEED is not pinned" in out:
        n_pass += 1
        print(f"PASS {label}")
    else:
        n_fail += 1
        print(f"FAIL {label} — exit {code}\n{out}")

# interpreter flags are part of identity: verify under -O must go STALE;
# -E cannot pin the hash seed at all and must be refused outright
base_env = dict(os.environ)
base_env.pop("MINI_ENV", None)
base_env.pop("PYTHONPATH", None)
base_env["PYTHONHASHSEED"] = "0"
base_env["CERT_DRIVER_CLASS"] = "test-driver"
d = pack_copy()
c = certify(d)
p = subprocess.run([sys.executable, "-O", SCRIPT, "verify",
                    os.path.join(d, "pack.json"), c],
                   capture_output=True, text=True, env=base_env)
if p.returncode == 1 and "STALE identity:interpreter: changed" in p.stdout:
    n_pass += 1
    print("PASS verify-stale-interpreter-flags (-O flips identity)")
else:
    n_fail += 1
    print(f"FAIL verify-stale-interpreter-flags — exit {p.returncode}\n{p.stdout}")
d = pack_copy()
p = subprocess.run([sys.executable, "-E", SCRIPT, "hash",
                    os.path.join(d, "pack.json")],
                   capture_output=True, text=True, env=base_env)
if p.returncode == 1 and "CANNOT pin the hash seed in these modes" in p.stdout:
    n_pass += 1
    print("PASS hash-rejects-ignore-environment (-E refused)")
else:
    n_fail += 1
    print(f"FAIL hash-rejects-ignore-environment — exit {p.returncode}\n{p.stdout}")
d = pack_copy()
c = certify(d)
case("verify-stale-pythonhashseed", ["verify", os.path.join(d, "pack.json"), c], 1,
     contains=["STALE env:PYTHONHASHSEED: changed"], env={"PYTHONHASHSEED": "1"})
case("hash-os-path-as-value",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\njoiner = os.path.join\n")), "pack.json")], 1,
     contains=["os.path.join used as a value"])


def symlink_helper(d):
    p = os.path.join(d, "scripts", "helper.py")
    os.remove(p)
    os.symlink("/etc/hosts", p)


case("hash-code-symlink-escape",
     ["hash", os.path.join(pack_copy(symlink_helper), "pack.json")], 1,
     contains=["imported code file", "escapes the pack root after symlink resolution"])
case("invocation-cwd-nonexistent",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "pack.json",
        lambda doc: doc["invocations"][0].update(cwd="work"))), "pack.json")], 1,
     contains=["cwd 'work' does not exist"])


def symlink_cwd(d):
    os.symlink("/tmp", os.path.join(d, "work"))
    edit_json(d, "pack.json", lambda doc: doc["invocations"][0].update(cwd="work"))


case("invocation-cwd-symlink",
     ["hash", os.path.join(pack_copy(symlink_cwd), "pack.json")], 1,
     contains=["resolves through a symlink"])


def add_second_root(d, alt_body):
    os.makedirs(os.path.join(d, "scripts2"))
    write(d, "scripts2/alt.py", alt_body)
    write(d, "scripts2/helper.py", "def derive():\n    return 2\n")
    edit_json(d, "pack.json", lambda doc: (
        doc["entrypoints"].append("scripts2/alt.py"),
        doc["invocations"].append({"entrypoint": "scripts2/alt.py", "argv": []})))


case("hash-cross-root-isolated-ok",
     ["hash", os.path.join(pack_copy(lambda d: add_second_root(
        d, "import helper\n")), "pack.json"),
      "-o", os.path.join(TMP, "cross-root.json")], 0, contains=["closure"])
cr = json.load(open(os.path.join(TMP, "cross-root.json"), encoding="utf-8"))
if "code:scripts/helper.py" in cr["components"] and \
        "code:scripts2/helper.py" in cr["components"]:
    n_pass += 1
    print("PASS cross-root-both-helpers-hashed (per-root sys.path model)")
else:
    n_fail += 1
    print(f"FAIL cross-root-both-helpers-hashed — components: "
          f"{sorted(k for k in cr['components'] if k.startswith('code:'))}")
case("hash-cross-root-unreachable",
     ["hash", os.path.join(pack_copy(lambda d: add_second_root(
        d, "import pkg.util\n")), "pack.json")], 1,
     contains=["'pkg'", "does not resolve to pack code from this entrypoint's root"])


def add_module_package_clash(d):
    os.makedirs(os.path.join(d, "scripts", "helper"))
    write(d, "scripts/helper/__init__.py", "CLASH = 1\n")


case("hash-ambiguous-module-package",
     ["hash", os.path.join(pack_copy(add_module_package_clash), "pack.json")], 1,
     contains=["matches BOTH a package and a module"])


def add_sourceless_pkg(d):
    os.makedirs(os.path.join(d, "scripts", "helper"))
    with open(os.path.join(d, "scripts", "helper", "__init__.pyc"), "wb") as f:
        f.write(b"\x00fake-bytecode")


case("hash-nonsource-candidate",
     ["hash", os.path.join(pack_copy(add_sourceless_pkg), "pack.json")], 1,
     contains=["bytecode/native-extension candidates",
               "CPython could execute what the walker cannot read"])

import importlib.machinery
tagged_suffix = importlib.machinery.EXTENSION_SUFFIXES[0]


def add_tagged_extension(d):
    with open(os.path.join(d, "scripts", f"helper{tagged_suffix}"), "wb") as f:
        f.write(b"\x00fake-native-extension")


case("hash-tagged-extension-candidate",
     ["hash", os.path.join(pack_copy(add_tagged_extension), "pack.json")], 1,
     contains=["bytecode/native-extension candidates"])
case("hash-rejects-pythonpath",
     ["hash", os.path.join(pack_copy(), "pack.json")], 1,
     contains=["PYTHONPATH is set", "single-root import contract"],
     env={"PYTHONPATH": "/opt/shims"})
case("hash-requires-driver-class",
     ["hash", os.path.join(pack_copy(), "pack.json")], 1,
     contains=["CERT_DRIVER_CLASS is not set", "ledger #6"],
     env={"CERT_DRIVER_CLASS": ""})
case("pack-internal-dotdot",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "pack.json",
        lambda doc: doc["dataFiles"].append("data/../PROFILE.md"))), "pack.json")], 1,
     contains=["must stay INSIDE the pack"])


def symlink_features(d):
    p = os.path.join(d, "features.json")
    os.remove(p)
    os.symlink("/etc/hosts", p)


case("matrix-symlink-features",
     ["matrix", os.path.join(pack_copy(symlink_features), "pack.json")], 1,
     contains=["escapes the pack root after symlink resolution"])
case("hash-dunder-import",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "x = __import__('json')\n")), "pack.json")], 1,
     contains=["dunder name '__import__'"])
case("hash-exec-eval",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "def derive(lut, mode):\n    return eval('1+1')\n")), "pack.json")], 1,
     contains=["'eval' is banned"])
case("hash-foreign-or-unresolved-import",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import requests\n")), "pack.json")], 1,
     contains=["'requests'", "fails closed"])
case("hash-unparseable-code",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "def broken(:\n")), "pack.json")], 1,
     contains=["unparseable"])
case("hash-missing-entrypoint",
     ["hash", os.path.join(pack_copy(lambda d: os.remove(
        os.path.join(d, "scripts", "main.py"))), "pack.json")], 1,
     contains=["entrypoint", "not found"])

# ---- file-read closure --------------------------------------------------------
case("hash-open-write-mode",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\n\ndef derive(lut, mode):\n    return open(os.path.join("
        "os.path.dirname(__file__), '..', 'data', 'lut.json'), 'w')\n")),
      "pack.json")], 1,
     contains=["may only READ", "overwrite the independent oracle"])
case("hash-open-nonexistent-declared",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\n\ndef derive(lut, mode):\n    return open(os.path.join("
        "os.path.dirname(__file__), '..', 'fixtures', 'nope.json'))\n")),
      "pack.json")], 1,
     contains=["does not exist at certification time"])
case("hash-open-literal-cwd-dependent",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "def derive(lut, mode):\n    return open('data/lut.json')\n")), "pack.json")], 1,
     contains=["cwd-dependent"])
case("hash-open-undeclared-resolved",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\n\ndef derive(lut, mode):\n    return open(os.path.join("
        "os.path.dirname(__file__), 'secret.json'))\n")), "pack.json")], 1,
     contains=["'scripts/secret.json'", "not", "declared"])
case("hash-open-opaque-path",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "def derive(lut, mode):\n    return open(mode)\n")), "pack.json")], 1,
     contains=["not statically resolvable"])
case("hash-open-argv-input-ok",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\n\ndef derive(lut, mode):\n    return open(sys.argv[1], 'rb')\n")),
      "pack.json"), "-o", os.path.join(TMP, "argv-ok.json")], 0,
     contains=["closure"])
case("hash-open-argv-nonliteral-index",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\n\ndef derive(lut, mode):\n    return open(sys.argv[mode])\n")),
      "pack.json")], 1,
     contains=["not statically resolvable"])
case("hash-open-argv-write-mode-rejected",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\n\ndef derive(lut, mode):\n    return open(sys.argv[1], 'w')\n")),
      "pack.json")], 1,
     contains=["may only READ"])
case("hash-argv-alias-rejected",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nargs = sys.argv\n")), "pack.json")], 1,
     contains=["aliasing, mutation, iteration"])
case("hash-argv-store-rejected",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nsys.argv[1] = 'x'\n")), "pack.json")], 1,
     contains=["sys.argv used outside read-only literal subscripts"])
case("hash-argv-zero-rejected",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nX = sys.argv[0]\n")), "pack.json")], 1,
     contains=["index 0 is the script path"])
case("hash-argv-out-of-range",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nX = sys.argv[9]\n")), "pack.json")], 1,
     contains=["no declared invocation of an entrypoint reaching this module"])
case("hash-argv-len-ok",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nN = len(sys.argv)\n")), "pack.json"),
      "-o", os.path.join(TMP, "len-ok.json")], 0, contains=["closure"])
case("hash-argv-shadowed-len",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\n\n\ndef len(x):\n    return 0\n\n\nN = len(sys.argv)\n")),
      "pack.json")], 1,
     contains=["'len' is shadowed by a pack binding"])
case("hash-argv-shadowed-len-except-alias",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\n\ntry:\n    pass\nexcept Exception as len:\n    pass\n\n"
        "N = len(sys.argv)\n")), "pack.json")], 1,
     contains=["'len' is shadowed by a pack binding"])
def local_sys_shadow(d):
    write(d, "scripts/pkgsys.py", "argv = ['', '/outside/file']\n")
    write(d, "scripts/helper.py",
          "from pkgsys import argv as sys\nX = open(sys[1], 'rb')\n")


case("hash-local-module-shadows-sys",
     ["hash", os.path.join(pack_copy(local_sys_shadow), "pack.json")], 1,
     contains=["'sys' is bound by pack code"])
case("hash-shadowed-sys-param",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "def read_other(sys):\n    return open(sys.argv[1], 'rb')\n")),
      "pack.json")], 1,
     contains=["'sys' is bound by pack code"])
case("hash-shadowed-os-assign",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nos = None\n")), "pack.json")], 1,
     contains=["'os' is bound by pack code"])
case("hash-shadowed-open-def",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "def open(p, mode='r'):\n    return p\n")), "pack.json")], 1,
     contains=["'open' is bound by pack code"])
case("hash-sys-dunder-chain",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nsys.exit.__self__.argv[1] = '/etc/passwd'\n"
        "X = open(sys.argv[1], 'rb')\n")), "pack.json")], 1,
     contains=["dunder attribute '.__self__'"])
case("hash-builtins-mutation",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\n\n\ndef evil(x):\n    x[1] = '/etc/passwd'\n    return 0\n\n\n"
        "__builtins__.len = evil\nN = len(sys.argv)\nX = open(sys.argv[1], 'rb')\n")),
      "pack.json")], 1,
     contains=["dunder name '__builtins__'"])
case("hash-builtins-direct-open",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "X = __builtins__.open('/etc/passwd')\n")), "pack.json")], 1,
     contains=["dunder name '__builtins__'"])
case("hash-sys-attr-chain",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import sys\nX = sys.exit.attr\n")), "pack.json")], 1,
     contains=["chained attribute sys.exit.attr"])


def wildcard_pkg(d):
    write(d, "scripts/evil.py", "def len(x):\n    return 0\n")
    write(d, "scripts/helper.py",
          "import sys\nfrom evil import *\n\nN = len(sys.argv)\n")


case("hash-wildcard-import",
     ["hash", os.path.join(pack_copy(wildcard_pkg), "pack.json")], 1,
     contains=["wildcard import", "shadowed builtin"])
case("hash-syntax-outside-allowlist",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "X = 1\nglobal_state = None\n\n\ndef derive(lut, mode):\n"
        "    global global_state\n    return 1\n")), "pack.json")], 1,
     contains=["syntax outside the pack-code allowlist", "Global"])


def two_arity_roots(d):
    # main's invocation supplies THREE args; short.py's supplies ONE — under a
    # global bound short.py could borrow main's arity for sys.argv[2]
    os.makedirs(os.path.join(d, "scripts2"))
    write(d, "scripts2/short.py", "import sys\nX = open(sys.argv[2], 'rb')\n")
    edit_json(d, "pack.json", lambda doc: (
        doc["invocations"][0].update(argv=["a", "b", "c"]),
        doc["entrypoints"].append("scripts2/short.py"),
        doc["invocations"].append({"entrypoint": "scripts2/short.py",
                                   "argv": ["only-one"]})))


case("hash-argv-no-arity-borrowing",
     ["hash", os.path.join(pack_copy(two_arity_roots), "pack.json")], 1,
     contains=["sys.argv[2]", "entrypoint reaching this module"])

# ---- environment closure ------------------------------------------------------
case("hash-undeclared-env",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nX = os.environ.get('NOT_DECLARED')\n")), "pack.json")], 1,
     contains=["'NOT_DECLARED'", "not declared"])
case("hash-nonliteral-env",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\n\ndef get(k):\n    return os.environ.get(k)\n")), "pack.json")], 1,
     contains=["non-literal key", "fails closed"])
case("hash-env-alias-from-import",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "from os import environ\n")), "pack.json")], 1,
     contains=["from os import", "fails closed"])
case("hash-env-enumeration",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nX = list(os.environ.items())\n")), "pack.json")], 1,
     contains=["outside the literal-key read forms"])
case("hash-env-alias-assign",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\ne = os.environ\n")), "pack.json")], 1,
     contains=["aliasing", "fails closed"])
case("hash-getattr-banned",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nx = getattr(os, 'environ')\n")), "pack.json")], 1,
     contains=["'getattr'", "banned"])

# ---- process closure ----------------------------------------------------------
case("hash-os-system",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nos.system('ls')\n")), "pack.json")], 1,
     contains=["os.system", "not an allowlisted os surface"])
case("hash-os-listdir",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import os\nX = os.listdir('.')\n")), "pack.json")], 1,
     contains=["os.listdir", "not an allowlisted os surface"])
case("hash-subprocess-import-rejected",
     ["hash", os.path.join(pack_copy(lambda d: write(d, "scripts/helper.py",
        "import subprocess\n")), "pack.json")], 1,
     contains=["REMOVED from this contract pending the runtime-enforcement phase"])
case("pack-subprocesses-key-rejected",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "pack.json", lambda doc: doc.update(
            subprocesses=[{"command": "echo", "binarySha256": WRONG_SHA}]))),
      "pack.json")], 1,
     contains=["'subprocesses'", "REMOVED from this contract"])

# ---- certification is never issued over a broken matrix -----------------------
case("hash-refuses-uncovered-feature",
     ["hash", os.path.join(pack_copy(lambda d: shutil.rmtree(
        os.path.join(d, "fixtures", "fx2"))), "pack.json")], 1,
     contains=["matrix:", "never issued over an unverified coverage matrix"])
case("hash-empty-fixtures",
     ["hash", os.path.join(pack_copy(lambda d: (
        shutil.rmtree(os.path.join(d, "fixtures")),
        os.makedirs(os.path.join(d, "fixtures")))), "pack.json")], 1,
     contains=["certifies nothing"])

# ---- coverage matrix ----------------------------------------------------------
case("matrix-covered", ["matrix", os.path.join(pack_copy(), "pack.json")], 0,
     contains=["COVERED", "coverage: alpha", "interaction: alpha×beta"])
case("matrix-uncovered-feature",
     ["matrix", os.path.join(pack_copy(lambda d: shutil.rmtree(
        os.path.join(d, "fixtures", "fx2"))), "pack.json")], 1,
     contains=["feature 'gamma' is not exercised", "NOT CERTIFIED"])


def split_pair(d):
    edit_json(d, "fixtures/fx1/fixture.json", lambda doc: doc.update(covers=["alpha"]))
    edit_json(d, "fixtures/fx2/fixture.json", lambda doc: doc.update(covers=["beta", "gamma"]))


case("matrix-uncovered-interaction",
     ["matrix", os.path.join(pack_copy(split_pair), "pack.json")], 1,
     contains=["interaction alpha×beta has no fixture covering both"])
case("matrix-undeclared-feature",
     ["matrix", os.path.join(pack_copy(lambda d: edit_json(
        d, "fixtures/fx1/fixture.json",
        lambda doc: doc.update(covers=["alpha", "delta"]))), "pack.json")], 1,
     contains=["undeclared feature 'delta'", "no third state"])

# ---- pack manifest fail-closed ------------------------------------------------
case("pack-unknown-key",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "pack.json", lambda doc: doc.update(extra=1))), "pack.json")], 1,
     contains=["unknown pack key 'extra'"])
case("pack-missing-identity",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "pack.json", lambda doc: doc.pop("sourceIdentity"))), "pack.json")], 1,
     contains=["'sourceIdentity'", "pair of worlds"])
case("pack-missing-invocations",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "pack.json", lambda doc: doc.pop("invocations"))), "pack.json")], 1,
     contains=["'invocations' is REQUIRED"])
case("pack-entrypoint-without-invocation",
     ["hash", os.path.join(pack_copy(lambda d: (
        write(d, "scripts/solo.py", "VALUE = 1\n"),
        edit_json(d, "pack.json",
                  lambda doc: doc["entrypoints"].append("scripts/solo.py")))),
      "pack.json")], 1,
     contains=["has no invocation"])
case("features-unknown-key",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "features.json", lambda doc: doc.update(
            interaction=doc.pop("interactions")))), "pack.json")], 1,
     contains=["unknown key 'interaction'", "silently drops declarations"])
case("features-duplicate",
     ["matrix", os.path.join(pack_copy(lambda d: edit_json(
        d, "features.json", lambda doc: doc["features"].append("alpha"))),
      "pack.json")], 1,
     contains=["'features' contains duplicates"])
case("pack-absolute-fixturesdir",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "pack.json", lambda doc: doc.update(fixturesDir="/tmp"))), "pack.json")], 1,
     contains=["must stay INSIDE the pack"])
case("pack-dotdot-datafile",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "pack.json",
        lambda doc: doc["dataFiles"].append("../outside.json"))), "pack.json")], 1,
     contains=["must stay INSIDE the pack"])
case("pack-absolute-invocation-cwd",
     ["hash", os.path.join(pack_copy(lambda d: edit_json(
        d, "pack.json",
        lambda doc: doc["invocations"][0].update(cwd="/tmp"))), "pack.json")], 1,
     contains=["invocation cwd", "must stay inside the pack"])


def add_symlink_escape(d):
    os.symlink("/etc/hosts", os.path.join(d, "fixtures", "fx1", "link.json"))


case("hash-symlink-escape",
     ["hash", os.path.join(pack_copy(add_symlink_escape), "pack.json")], 1,
     contains=["escapes the pack root after symlink resolution"])
case("unknown-flag-rejected",
     ["verify", os.path.join(clean, "pack.json"), cert, "--nope", "x"], 2,
     contains=["unknown flag"])

print(f"\n{n_pass} passed, {n_fail} failed (fixtures in {TMP})")
sys.exit(1 if n_fail else 0)
