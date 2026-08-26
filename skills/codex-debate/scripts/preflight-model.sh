#!/usr/bin/env bash
# preflight-model.sh — staleness / update awareness for the review skills.
#
# Contract: ALWAYS exits 0 and never blocks a gate. SILENT unless something
# is actually stale (R11) — then it prints EXACTLY ONE machine-readable line
# on stdout:
#   preflight-model: stale=<class[,class]> installed=<ver|unknown|-> \
#     current=<ver|-> newest=<ver|-> map=<mtime|missing> pin=<slug|->; \
#     remedy: <one remedy per class, ';'-joined>
# Classes:
#   map-missing             the shipped role map is gone
#   pin-unknown-to-map      this skill's model.txt names a slug the map no
#                           longer knows (a retired family — exactly how the
#                           original drift would return in six months)
#   update-not-active       (standalone channel) a newer release is
#                           downloaded under packages/standalone/releases/
#                           but `current` still points at an older one
#   running-version-differs (standalone channel) the codex on PATH is not
#                           the version `current` points at — PATH shadowing
#                           or a half-finished update
#
# D3 (USER): this script only REPORTS; it never runs `codex update` itself —
# updating the reviewer mid-gate changes the instrument.
#
# codex invocation policy: `codex --version` is the ONE sanctioned codex
# call in this family (gated model plan, Stage 2) — a pure, bounded (15s)
# version query, needed because install metadata cannot see a PATH-shadowed
# older binary. It runs ONLY when the standalone channel is present or an
# anomaly is already being reported; a healthy npm machine invokes nothing.
# exec/resume stay exclusively inside review-round.sh.
set -u

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd) || exit 0
# a broken environment is env-probe's failure to report, not this script's:
# with no python3 OR no codex there is nothing meaningful to be stale AGAINST
command -v python3 >/dev/null 2>&1 || exit 0
command -v codex >/dev/null 2>&1 || exit 0
export PYTHONIOENCODING=utf-8
python3 - "$SKILL_DIR" <<'PREFLIGHT_PY' || true
import os, re, subprocess, sys

skill_dir = sys.argv[1]
codex_home = os.environ.get("CODEX_HOME") or os.path.join(
    os.path.expanduser("~"), ".codex")
pin_file = os.path.join(skill_dir, "model.txt")
rolemap_file = os.path.join(codex_home, "skills", ".system", "openai-docs",
                            "references", "latest-model.md")
releases_dir = os.path.join(codex_home, "packages", "standalone", "releases")
current_link = os.path.join(codex_home, "packages", "standalone", "current")

SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$")
VER_RE = re.compile(r"(\d+)\.(\d+)\.(\d+)")

def ver_key(text):
    m = VER_RE.search(text or "")
    return tuple(int(x) for x in m.groups()) if m else None

def ver_str(key):
    return ".".join(str(x) for x in key)

def installed_version():
    """Bounded pure version query — what the PATH actually runs."""
    try:
        out = subprocess.run(["codex", "--version"],
                             capture_output=True, timeout=15)
        k = ver_key(out.stdout.decode("ascii", "replace"))
        if out.returncode == 0 and k:
            return ver_str(k)
    except Exception:
        pass
    return "unknown"

def map_state():
    try:
        st = os.stat(rolemap_file)
        return True, "%d" % st.st_mtime
    except OSError:
        return False, "missing"

def map_slugs():
    slugs = set()
    try:
        with open(rolemap_file, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*\|\s*`([^`]+)`\s*\|(.+)\|\s*$", line)
                if m and SLUG_RE.match(m.group(1)):
                    slugs.add(m.group(1))
    except (OSError, UnicodeError):
        pass
    return slugs

def read_pin():
    try:
        with open(pin_file, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line:
                    return line
        return None  # blank pin is the resolver's refusal, not staleness
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError):
        return "<unreadable>"

def standalone_state():
    """(newest, current) release versions, or (None, None) off-channel."""
    try:
        names = os.listdir(releases_dir)
    except OSError:
        return None, None
    keys = [k for k in (ver_key(n) for n in names) if k]
    newest = ver_str(max(keys)) if keys else None
    cur = None
    try:
        k = ver_key(os.path.basename(os.path.realpath(current_link)))
        if k:
            cur = ver_str(k)
    except OSError:
        pass
    return newest, cur

stale, remedies = [], []

map_present, map_mtime = map_state()
if not map_present:
    stale.append("map-missing")
    remedies.append("reinstall/update codex to restore the shipped role map")

pin = read_pin()
if pin and map_present and (pin == "<unreadable>" or pin not in map_slugs()):
    stale.append("pin-unknown-to-map")
    remedies.append("the pin may name a retired family: re-pin via "
                    "'resolve-model.sh --propose <tier>' or delete model.txt")

newest, cur = standalone_state()
installed = None
if newest or cur:
    installed = installed_version()
    if newest and cur is None:
        # releases are downloaded but nothing usable is active — the
        # half-applied-update state must never pass silently
        stale.append("update-not-active")
        remedies.append("standalone releases exist (newest %s) but 'current' "
                        "points at nothing usable: repair/finish the update "
                        "yourself (this preflight never runs it)" % newest)
    elif newest and cur and ver_key(newest) != ver_key(cur):
        stale.append("update-not-active")
        remedies.append("a newer standalone release (%s) is downloaded but "
                        "'current' points at %s: finish the update yourself "
                        "(this preflight never runs it)" % (newest, cur))
    if cur and installed != "unknown" and ver_key(installed) != ver_key(cur):
        stale.append("running-version-differs")
        remedies.append("the codex on PATH (%s) is not the standalone "
                        "'current' (%s): fix PATH shadowing or finish the "
                        "half-applied update" % (installed, cur))

if stale:
    if installed is None:
        installed = installed_version()
    # the line must stay machine-readable: a malformed pin's raw bytes could
    # forge fields, so anything that is not a plausible slug is a sentinel
    pin_render = pin if (pin and SLUG_RE.match(pin)) else ("-" if not pin
                                                           else "<invalid>")
    sys.stdout.write(
        "preflight-model: stale=%s installed=%s current=%s newest=%s "
        "map=%s pin=%s; remedy: %s\n"
        % (",".join(stale), installed, cur or "-", newest or "-",
           map_mtime, pin_render, "; ".join(remedies)))
PREFLIGHT_PY
exit 0
