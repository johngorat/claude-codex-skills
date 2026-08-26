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
      if ! command -v node >/dev/null 2>&1; then
        say "PROBE FAIL codex: '$real' is an npm entry but 'node' is not on PATH — remedy: install Node.js (e.g. brew install node) or reinstall codex"
        fail=1
      fi
      if [ "$py_ok" -eq 1 ]; then
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

exit "$fail"
