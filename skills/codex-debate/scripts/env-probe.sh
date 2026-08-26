#!/usr/bin/env bash
# env-probe.sh — capability probe for the codex review skills.
#
# Verifies the DECLARED runtime (bash, git, python3, codex — P1) by
# EXECUTING a capability test for each (P2): a Windows Store python alias,
# a Python 2, or a cp1252-bound console all pass a presence test and die in
# real use, so presence alone proves nothing.
#
# Contract: SILENT on success, exit 0. On failure: one line per problem on
# stderr, each naming the exact remedy (P4), exit 1. Never invokes codex
# (R4) — presence and payload readability only; even `codex --version` may
# touch state. Pure bash 3.2 + POSIX tools: this probe runs BEFORE python3
# is known good, so it must not depend on it.
set -u

fail=0
say() { printf '%s\n' "$*" >&2; }

# bash — the entrypoint contract (P0) is `bash <script>`; running under
# anything else means the caller bypassed it.
if [ -z "${BASH_VERSION:-}" ]; then
  say "PROBE FAIL bash: not running under bash — remedy: invoke every skill script as 'bash <script>' (declared floor: bash 3.2)"
  fail=1
fi

# git — presence plus the one capability the skills lean on.
if command -v git >/dev/null 2>&1; then
  if ! printf 'probe' | git hash-object --stdin >/dev/null 2>&1; then
    say "PROBE FAIL git: 'git hash-object --stdin' failed — remedy: reinstall git (https://git-scm.com)"
    fail=1
  fi
else
  say "PROBE FAIL git: not found on PATH — remedy: install git (https://git-scm.com)"
  fail=1
fi

# python3 — JSON parse + UTF-8 round-trip, printed to a captured stdout.
# PYTHONIOENCODING=utf-8 is part of the contract: the measured trap is the
# cp1252 CONSOLE on Windows, not paths (cross-platform findings, hazard 1).
py_ok=0
if command -v python3 >/dev/null 2>&1; then
  got=$(PYTHONIOENCODING=utf-8 python3 -c 'import json,sys;sys.stdout.write(json.loads("{\"k\": \"\\u00fc\\u4e16\"}")["k"])' 2>/dev/null) || got=""
  if [ "$got" = "ü世" ]; then
    py_ok=1
  else
    say "PROBE FAIL python3: JSON+UTF-8 capability test failed (Store alias? Python 2? broken stdout?) — remedy: install real Python 3.9+ and make 'python3' resolve to it (macOS: xcode-select --install; Windows: python.org installer)"
    fail=1
  fi
else
  say "PROBE FAIL python3: not found on PATH — remedy: install Python 3.9+ (macOS: xcode-select --install; Windows: python.org installer, NOT the Store alias)"
  fail=1
fi

# codex — presence + a RESOLVABLE payload; NEVER executed by a probe (an
# invalid launch was measured making a live API request). On the npm channel
# the entrypoint is a JavaScript shim: a readable shim with no node and no
# native payload would pass a naive check and then die on the first round.
if command -v codex >/dev/null 2>&1; then
  exe=$(command -v codex)
  real=$exe
  if [ "$py_ok" -eq 1 ]; then
    real=$(PYTHONIOENCODING=utf-8 python3 -c 'import os,sys;sys.stdout.write(os.path.realpath(sys.argv[1]))' "$exe" 2>/dev/null) || real=$exe
    [ -n "$real" ] || real=$exe
  fi
  if [ ! -r "$real" ]; then
    say "PROBE FAIL codex: '$exe' resolves to unreadable '$real' — remedy: reinstall codex (npm install -g @openai/codex, or the standalone package on Windows)"
    fail=1
  else
    # npm layout detection covers BOTH entry shapes: the resolved symlink
    # entry (<pkg>/bin/codex.js, Mac) and the Windows git-bash WRAPPER at the
    # npm prefix, which realpath cannot resolve — its package lives at
    # <prefix>/node_modules/@openai/codex. Either way the top-level JSON
    # "name" must be EXACTLY @openai/codex, parsed with python3 (a grep is
    # not a JSON parser: "@openai/codex-helper" or a nested name field must
    # not reclassify a standalone binary). Classification needs the already
    # capability-verified python3; without it the probe is failing anyway
    # and claims NO classification.
    is_codex_pkg() {
      [ "$py_ok" -eq 1 ] || return 1
      [ -f "$1/package.json" ] || return 1
      PYTHONIOENCODING=utf-8 python3 -c 'import json,sys
try:
    ok = json.load(open(sys.argv[1], encoding="utf-8")).get("name") == "@openai/codex"
except Exception:
    ok = False
sys.exit(0 if ok else 1)' "$1/package.json" 2>/dev/null
    }
    pkgdir=$(dirname "$(dirname "$real")")
    if ! is_codex_pkg "$pkgdir"; then
      alt="$(dirname "$real")/node_modules/@openai/codex"
      if is_codex_pkg "$alt"; then pkgdir=$alt; else pkgdir=""; fi
    fi
    if [ -n "$pkgdir" ]; then
      # npm layout: the entrypoint is a stable shim/wrapper that launches
      # node. Require node and EXACTLY the active platform package's native
      # entrypoint. Metadata (codex-package.json) or companion hosts must NOT
      # satisfy this, and a missing node_modules is an orphaned shim: FAIL,
      # because a naive pass here dies on the first live round instead.
      # (Needs the already-verified python3; if python3 failed, the probe is
      # failing anyway.)
      node_ok=1
      if ! command -v node >/dev/null 2>&1; then
        node_ok=0
        say "PROBE FAIL node: not found on PATH, but the codex install at '$pkgdir' is an npm layout that needs it — remedy: install Node.js (e.g. brew install node) or reinstall codex"
        fail=1
      fi
      # one line per problem: an ABSENT node is fully reported above — the
      # target query and payload selection run only when node exists, so no
      # second, contradictory "is on PATH" diagnostic can appear.
      if [ "$py_ok" -eq 1 ] && [ "$node_ok" -eq 1 ]; then
        # Same selection law as resolve-model.sh: the platform dependency is
        # NAMED by the root package metadata (glob fallback only when it
        # names nothing); the ACTIVE one must carry NODE's own platform-arch
        # suffix — node, not python, chose which package npm installed
        # (under Rosetta they disagree), so a unique-but-foreign payload is
        # still dead. Exact filename, regular EXECUTABLE file, exactly ONE
        # match — no node target, zero or ambiguous all fail closed.
        # Query node through the verified python with the SAME timeout and
        # output validation as the resolver's _node_target(): a hanging or
        # garbage-printing node must fail the probe, never block it.
        node_target=$(PYTHONIOENCODING=utf-8 python3 -c '
import re, subprocess, sys
try:
    out = subprocess.run(["node", "-p", "process.platform + \"-\" + process.arch"],
                         capture_output=True, timeout=15)
    t = out.stdout.decode("ascii", "replace").strip()
    if out.returncode == 0 and re.match(r"^[a-z0-9]+-[a-z0-9]+$", t):
        sys.stdout.write(t)
except Exception:
    pass' 2>/dev/null) || node_target=""
        if [ -z "$node_target" ]; then
          # NODE is broken, not codex — the remedy must say so: reinstalling
          # codex cannot fix a hung/crashed/garbage-printing node.
          say "PROBE FAIL node: 'node' is on PATH but produced no valid platform target within 15s (hung, crashed or printed garbage) — remedy: reinstall or fix Node.js, or remove whatever shadows 'node' on PATH"
          fail=1
        else
          payload=$(PYTHONIOENCODING=utf-8 python3 -c '
import glob, json, os, sys
pkg, suffix = sys.argv[1], "-" + sys.argv[2]
name = "codex.exe" if sys.platform == "win32" else "codex"
roots = []
try:
    with open(os.path.join(pkg, "package.json"), encoding="utf-8") as f:
        meta = json.load(f)
    deps = {}
    for key in ("optionalDependencies", "dependencies"):
        d = meta.get(key)
        if isinstance(d, dict):
            deps.update(d)
    roots = [os.path.join(pkg, "node_modules", *dep.split("/"))
             for dep in sorted(deps)]
except (OSError, ValueError, UnicodeError):
    pass
if not roots:
    roots = glob.glob(os.path.join(pkg, "node_modules", "@openai", "*"))
hits = []
for root in roots:
    if not os.path.basename(root).endswith(suffix):
        continue
    for p in glob.glob(os.path.join(root, "vendor", "*", "bin", name)):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            hits.append(p)
sys.stdout.write(hits[0] if len(hits) == 1 else "")' "$pkgdir" "$node_target" 2>/dev/null) || payload=""
          if [ -z "$payload" ] || [ ! -r "$payload" ] || [ ! -x "$payload" ]; then
            say "PROBE FAIL codex: npm install at '$pkgdir' has no unique readable+executable native payload matching Node's platform ('$node_target') — remedy: reinstall codex (npm install -g @openai/codex)"
            fail=1
          fi
        fi
      fi
    fi
  fi
else
  say "PROBE FAIL codex: not found on PATH — remedy: install codex (npm install -g @openai/codex, or the standalone package on Windows), then 'codex login'"
  fail=1
fi

# temp — mktemp -d with no template works on BSD and GNU alike.
d=$(mktemp -d 2>/dev/null) || d=""
if [ -n "$d" ] && [ -d "$d" ]; then
  rmdir "$d" 2>/dev/null || true
else
  say "PROBE FAIL mktemp: 'mktemp -d' failed — remedy: point TMPDIR at a writable directory"
  fail=1
fi

# cache root — writable, and atomic rename works there (the resolver's
# record depends on it). Lives OUTSIDE both the checkout and the install.
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-skills"
probe_tmp="$cache_root/.probe.$$"
if mkdir -p "$cache_root" 2>/dev/null \
   && printf 'x' > "$probe_tmp" 2>/dev/null \
   && mv -f "$probe_tmp" "$cache_root/.probe.ok" 2>/dev/null; then
  rm -f "$cache_root/.probe.ok"
else
  rm -f "$probe_tmp" 2>/dev/null
  say "PROBE FAIL cache: cannot write $cache_root — remedy: create it writable, or set XDG_CACHE_HOME to a writable location"
  fail=1
fi

# installation record (written by install.sh) — recheck BOTH sides at every
# entry: an installed COPY that drifted from its record (corruption) or whose
# source checkout moved on (staleness) must be BLOCKED here, before any gate
# spends quota on it. The record lives OUTSIDE both trees (XDG_STATE_HOME).
# FAIL-CLOSED: the checker must end with an explicit OK — an absent state
# dir or no matching record IS an OK (plain checkout / manual install), but
# a crash, a permission error or an unreadable file is a blocking failure,
# never silence.
if [ "$py_ok" -eq 1 ]; then
  # records store dest as CANONICAL-parent + skill name (the skill dir
  # itself may legitimately be a symlink in symlink mode) — so the probe
  # must compare the PHYSICAL parent (pwd -P) joined with the LOGICAL
  # skill-dir name, or an aliased parent would silently match nothing
  _skill_logical=$(cd "$(dirname "$0")/.." && pwd)
  SKILL_ROOT="$(cd "$_skill_logical/.." && pwd -P)/$(basename "$_skill_logical")"
  rec_out=$(PYTHONIOENCODING=utf-8 python3 -c '
import errno, hashlib, json, os, re, stat, sys
skill_dir = os.path.normcase(os.path.normpath(sys.argv[1]))
# XDG semantics, IDENTICAL to install.sh: a relative XDG_STATE_HOME is
# invalid and ignored — resolving it against the CWD would make the probe
# and the installer look at different state directories.
_xdg = os.environ.get("XDG_STATE_HOME") or ""
_base = _xdg if os.path.isabs(_xdg) else os.path.join(
    os.path.expanduser("~"), ".local", "state")
state_dir = os.path.realpath(os.path.join(_base, "claude-codex-skills"))
ALLOW = ("model.txt",)
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
IDENTITY_RE = re.compile(r"^([0-9a-f]{64}|link:.*)$")
def shape_ok(rec):
    return (isinstance(rec, dict) and rec.get("schema") == 1
            and all(isinstance(rec.get(k), str)
                    for k in ("skill", "mode", "source", "dest"))
            and NAME_RE.match(rec["skill"])
            and rec["mode"] in ("copy", "symlink")
            and os.path.isabs(rec["source"]) and os.path.isabs(rec["dest"])
            and isinstance(rec.get("files"), dict)
            and all(isinstance(k, str) and isinstance(v, str)
                    and IDENTITY_RE.match(v)
                    for k, v in rec["files"].items()))
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()
def _raise(e):
    raise e   # an unscannable subtree must FAIL the check, never slim the map
def tree(root):
    out = {}
    for cur, dirs, files in os.walk(root, onerror=_raise):
        for d in list(dirs):
            p = os.path.join(cur, d)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            if rel in ALLOW:
                # a DIRECTORY (or dir symlink) wearing the pin name lands in
                # dirs, not files — it can never be a valid pin
                raise OSError(errno.EINVAL, "the pin must be a REGULAR "
                              "file — a directory here can never be a "
                              "valid pin", p)
            if os.path.islink(p):
                out[rel] = "link:" + os.readlink(p)
                dirs.remove(d)
        for fn in files:
            p = os.path.join(cur, fn)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            st = os.lstat(p)
            if rel in ALLOW:
                # only the ROOT pin is local state; nested = payload — the
                # pin is CLASSIFIED before it is excluded: a symlink/FIFO
                # pin would be followed or block the resolver later
                if not stat.S_ISREG(st.st_mode):
                    raise OSError(errno.EINVAL, "the pin must be a REGULAR "
                                  "file — a symlink or special file here "
                                  "would be followed by the resolver", p)
                continue
            if stat.S_ISLNK(st.st_mode):
                out[rel] = "link:" + os.readlink(p)
                continue
            if not stat.S_ISREG(st.st_mode):
                # hashing a FIFO would BLOCK the probe forever; classify,
                # never open blind
                raise OSError(errno.EINVAL, "unsupported special file "
                              "(FIFO/socket/device) in the payload — remove "
                              "it from the skill", p)
            out[rel] = sha(p)
    return out
def main():
    try:
        names = sorted(os.listdir(state_dir))
    except OSError as e:
        if e.errno == errno.ENOENT:
            return "OK"   # never installed via install.sh: nothing to check
        return ("cannot read the install-state dir %s (%s) — remedy: fix "
                "its permissions" % (state_dir, e))
    matches = []
    for fn in names:
        if not (fn.startswith("install.") and fn.endswith(".json")):
            continue
        try:
            with open(os.path.join(state_dir, fn), encoding="utf-8") as f:
                rec = json.load(f)
        except (OSError, ValueError, UnicodeError) as e:
            return ("unreadable install record %s (%s) — remedy: delete it "
                    "and reinstall" % (fn, e))
        if not shape_ok(rec):
            # a malformed record could belong to THIS skill — treating it as
            # unrelated would bypass the entry-time integrity check entirely
            return ("malformed install record %s — remedy: delete it and "
                    "reinstall that skill" % fn)
        # semantic BINDING, identical to install.sh: a shape-valid record
        # whose dest does not end in its own skill name, or that sits under
        # a filename belonging to a different (skill, dest), is corrupt
        key = os.path.normcase(os.path.normpath(rec["dest"])).encode("utf-8")
        want_fn = ("install.%s.%s.v1.json"
                   % (rec["skill"], hashlib.sha256(key).hexdigest()[:12]))
        if (os.path.basename(os.path.normpath(rec["dest"])) != rec["skill"]
                or fn != want_fn):
            return ("install record %s does not BIND to its own name/"
                    "destination — remedy: delete it and reinstall that "
                    "skill" % fn)
        # match by the RESOLVED parent of the record + its skill-dir name:
        # skill_dir is built from the PHYSICAL parent, so a record whose
        # recorded parent was later aliased away would never match its
        # lexical dest — and the canonicality verdict below would silently
        # never run (fail-open). Resolving the recorded parent the same way
        # keeps the match, so the aliased parent is REPORTED, not skipped.
        rec_id = os.path.normcase(os.path.join(
            os.path.realpath(os.path.dirname(rec["dest"])),
            os.path.basename(os.path.normpath(rec["dest"]))))
        same = rec_id == skill_dir
        if not same:
            # last-resort NO-FOLLOW identity — covers a case-variant final
            # component on a case-insensitive filesystem, where posix
            # normcase folds nothing: same lstat inode = the very same
            # directory ENTRY. lstat, never stat: following links would
            # conflate every symlink install that shares one source; a
            # dead recorded path is simply not this dir
            try:
                same = os.path.samestat(os.lstat(rec["dest"]),
                                        os.lstat(sys.argv[1]))
            except OSError:
                same = False
        if same:
            matches.append(rec)
    # SECOND pass: verify the collected matches only after EVERY record file
    # proved readable and well-formed — returning OK on the first match
    # would skip validating records that sort after it, and a malformed one
    # could belong to this very skill (fail-closed means the whole dir)
    for rec in matches:
        # destination-side canonicality, the mirror of the source rule
        dparent = os.path.dirname(rec["dest"])
        if (os.path.normcase(os.path.realpath(dparent))
                != os.path.normcase(os.path.normpath(dparent))):
            return ("destination root %s is no longer canonical (aliased "
                    "through a symlink) — remedy: reinstall into the real "
                    "location" % dparent)
        src = os.path.join(rec["source"], "skills", rec["skill"])
        # canonicality, not just the final component: if realpath differs,
        # a symlink now aliases the skill dir, skills/, or ANY ancestor of
        # the recorded checkout — the canonical source has moved
        if (os.path.normcase(os.path.realpath(src))
                != os.path.normcase(os.path.normpath(src))
                or not os.path.isdir(src)):
            return ("recorded source %s moved or disappeared (or is aliased "
                    "through a symlink) — remedy: reinstall from the "
                    "checkout at its new location" % src)
        if rec.get("mode") == "symlink":
            # consumer check: still a link, and the bytes read THROUGH it
            # match the current source (git pull is the update path here)
            if not os.path.islink(rec["dest"]):
                return ("%s is no longer a symlink — remedy: re-run bash "
                        "%s/install.sh %s"
                        % (rec["dest"], rec["source"], rec["skill"]))
            if tree(rec["dest"]) != tree(src):
                return ("content through the link differs from the source — "
                        "remedy: re-run bash %s/install.sh %s"
                        % (rec["source"], rec["skill"]))
            # NO early OK: every matched record must pass — a healthy
            # sibling record must never mask a failing one
            continue
        # a copy record needs a REAL directory: isdir/os.walk follow a
        # root symlink, so a link to a byte-identical tree would pass while
        # silently disabling the staleness/corruption checks
        if os.path.islink(rec["dest"]) or not os.path.isdir(rec["dest"]):
            return ("installed copy at %s is missing or was replaced by a "
                    "symlink — remedy: remove it and reinstall (bash "
                    "%s/install.sh %s)"
                    % (rec["dest"], rec["source"], rec["skill"]))
        if tree(rec["dest"]) != rec.get("files"):
            return ("installed copy differs from its record (corrupted or "
                    "edited) — remedy: bash %s/install.sh --refresh %s"
                    % (rec["source"], rec["skill"]))
        if tree(src) != rec.get("files"):
            return ("source checkout changed since the install (STALE "
                    "copy) — remedy: bash %s/install.sh --refresh %s"
                    % (rec["source"], rec["skill"]))
    return "OK"   # every record well-formed; every match (if any) verified
try:
    sys.stdout.write(main())
except Exception as e:
    sys.stdout.write("record check crashed (%s: %s) — remedy: fix the "
                     "install-state dir or reinstall the skill"
                     % (type(e).__name__, e))
' "$SKILL_ROOT" 2>/dev/null) || rec_out=""
  if [ "$rec_out" != "OK" ]; then
    if [ -n "$rec_out" ]; then
      say "PROBE FAIL install: $rec_out"
    else
      say "PROBE FAIL install: the record check produced no verdict (python crashed or was killed) — remedy: re-run; if it persists, reinstall the skill"
    fi
    fail=1
  fi
fi

exit "$fail"
