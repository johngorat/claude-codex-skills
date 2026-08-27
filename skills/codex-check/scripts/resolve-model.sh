#!/usr/bin/env bash
# resolve-model.sh — model-resolution ladder for the codex review skills.
#
# Usage:
#   resolve-model.sh <tier> [override-slug]    tier: debate | check
#   resolve-model.sh --propose <tier>          candidates + evidence report
#
# stdout contract (resolution mode): EXACTLY one line "<slug>\t<source>",
#   source: override | pin | machine-pin | cache | rolemap. Nothing else ever
#   lands on stdout; diagnostics, warnings and the refusal bootstrap go to
#   stderr. (--propose mode prints its report on stdout — it IS the output
#   there.)
# Exit codes: 0 resolved / 1 refusal or precondition failure / 2 usage.
#
# Ladder (plans/CODEX-MODEL-RESOLUTION-plan.md; machine pin added by
# plans/CLAUDEX-ADOPTION-plan.md Stage 1 — plugin-cache installs are replaced
# wholesale on update, so an in-tree pin cannot survive there):
#   1 user override   — validated offline; a broken override REFUSES.
#   2 model.txt pin   — next to SKILL.md; validated offline; a broken pin
#                       REFUSES (the pin is the USER's explicit choice — an
#                       automatic source must never outrank or mask it).
#   3 machine pin     — ${CLAUDE_SKILLS_PIN_DIR:-~/.claude/codex-skills-pins}/
#                       <skill>.txt; same explicit-choice semantics as the
#                       in-tree pin (broken/unvalidated REFUSES, automatic
#                       sources never mask it). Consulted only when model.txt
#                       is ABSENT: when both exist the file next to the
#                       running SKILL.md is the more specific choice, and a
#                       BROKEN model.txt still refuses rather than fall
#                       through — otherwise a stale machine pin would silently
#                       hijack an install whose own pin the user just broke.
#   4 models_cache.json — back-compat catalog (per-CHANNEL on 0.145: npm
#                       writes it, standalone does not); original semantics:
#                       visible models by ascending priority, debate=1st,
#                       check=2nd (falling back to 1st). Absence is NOT an
#                       error; an unparseable file warns and continues.
#   5 latest-model.md — role map (flagship -> debate, mini-like/balanced ->
#                       check); the candidate MUST validate offline against a
#                       source OTHER than the role map itself (cache, rollout
#                       corpus, payload strings) — the map self-declares
#                       drift and never self-certifies.
#   6 REFUSE          — both lanes, with the guided bootstrap (R12): print
#                       candidates + evidence; the agent presents them to the
#                       USER; model.txt is written ONLY on explicit USER
#                       confirmation. Never an arbitrary model (R1/D1).
#
# Offline validation = membership in models_cache.json OR the role map
# (cross-source for pins/overrides), OR evidence in the rollout corpus
# ("model":"<slug>" in ~/.codex/sessions/**/rollout-*.jsonl), OR the slug
# baked into the resolved codex payload. The two expensive scans (rollouts,
# payload) cache their POSITIVE verdicts in a schema-versioned record under
# ${XDG_CACHE_HOME:-~/.cache}/claude-codex-skills/, keyed by the ACTIVE CODEX
# IDENTITY (resolved payload path + content hash — never a bare path, never a
# version string; on the npm channel the entry file is a stable shim, so the
# adjacent package.json joins the hash). Negative verdicts are never cached:
# they can flip when new evidence appears, and the failure path ends in a
# refusal anyway. Cheap facts (pin, override, both catalog parses) are
# re-resolved on every run. Record writes are atomic (tmp + rename) behind a
# best-effort lock; a lock that cannot be taken skips the write — the cache
# is an optimization and must never block or corrupt a resolution.
#
# This script NEVER invokes codex (R4: an invalid -m was MEASURED creating a
# live thread + API request — validation stays offline). All parsing lives in
# python3 (declared dependency, capability-tested by env-probe.sh); this bash
# layer only locates the interpreter, so the file itself needs nothing beyond
# bash 3.2 and POSIX.
set -u

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd) || exit 1
command -v python3 >/dev/null 2>&1 || {
  printf '%s\n' "ERROR: python3 not found — run: bash \"$SKILL_DIR/scripts/env-probe.sh\" and follow its remedy" >&2
  exit 1
}
export PYTHONIOENCODING=utf-8
exec python3 - "$SKILL_DIR" "$@" <<'RESOLVE_PY'
import json, os, re, sys, time, hashlib, tempfile

# SCHEMA covers the record format AND the validation algorithm: v1 verdicts
# were produced by a substring scan whose positives (e.g. a prefix typo) the
# whole-token algorithm must not inherit — same identity, different truth.
SCHEMA = 2
SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$")

def err(msg):
    print(msg, file=sys.stderr)

# ---- arguments -------------------------------------------------------------
argv = sys.argv[1:]
skill_dir, argv = argv[0], argv[1:]
propose = False
if argv and argv[0] == "--propose":
    propose, argv = True, argv[1:]
if len(argv) < 1 or argv[0] not in ("debate", "check") or len(argv) > 2 \
        or (propose and len(argv) != 1):
    err("usage: resolve-model.sh <debate|check> [override-slug]")
    err("       resolve-model.sh --propose <debate|check>")
    sys.exit(2)
tier = argv[0]
override = argv[1] if len(argv) == 2 else None

# ---- locations (CODEX_HOME / XDG_CACHE_HOME / CLAUDE_SKILLS_PIN_DIR are the
# ---- test seams) ------------------------------------------------------------
home = os.path.expanduser("~")
codex_home = os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
cache_root = os.path.join(os.environ.get("XDG_CACHE_HOME")
                          or os.path.join(home, ".cache"), "claude-codex-skills")
pin_file = os.path.join(skill_dir, "model.txt")
# machine pin: keyed by the SKILL NAME (basename), not the install path — the
# same skill must resolve identically from a checkout, an installed copy and
# a plugin-cache version dir (whose path changes on every update).
pin_dir = (os.environ.get("CLAUDE_SKILLS_PIN_DIR")
           or os.path.join(home, ".claude", "codex-skills-pins"))
machine_pin_file = os.path.join(
    pin_dir, os.path.basename(os.path.normpath(skill_dir)) + ".txt")
catalog_file = os.path.join(codex_home, "models_cache.json")
rolemap_file = os.path.join(codex_home, "skills", ".system", "openai-docs",
                            "references", "latest-model.md")
sessions_dir = os.path.join(codex_home, "sessions")
record_file = os.path.join(cache_root, "resolver.v%d.json" % SCHEMA)

# ---- corpora (cheap parses, re-resolved every run) -------------------------
def load_catalog():
    """-> (ordered visible slugs or None, status note)."""
    try:
        with open(catalog_file, encoding="utf-8") as f:
            d = json.load(f)
        models = d.get("models") if isinstance(d, dict) else None
        if not isinstance(models, list):
            return None, "present but has no models[] array"
        vis = [(m["priority"], m["slug"]) for m in models
               if isinstance(m, dict) and m.get("visibility") == "list"
               and isinstance(m.get("slug"), str)
               and isinstance(m.get("priority"), (int, float))
               and SLUG_RE.match(m["slug"])]
        vis.sort(key=lambda t: t[0])
        slugs = [s for _, s in vis]
        return (slugs or None), ("present, no visible models" if not slugs else "ok")
    except FileNotFoundError:
        return None, "absent"
    except (OSError, ValueError) as e:
        return None, "unparseable (%s)" % e

def load_rolemap():
    """-> (ordered [(slug, description)] or None, status note)."""
    try:
        rows = []
        with open(rolemap_file, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*\|\s*`([^`]+)`\s*\|(.+)\|\s*$", line)
                if m and SLUG_RE.match(m.group(1)):
                    rows.append((m.group(1), m.group(2).strip()))
        return (rows or None), ("present, no table rows parsed" if not rows else "ok")
    except FileNotFoundError:
        return None, "absent"
    except (OSError, UnicodeError) as e:
        return None, "unreadable (%s)" % e

def rolemap_pick(rows, for_tier):
    want = ("flagship",) if for_tier == "debate" else ("mini-like", "balanced")
    for slug, desc in rows:
        low = desc.lower()
        if any(w in low for w in want) and _review_capable(desc):
            return slug
    return None

catalog, catalog_note = load_catalog()
rolemap, rolemap_note = load_rolemap()

# Role-map MEMBERSHIP counts as evidence only for review-capable rows: the
# shipped map also lists image/video/audio/speech/realtime models, and an
# explicit pin/override of one of those must refuse OFFLINE — a reviewer that
# cannot produce a text verdict fails only after a live, quota-relevant
# launch. NEGATIVE categories are checked FIRST: "Text-to-speech" contains
# the word text and must still be rejected.
NON_REVIEW = ("speech", "audio", "video", "image", "realtime", "voice",
              "transcrib", "tts")
REVIEW_CAPABLE = ("flagship", "mini-like", "nano-like", "balanced",
                  "reasoning", "coding", "text")
def _review_capable(desc):
    low = desc.lower()
    if any(w in low for w in NON_REVIEW):
        return False
    return any(w in low for w in REVIEW_CAPABLE)
rolemap_slugs = ({s for s, d in rolemap if _review_capable(d)}
                 if rolemap else set())

# ---- active codex identity (computed lazily — only the expensive
# ---- validation path needs the record) --------------------------------------
def _exe_path():
    for p in (os.environ.get("PATH") or "").split(os.pathsep):
        for cand in (os.path.join(p, "codex"), os.path.join(p, "codex.exe")):
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                return cand
    return None

def _is_codex_pkg(d):
    """True only when d/package.json names @openai/codex — an unrelated
    node project's package.json above a standalone binary must not switch
    the layout to npm (that would both drop the binary as evidence and make
    the probe demand a vendor payload that never existed)."""
    try:
        with open(os.path.join(d, "package.json"), encoding="utf-8") as f:
            meta = json.load(f)
        # a VALID but non-object package.json ([], null, "x") is still not
        # ours — and must classify as standalone, never crash
        return isinstance(meta, dict) and meta.get("name") == "@openai/codex"
    except (OSError, ValueError, UnicodeError):
        return False

def _npm_pkg_dir(real):
    """Package root for BOTH npm entry layouts:
    - symlink prefix (Mac/Homebrew): <prefix>/codex -> <pkg>/bin/codex.js,
      so the root is two levels above the RESOLVED entry;
    - wrapper prefix (Windows git-bash): npm writes an extensionless SHELL
      WRAPPER at <prefix>/codex that realpath cannot resolve — the package
      lives at <prefix>/node_modules/@openai/codex. Missing this would make
      the wrapper TEXT count as a standalone payload (its own tokens would
      validate) and would pin the identity to the wrapper instead of the
      replaceable native executable.
    Both branches demand the metadata NAME @openai/codex — anything else is
    a standalone binary that merely lives near someone's package.json."""
    d = os.path.dirname(os.path.dirname(real))
    if _is_codex_pkg(d):
        return d
    w = os.path.join(os.path.dirname(real), "node_modules", "@openai", "codex")
    if _is_codex_pkg(w):
        return w
    return None

def _node_target():
    """Node's own platform-arch (e.g. darwin-arm64, win32-x64). npm names
    the platform package with exactly this suffix, and NODE — not python —
    chose which one to install: under Rosetta an x64 Node installs and later
    launches the x64 payload while python reports arm64. Asking node is the
    only truthful source; codex itself is never invoked."""
    import subprocess
    try:
        out = subprocess.run(
            ["node", "-p", 'process.platform + "-" + process.arch'],
            capture_output=True, timeout=15)
        t = out.stdout.decode("ascii", "replace").strip()
        if out.returncode == 0 and re.match(r"^[a-z0-9]+-[a-z0-9]+$", t):
            return t
    except Exception:
        pass
    return None

def _npm_native_payload(pkgdir):
    """EXACTLY the active platform package's native entrypoint. The platform
    dependency is NAMED by the root package metadata (optionalDependencies —
    measured layout); a bare directory glob is only the fallback when the
    metadata names nothing. The ACTIVE one must carry Node's own
    platform-arch suffix (_node_target) — a stale foreign-platform package,
    even a unique one, is dead weight the shim would never launch. Within
    the matching package the entry must be the exact filename, a regular
    EXECUTABLE file, and UNIQUE. No node, ZERO or AMBIGUOUS matches ->
    None: validation then has no payload source at all (fail closed)."""
    import glob
    target = _node_target()
    if not target:
        return None
    suffix = "-" + target
    name = "codex.exe" if sys.platform == "win32" else "codex"
    roots = []
    try:
        with open(os.path.join(pkgdir, "package.json"), encoding="utf-8") as f:
            meta = json.load(f)
        deps = {}
        if isinstance(meta, dict):
            for key in ("optionalDependencies", "dependencies"):
                d = meta.get(key)
                if isinstance(d, dict):
                    deps.update(d)
        roots = [os.path.join(pkgdir, "node_modules", *dep.split("/"))
                 for dep in sorted(deps)]
    except (OSError, ValueError, UnicodeError):
        pass
    if not roots:
        roots = glob.glob(os.path.join(pkgdir, "node_modules", "@openai", "*"))
    hits = []
    for root in roots:
        if not os.path.basename(root).endswith(suffix):
            continue
        for p in glob.glob(os.path.join(root, "vendor", "*", "bin", name)):
            if os.path.isfile(p) and os.access(p, os.X_OK):
                hits.append(p)
    return hits[0] if len(hits) == 1 else None

def payload_paths():
    """The file(s) whose CONTENT counts as slug evidence: ONLY the active
    native executable. The npm entry is a stable JS shim and the metadata
    contains tokens like 'codex' — scanning those would let a non-slug
    override validate as a model."""
    exe = _exe_path()
    if not exe:
        return []
    real = os.path.realpath(exe)
    pkgdir = _npm_pkg_dir(real)
    if pkgdir:
        native = _npm_native_payload(pkgdir)
        return [native] if native else []
    return [real]

_identity = None
_identity_done = False
def identity():
    """ACTIVE-payload identity: resolved native payload path + content hash,
    plus the package.json hash on the npm channel (its shim is stable; the
    package.json changes with every release). Never a bare path, never a
    version string, never an error text. Returns None when the identity is
    UNAVAILABLE (no payload, or any component unhashable) — the caller must
    then disable the persistent cache for this run entirely: a sentinel that
    stays equal across a payload replacement would key stale verdicts."""
    global _identity, _identity_done
    if _identity_done:
        return _identity
    _identity_done = True
    _identity = None
    exe = _exe_path()
    if not exe:
        return None
    real = os.path.realpath(exe)
    paths = list(payload_paths())
    if not paths:
        return None
    pkgdir = _npm_pkg_dir(real)
    if pkgdir:
        paths.append(os.path.join(pkgdir, "package.json"))
    parts = []
    for p in sorted(paths):
        try:
            parts.append("%s#sha256:%s" % (p, _sha256(p)))
        except OSError:
            return None
    _identity = "+".join(parts)
    return _identity

def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

# ---- validation record (positive expensive verdicts only; disabled
# ---- entirely when the active identity is unavailable) ----------------------
def load_record():
    ident = identity()
    if ident is not None:
        try:
            with open(record_file, encoding="utf-8") as f:
                rec = json.load(f)
            if (isinstance(rec, dict) and rec.get("schema") == SCHEMA
                    and rec.get("identity") == ident
                    and isinstance(rec.get("validated"), dict)):
                return rec
        except (OSError, ValueError):
            pass
    return {"schema": SCHEMA, "identity": ident, "validated": {}}

def remember(slug, evidence):
    """Best-effort, atomic, locked; never blocks or breaks resolution.
    No identity -> no persistence: verdicts may not outlive an unidentifiable
    payload."""
    if identity() is None:
        return
    lock = record_file + ".lock"
    try:
        os.makedirs(cache_root, exist_ok=True)
        got = False
        for _ in range(20):
            try:
                os.mkdir(lock)
                got = True
                break
            except FileExistsError:
                try:  # break a stale lock (crashed writer) after 60s
                    if time.time() - os.stat(lock).st_mtime > 60:
                        os.rmdir(lock)
                        continue
                except OSError:
                    pass
                time.sleep(0.1)
        if not got:
            return
        try:
            rec = load_record()
            rec["validated"][slug] = evidence
            fd, tmp = tempfile.mkstemp(dir=cache_root)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(rec, f)
            os.replace(tmp, record_file)
        finally:
            os.rmdir(lock)
    except OSError:
        pass

# ---- expensive scans --------------------------------------------------------
def rollouts_contain(slug):
    needle = ('"model":"%s"' % slug).encode("utf-8")
    if not os.path.isdir(sessions_dir):
        return False
    for root, _dirs, files in os.walk(sessions_dir):
        for fn in files:
            if not (fn.startswith("rollout-") and fn.endswith(".jsonl")):
                continue
            try:
                with open(os.path.join(root, fn), "rb") as f:
                    tail = b""
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        if needle in tail + chunk:
                            return True
                        tail = chunk[-len(needle):]
            except OSError:
                continue
    return False

def payload_contains(slug):
    """The slug must appear as a WHOLE token: without boundaries a payload
    containing 'gpt-5.6-sol' would certify the typo 'gpt-5.6-so' and the
    resolver would emit exactly the invalid slug offline validation exists to
    stop."""
    pat = re.compile(rb"(?<![A-Za-z0-9._-])" + re.escape(slug.encode("utf-8"))
                     + rb"(?![A-Za-z0-9._-])")
    keep = len(slug.encode("utf-8")) + 8
    for path in payload_paths():
        try:
            with open(path, "rb") as f:
                tail = b""
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    if pat.search(tail + chunk):
                        return True
                    tail = (tail + chunk)[-keep:]
        except OSError:
            continue
    return False

# ---- offline validation ------------------------------------------------------
def validate(slug, exclude_rolemap=False):
    """-> evidence string, or None. Cheap memberships first; expensive scans
    consult the identity-keyed record before touching disk (R8)."""
    if catalog and slug in catalog:
        return "cache-member"
    if not exclude_rolemap and slug in rolemap_slugs:
        return "rolemap-member"
    rec = load_record()
    if slug in rec["validated"]:
        return rec["validated"][slug] + " (cached)"
    if rollouts_contain(slug):
        remember(slug, "rollouts")
        return "rollouts"
    if payload_contains(slug):
        remember(slug, "payload")
        return "payload"
    return None

# ---- pins --------------------------------------------------------------------
def read_pin(path):
    """First non-blank line of a pin file, or None if the file is absent.
    An unreadable or non-UTF-8 pin returns a sentinel that fails the slug
    check — a broken EXPLICIT pin must refuse with its remedy, never crash
    with a traceback and never fall through to automatic sources."""
    try:
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line:
                    return line
        return ""  # present but blank — a broken pin, not an absent one
    except FileNotFoundError:
        # A DANGLING SYMLINK also raises FileNotFoundError, but the entry
        # EXISTS — it is a broken explicit pin and must refuse, not silently
        # fall through to the next rung (lexists sees the link itself).
        if os.path.lexists(path):
            return "<unreadable: dangling symlink>"
        return None
    except (OSError, UnicodeError) as e:
        return "<unreadable: %s>" % e

# ---- candidates + bootstrap (the ONLY home of first-launch text, R12) --------
def candidates(for_tier):
    out = []
    if rolemap:
        cand = rolemap_pick(rolemap, for_tier)
        if cand:
            out.append((cand, "rolemap"))
    if catalog:
        idx = 0 if for_tier == "debate" else min(1, len(catalog) - 1)
        for s in dict.fromkeys([catalog[idx]] + catalog[:2]):
            if all(s != c for c, _ in out):
                out.append((s, "cache"))
    return out

NO_SOURCE_REMEDY = ("restore a NAMING source: reinstall or update codex "
                    "(npm install -g @openai/codex, or the standalone "
                    "package on Windows) — it ships the role map that names "
                    "tier candidates. Rollouts and the payload only VALIDATE "
                    "an already-named slug, they never name one; a pin can "
                    "only validate against evidence already present, so with "
                    "no naming source restoring the role map comes first")

def propose_report(for_tier, dest):
    print("candidates for tier '%s':" % for_tier, file=dest)
    cands = candidates(for_tier)
    if not cands:
        print("  (none — no catalog and no role map on this machine)", file=dest)
        print("no candidates exist, so there is nothing to confirm or pin;", file=dest)
        print("  " + NO_SOURCE_REMEDY + ", then re-run.", file=dest)
        return
    for slug, origin in cands:
        ev = validate(slug, exclude_rolemap=(origin == "rolemap"))
        print("  %s  from=%s  validation=%s" % (slug, origin, ev or "UNVALIDATED"),
              file=dest)
    print("bootstrap (once per machine):", file=dest)
    print("  1. Present the candidates above to the USER, including their", file=dest)
    print("     validation status. UNVALIDATED = no offline evidence on this", file=dest)
    print("     machine yet — the USER must consciously accept that.", file=dest)
    print("  2. ONLY after the USER explicitly confirms a slug, write the pin.", file=dest)
    print("     Machine pin (survives skill updates; the ONLY option for a", file=dest)
    print("     plugin install — the plugin cache is replaced wholesale on", file=dest)
    print("     every update):", file=dest)
    print("       mkdir -p \"%s\"" % pin_dir, file=dest)
    print("       printf '%%s\\n' '<slug>' > \"%s\"" % machine_pin_file, file=dest)
    print("     Or the in-tree pin, next to this install's SKILL.md (outranks", file=dest)
    print("     the machine pin; checkout/installer installs only):", file=dest)
    print("       printf '%%s\\n' '<slug>' > \"%s\"" % pin_file, file=dest)
    print("  3. Re-run the resolution. Never pick a model without USER", file=dest)
    print("     confirmation, and never retry with a guessed slug.", file=dest)

if propose:
    propose_report(tier, sys.stdout)
    sys.exit(0)

# ---- the ladder ---------------------------------------------------------------
evidence_log = []

def source_health():
    """Non-absent failures of the validation sources, each with its remedy.
    Printed on EVERY refusal: an override or pin that refuses early may be a
    perfectly valid choice whose evidence source is broken — blaming the
    explicit choice while hiding the corrupt source sends the user the wrong
    way."""
    lines = []
    if catalog_note not in ("absent", "ok"):
        if catalog_note.startswith("present, no visible models"):
            lines.append("models_cache.json (%s): %s — remedy: update codex "
                         "to refresh the catalog" % (catalog_file, catalog_note))
        else:
            lines.append("models_cache.json (%s): %s — remedy: delete it; "
                         "codex regenerates it on the channels that write it"
                         % (catalog_file, catalog_note))
    if rolemap is None and rolemap_note != "absent":
        lines.append("role map (%s): %s — remedy: reinstall/update codex to "
                     "restore the shipped role map" % (rolemap_file, rolemap_note))
    return lines

def refuse(reason, remedy=None):
    err("REFUSED: cannot resolve a reviewer model for tier '%s' — %s" % (tier, reason))
    for line in evidence_log:
        err("  " + line)
    for line in source_health():
        err("  BROKEN SOURCE: " + line)
    propose_report(tier, sys.stderr)
    if remedy:
        err("remedy: " + remedy)
    sys.exit(1)

def resolved(slug, source):
    sys.stdout.write("%s\t%s\n" % (slug, source))
    sys.exit(0)

# 1. user override — an override always OUTRANKS the pin, so the remedy for a
# broken one can never be "write model.txt": that pin would be shadowed by the
# same override on the next run and the refusal would loop forever.
OVERRIDE_REMEDY = ("correct the override to a validated candidate above, or "
                   "withdraw it (re-run WITHOUT the second argument) — an "
                   "override outranks the pin, so writing model.txt alone "
                   "cannot fix this")
if override is not None:
    if not SLUG_RE.match(override):
        evidence_log.append("override: %r is not a plausible model slug" % override)
        refuse("the override is malformed", OVERRIDE_REMEDY)
    ev = validate(override)
    if ev:
        resolved(override, "override")
    evidence_log.append("override: '%s' has NO offline evidence (not in the "
                        "catalog, role map, rollout corpus or payload)" % override)
    refuse("the user-named model failed offline validation", OVERRIDE_REMEDY)
evidence_log.append("override: not given")

# 2. in-tree pin / 3. machine pin — identical explicit-choice semantics.
# A PRESENT pin either resolves or REFUSES; only an ABSENT one falls through.
# The machine pin is consulted only when model.txt is absent (header rationale:
# a broken in-tree pin must never be silently rescued by a stale machine pin).
def pin_rung(path, source, kind):
    pin = read_pin(path)
    if pin is None:
        evidence_log.append("%s (%s): absent" % (kind, path))
        return
    if not SLUG_RE.match(pin):
        evidence_log.append("%s (%s): does not contain a plausible slug: %r"
                            % (kind, path, pin))
        refuse("the %s is broken" % kind,
               "edit %s to a validated candidate above (via the bootstrap, on "
               "explicit USER confirmation), or delete it to fall through to "
               "the automatic sources" % path)
    ev = validate(pin)
    if ev:
        resolved(pin, source)
    evidence_log.append("%s (%s): '%s' has NO offline evidence — the model "
                        "may be retired or the slug mistyped" % (kind, path, pin))
    refuse("the pinned model failed offline validation",
           "edit %s to a validated candidate above (via the bootstrap, on "
           "explicit USER confirmation), or delete it to fall through to the "
           "automatic sources" % path)

pin_rung(pin_file, "pin", "pin")
pin_rung(machine_pin_file, "machine-pin", "machine pin")

# 4. models_cache.json (back-compat; absence is normal, measured per-channel)
if catalog:
    idx = 0 if tier == "debate" else min(1, len(catalog) - 1)
    resolved(catalog[idx], "cache")
evidence_log.append("models_cache.json (%s): %s" % (catalog_file, catalog_note))
if catalog_note not in ("absent", "ok"):
    if catalog_note.startswith("present, no visible models"):
        err("note: models_cache.json %s — continuing down the ladder; remedy: "
            "none needed if a later step resolves, otherwise update codex to "
            "refresh the catalog" % catalog_note)
    else:
        err("note: models_cache.json %s — continuing down the ladder; remedy: "
            "delete %s (codex regenerates it on the channels that write it)"
            % (catalog_note, catalog_file))

# 5. latest-model.md role map (candidate must validate OUTSIDE the map)
if rolemap:
    cand = rolemap_pick(rolemap, tier)
    if cand:
        ev = validate(cand, exclude_rolemap=True)
        if ev:
            resolved(cand, "rolemap")
        evidence_log.append("role map (%s): candidate '%s' has no evidence "
                            "outside the map itself (map self-declares drift, "
                            "never self-certifies)" % (rolemap_file, cand))
    else:
        evidence_log.append("role map (%s): no row matches the '%s' role"
                            % (rolemap_file, tier))
else:
    evidence_log.append("role map (%s): %s" % (rolemap_file, rolemap_note))

# 6. refuse — the guided bootstrap prints via refuse(); when not even a
# candidate exists, the remedy is restoring a source, not confirming a ghost.
if candidates(tier):
    refuse("no source named a model",
           "follow the printed bootstrap above (user-confirmed pin)")
else:
    refuse("no source named a model", NO_SOURCE_REMEDY)
RESOLVE_PY
