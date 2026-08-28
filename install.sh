#!/usr/bin/env bash
# install.sh — install, verify and refresh the codex review skills.
#
# Usage (run from anywhere; the source is where THIS script lives):
#   bash install.sh [--dest DIR] [--mode auto|copy|symlink] [skill ...]
#   bash install.sh --verify  [skill ...]
#   bash install.sh --refresh [skill ...]
#   bash install.sh --update  [skill ...]   (git pull + refresh + NEW skills)
#
# Defaults: dest = ${CLAUDE_SKILLS_DIR:-~/.claude/skills}; install with no
# operands takes every directory under skills/; --verify/--refresh with no
# operands take their targets EXCLUSIVELY from the installation records — a
# skill whose source directory disappeared upstream must still be reported,
# not silently skipped. Mode auto is decided by a REAL capability test at
# the destination (python creates a symlink and reads back through it —
# never inferred from core.symlinks; MSYS's silent ln-s-copies cannot fool
# os.symlink, which either links or raises).
#
# COPY is the PRIMARY supported mode (USER D3: nothing may require Developer
# Mode); symlink stays a supported optimization where links actually work.
#
# Guarantees (each one tested in tests/check-install.sh):
#   - transactional: stage -> verify staged bytes -> activate by rename; the
#     previous installation is KEPT as a backup until post-activation
#     verification AND the record write both succeed. On failure the tree
#     THIS attempt activated is QUARANTINED by rename (rename survives file
#     locks that delete cannot; a failure BEFORE activation leaves the
#     current install exactly where it was), the backup is restored, and
#     when the filesystem prevents even that, the exact manual recovery
#     paths are printed. Interrupts (Ctrl-C) BEFORE the record commit roll
#     back the same way (deferred to explicit checkpoints where rollback is
#     still possible); an interrupt at or after the commit point closes the
#     transaction consistently and exits 130 with an explicit COMMITTED
#     note — never reporting a rollback that did not happen. Nothing is
#     ever silently lost.
#   - serialized: installs and refreshes take an exclusive lock
#     (install.lock in the state dir, auto-released on process death), so
#     concurrent runs can never commit a record describing a tree another
#     run just replaced; contention refuses with a named remedy after
#     bounded retries. Stale write temporaries are swept under the lock.
#   - staleness DETECTED, not merely refreshable: one installation record
#     per (skill, destination) — multiple destinations never overwrite each
#     other — lives OUTSIDE both trees (${XDG_STATE_HOME:-~/.local/state}/
#     claude-codex-skills/, canonicalized and REJECTED if it lies inside the
#     checkout or a destination), holding the CANONICAL source location plus
#     per-file content identities. --verify (and env-probe.sh at every skill
#     entry) rechecks BOTH sides and fails closed when the source moved or
#     disappeared. Unreadable or malformed records are named failures with
#     remedies, never treated as absence — and every record must BIND to its
#     own filename and destination (dest ends in its skill name, filename is
#     the canonical record name), so a misbound record can never steer a
#     refresh at a sibling path.
#   - tree identity covers EVERYTHING: symlinks are recorded as distinct
#     entries (an added link reads as a difference, never vanishes), and an
#     unscannable subtree is fatal — an incomplete payload must not install
#     or verify as complete.
#   - symlink installs are verified through the CONSUMER: the source must
#     exist first (a dangling link cannot pass by lexical path equality),
#     the destination must still BE a link, and the content read through it
#     must byte-match the source. (Record hashes are stored but deliberately
#     not a staleness bar in symlink mode: `git pull` IS the update path.)
#   - --refresh removes files deleted upstream (whole-directory swap) and
#     PRESERVES the local-state allowlist (model.txt) across every install,
#     refresh and MODE SWITCH; when the two sides of a mode switch carry
#     DIFFERENT pins, the switch refuses with a reconciliation remedy
#     instead of silently choosing one.
#   - --update is the ONE user-facing update command: git pull --ff-only in
#     the checkout, then the FRESHLY pulled installer re-runs the refresh and
#     ADOPTS skills that are new upstream into every recorded destination
#     root (in the recorded mode when the root's records agree, else auto).
#     Pins survive as in every refresh; a pull that cannot fast-forward
#     refuses with git's own message and touches nothing.
#   - tracked mode-120000 entries: this repo's tree guard
#     (tests/check-tree.sh) FORBIDS them at the source — so no export or
#     checkout of this repo can contain a text placeholder. The install-time
#     check remains for forks: inside a git checkout placeholders refuse,
#     and when git cannot answer there, the install fails CLOSED.
#   - skill operands are strict basenames: path traversal cannot select or
#     write anything outside skills/ and the destination root; a destination
#     overlapping the source checkout refuses (staging into the walked tree
#     would copy it into itself); FIFOs/sockets/devices in a payload refuse
#     (hashing one hangs); pins (model.txt) must be REGULAR files on both
#     sides — a pin symlink would read or write state outside the trees.
#
# Bash 3.2 + POSIX wrapper only; ALL logic lives in python3 (declared,
# capability-tested dependency). Never invokes codex.
set -u

SRC_ROOT=$(cd "$(dirname "$0")" && pwd) || exit 1
command -v python3 >/dev/null 2>&1 || {
  printf '%s\n' "ERROR: python3 not found — install Python 3.9+ first (macOS: xcode-select --install; Windows: python.org installer)" >&2
  exit 1
}
export PYTHONIOENCODING=utf-8
exec python3 - "$SRC_ROOT" "$@" <<'INSTALL_PY'
import errno, hashlib, json, os, re, shutil, signal, stat, subprocess, sys
import tempfile, time

if sys.version_info < (3, 9):
    sys.stderr.write("ERROR: python3 %d.%d is too old for this installer — "
                     "remedy: install Python 3.9+ (macOS: xcode-select "
                     "--install; Windows: python.org installer) and make "
                     "'python3' resolve to it\n" % sys.version_info[:2])
    sys.exit(1)

SCHEMA = 1
ALLOWLIST = ("model.txt",)   # machine-local files that survive every refresh
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

def err(msg):
    print(msg, file=sys.stderr)

def die(msg):
    err("ERROR: " + msg)
    sys.exit(1)

# the CANONICAL source: a symlinked alias to the checkout must not become
# the recorded identity (removing the alias would fake a "moved" source)
src_root = os.path.realpath(sys.argv[1])
argv = sys.argv[2:]

mode_req, action, dest_root, skills = "auto", "install", None, []
i = 0
while i < len(argv):
    a = argv[i]
    if a == "--dest" and i + 1 < len(argv):
        dest_root = argv[i + 1]; i += 2
    elif a == "--mode" and i + 1 < len(argv):
        mode_req = argv[i + 1]; i += 2
    elif a in ("--verify", "--refresh", "--update", "--update-local"):
        # --update-local is the internal second phase of --update: it runs
        # FROM the freshly pulled installer so the refresh/adoption logic
        # postdates the pull. Action flags are MUTUALLY EXCLUSIVE: with
        # last-one-wins, `--update --refresh --dest X` would silently become
        # a refresh and bypass --update's flag restriction (gate finding).
        if action != "install":
            die("conflicting action flags --%s and %s — pick one"
                % (action, a))
        action = a[2:]; i += 1
    else:
        skills.append(a); i += 1
if mode_req not in ("auto", "copy", "symlink"):
    die("unknown --mode '%s' (auto|copy|symlink)" % mode_req)
if action in ("update", "update-local") \
        and (dest_root is not None or mode_req != "auto"):
    die("--update takes only skill operands — destinations and modes come "
        "from the installation records")

home = os.path.expanduser("~")
dest_root = os.path.abspath(dest_root or os.environ.get("CLAUDE_SKILLS_DIR")
                            or os.path.join(home, ".claude", "skills"))
# XDG semantics: a RELATIVE XDG_STATE_HOME is invalid and must be IGNORED —
# resolving it against the current working directory would make the installer
# and the probe (run from different directories) look at different state.
# env-probe.sh applies the identical rule.
_xdg = os.environ.get("XDG_STATE_HOME") or ""
_state_base = _xdg if os.path.isabs(_xdg) else os.path.join(home, ".local",
                                                            "state")
state_dir = os.path.realpath(os.path.join(_state_base, "claude-codex-skills"))

def _inside(child, parent):
    child = os.path.normcase(os.path.normpath(child))
    parent = os.path.normcase(os.path.normpath(parent))
    return child == parent or child.startswith(parent + os.sep)

def physical_spelling(path):
    """FILESYSTEM-reported spelling of an absolute path (never mutates
    anything): on case-insensitive filesystems (macOS default) realpath
    keeps the caller casing and posix normcase folds nothing, so a
    containment check comparing strings would let /users/me/repo slip past
    a /Users/me/repo guard. chdir/getcwd on the deepest EXISTING ancestor
    returns the on-disk spelling (measured on macOS; identity on
    case-sensitive filesystems); the not-yet-existing suffix is appended
    as given. An unenterable ancestor keeps the lexical path — no worse
    than the pre-check behavior."""
    path = os.path.normpath(path)
    cur, suffix = path, ""
    while cur and not os.path.isdir(cur):
        parent = os.path.dirname(cur)
        if parent == cur:
            return path
        suffix = os.path.join(os.path.basename(cur), suffix) \
            if suffix else os.path.basename(cur)
        cur = parent
    prev = os.getcwd()
    try:
        os.chdir(cur)
        cur = os.getcwd()
    except OSError:
        return path
    finally:
        os.chdir(prev)
    return os.path.join(cur, suffix) if suffix else cur

# containment compares PHYSICAL spellings — a case-variant XDG_STATE_HOME
# or destination must not plant the lock inside the checkout on a
# case-insensitive filesystem
src_root = physical_spelling(src_root)
state_dir = physical_spelling(state_dir)
skills_src = os.path.join(src_root, "skills")

# records must live OUTSIDE both trees: inside the checkout they would write
# through a symlink install into the public repo; inside a destination they
# would corrupt the very content they attest (R2-F4)
if _inside(state_dir, src_root):
    die("the install-state dir %s lies INSIDE the source checkout — set "
        "XDG_STATE_HOME to a location outside both trees" % state_dir)

def check_name(name):
    """Skill operands are strict basenames: '../tests' or 'a/b' must never
    select or install anything outside skills/ and dest_root."""
    if not NAME_RE.match(name) or os.sep in name or "/" in name \
            or "\\" in name or name in (".", ".."):
        die("invalid skill name %r — a skill is a plain directory name "
            "under skills/" % name)
    real = os.path.realpath(os.path.join(skills_src, name))
    if os.path.dirname(real) != os.path.realpath(skills_src):
        die("skill %r does not resolve to a direct child of %s"
            % (name, skills_src))
    return name

def discover_source_skills():
    """Every real skill directory under skills/, validated exactly like an
    explicit operand. Discovery NEVER follows a symlink at the skill root —
    an untracked skills/x -> /elsewhere must not pull external files into
    an install."""
    try:
        names = sorted(os.listdir(skills_src))
    except OSError:
        names = []
    found = []
    for d in names:
        p = os.path.join(skills_src, d)
        if os.path.islink(p):
            die("skills/%s is a SYMLINK at the skill root — refusing to "
                "follow it; a skill must be a real directory" % d)
        if os.path.isdir(p):
            found.append(check_name(d))
    return found

if skills:
    skills = [check_name(s) for s in skills]
elif action == "install":
    # ONLY install enumerates the source: verify/refresh with no operands
    # must draw their targets from the RECORDS, or a skill whose source
    # directory disappeared upstream would be silently skipped.
    skills = discover_source_skills()
    if not skills:
        die("no skills found under %s" % skills_src)

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def _walk_error(e):
    # raise the ORIGINAL OSError: inside a transaction the activation handler
    # must be able to roll back (a die() here would raise SystemExit past the
    # Exception handlers and strand the backup); outside transactions the
    # call sites convert it into the loud remedy via hash_tree_or_die
    raise e

def scan_remedy(root, e):
    return ("cannot scan %s (%s) — remedy: fix its permissions or remove "
            "the unsupported entry; an unscannable tree must never install "
            "or verify as complete" % (getattr(e, "filename", None) or root, e))

def hash_tree_or_die(root):
    try:
        return hash_tree(root)
    except OSError as e:
        die(scan_remedy(root, e))

def hash_tree(root):
    """rel -> content identity for EVERYTHING under root: regular files get
    a sha256, symlinks (file OR directory) are recorded as 'link:<target>'
    entries — an added link must read as a DIFFERENCE, never vanish from the
    map. Every entry is CLASSIFIED via lstat: a FIFO/socket/device would
    block or garble a naive open (sha256 on a FIFO waits for a writer
    forever), so anything that is neither a regular file nor a link is a
    scan failure, never silently hashed. The allowlist is excluded (local
    state is not payload identity). Unreadable subtrees are fatal via
    _walk_error."""
    out = {}
    for cur, dirs, files in os.walk(root, onerror=_walk_error):
        for d in list(dirs):
            p = os.path.join(cur, d)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            if rel in ALLOWLIST:
                # a DIRECTORY (or directory symlink) wearing the pin's name
                # lands in dirs, not files — it can never be a valid pin,
                # and letting it through would install it as payload and
                # then fail every later read_local_state
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
            if rel in ALLOWLIST:
                # only the ROOT model.txt is machine-local state; a nested
                # fixtures/model.txt is payload and must stay in the
                # identity. The pin is CLASSIFIED before it is excluded: a
                # pin symlink/FIFO would otherwise install unvalidated on a
                # fresh install (no migration loop runs) and the resolver
                # would follow or block on it later
                if not stat.S_ISREG(st.st_mode):
                    raise OSError(errno.EINVAL, "the pin must be a REGULAR "
                                  "file — a symlink or special file here "
                                  "would be followed by the resolver", p)
                continue
            if stat.S_ISLNK(st.st_mode):
                out[rel] = "link:" + os.readlink(p)
                continue
            if not stat.S_ISREG(st.st_mode):
                raise OSError(errno.EINVAL, "unsupported special file "
                              "(FIFO/socket/device) in the payload", p)
            out[rel] = sha256_file(p)
    return out

def assert_no_links(root, hashes):
    for rel, v in sorted(hashes.items()):
        if v.startswith("link:"):
            die("internal symlink in payload: %s/%s — remove it from the "
                "skill; copy mode refuses links" % (root, rel))

def dest_digest(dest):
    key = os.path.normcase(os.path.normpath(dest)).encode("utf-8")
    return hashlib.sha256(key).hexdigest()[:12]

def record_path(skill, dest):
    return os.path.join(state_dir, "install.%s.%s.v%d.json"
                        % (skill, dest_digest(dest), SCHEMA))

IDENTITY_RE = re.compile(r"^([0-9a-f]{64}|link:.*)$")

def record_shape_ok(rec):
    """Semantic validation, not just types: a record whose mode says 'bogus'
    or whose paths are relative must be a NAMED failure, never silently
    interpreted as something else. env-probe.sh applies the identical rule."""
    return (isinstance(rec, dict) and rec.get("schema") == SCHEMA
            and all(isinstance(rec.get(k), str)
                    for k in ("skill", "mode", "source", "dest"))
            and NAME_RE.match(rec["skill"])
            and rec["mode"] in ("copy", "symlink")
            and os.path.isabs(rec["source"]) and os.path.isabs(rec["dest"])
            and isinstance(rec.get("files"), dict)
            and all(isinstance(k, str) and isinstance(v, str)
                    and IDENTITY_RE.match(v)
                    for k, v in rec["files"].items()))

def load_records(want_skill=None):
    """Every record, one per (skill, destination). FAIL-CLOSED: only a
    missing state dir means 'no records'; unreadable dirs and malformed or
    unreadable record files are named failures with remedies — a truncated
    record must never make its destination silently drop out of verify or
    refresh."""
    recs = []
    try:
        names = sorted(os.listdir(state_dir))
    except OSError as e:
        if e.errno == errno.ENOENT:
            return recs
        die("cannot read the install-state dir %s (%s) — remedy: fix its "
            "permissions" % (state_dir, e))
    for fn in names:
        if not (fn.startswith("install.") and fn.endswith(".json")):
            continue
        path = os.path.join(state_dir, fn)
        try:
            with open(path, encoding="utf-8") as f:
                rec = json.load(f)
        except (OSError, ValueError, UnicodeError) as e:
            die("unreadable install record %s (%s) — remedy: delete it and "
                "reinstall that skill" % (path, e))
        if not record_shape_ok(rec):
            die("malformed install record %s — remedy: delete it and "
                "reinstall that skill" % path)
        # semantic BINDING, not just shape: refresh derives its install
        # target from dirname(dest)+skill, so a shape-valid record whose
        # dest does not end in its own skill name — or that sits under a
        # filename belonging to a different (skill, dest) — would steer the
        # refresh at a SIBLING path and replace an unrelated tree. Filename
        # uniqueness also makes duplicate (skill, dest) bindings impossible.
        if os.path.basename(os.path.normpath(rec["dest"])) != rec["skill"] \
                or fn != os.path.basename(record_path(rec["skill"],
                                                      rec["dest"])):
            die("install record %s does not BIND to its own name/"
                "destination (skill %s, dest %s) — remedy: delete it and "
                "reinstall that skill" % (path, rec["skill"], rec["dest"]))
        if want_skill and rec["skill"] != want_skill:
            continue
        recs.append(rec)
    return recs

LOCK_FD = None   # held open for the process lifetime; released on exit/death

class defer_interrupts(object):
    """SIGINT inside a transaction is DEFERRED, never lost: a Ctrl-C landing
    between a filesystem mutation and its bookkeeping assignment (rename ->
    `bak = ...`, rename -> `activated = True`, record os.replace -> return)
    would otherwise strand the backup, skip the quarantine, or restore a
    tree whose record already committed. The deferred signal is ACTED ON at
    explicit checkpoint() calls — each placed where the rollback handler can
    still restore the previous state, so a real Ctrl-C rolls back instead of
    riding through the commit. Once the caller marks the record COMMITTED,
    the transaction closes consistently and the interrupt exits 130 with an
    explicit committed note — reporting an interrupt "failure" after the
    state actually committed would be a lie in the other direction. When
    another exception is already propagating, the failure path (which
    already rolled back) wins."""
    def __enter__(self):
        self.got = False
        self.committed = False
        self.prev = None
        try:
            self.prev = signal.signal(signal.SIGINT,
                                      lambda s, f: setattr(self, "got", True))
        except ValueError:   # not the main thread — deferral unavailable
            self.prev = None
        return self
    def checkpoint(self):
        """Raise the deferred interrupt HERE, where rollback is possible."""
        if self.got:
            raise KeyboardInterrupt
    def __exit__(self, exc_type, exc, tb):
        if self.prev is not None:
            signal.signal(signal.SIGINT, self.prev)
        if self.got and exc_type is None:
            if self.committed:
                err("NOTE: interrupt received during the transaction — it "
                    "had already COMMITTED; the installation and its record "
                    "are consistent, nothing was rolled back")
            else:
                err("NOTE: interrupt received — stopping; no half-applied "
                    "changes were left behind")
            raise SystemExit(130)
        return False

def validate_dest_root(this_dest_root):
    """Refuse a destination overlapping the state dir or the checkout.
    Called BEFORE any state-dir mutation as well as inside install_one:
    the lock file and the temp sweep must never be created inside a tree
    the install is about to refuse to touch."""
    real = physical_spelling(os.path.realpath(this_dest_root))
    if _inside(state_dir, real) or _inside(real, state_dir):
        die("the install-state dir %s overlaps the destination %s — records "
            "must live outside both trees; set XDG_STATE_HOME elsewhere"
            % (state_dir, this_dest_root))
    # a destination inside the checkout would stage the tree into itself
    # (os.walk picks up the growing stage — unbounded recursive copy) or
    # rename the SOURCE skill away as a "backup"; refuse both directions
    if _inside(real, src_root) or _inside(src_root, real):
        die("the destination %s lies inside the source checkout %s (or "
            "contains it) — staging would copy the tree into itself or "
            "displace the source; pick a destination outside the checkout"
            % (this_dest_root, src_root))

def acquire_install_lock():
    """ONE mutator per state dir: without this, two concurrent installs can
    interleave activation and record commit so the surviving record describes
    the LOSING tree — and source-pin migration is shared across destinations,
    so installs and refreshes serialize globally. flock/msvcrt locks die with
    the process, so a crashed run never needs stale-lock cleanup. Every
    prospective destination is validated (validate_dest_root) BEFORE this
    runs — creating the lock is a state-dir mutation."""
    global LOCK_FD
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, "install.lock")
    fd = os.open(path, os.O_CREAT | os.O_RDWR)
    tries = int(os.environ.get("CLAUDE_SKILLS_INSTALL_TEST_LOCK_TRIES", "10"))
    for attempt in range(tries):
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            if attempt + 1 < tries:
                time.sleep(1)
            continue
        LOCK_FD = fd
        return
    os.close(fd)
    die("another install/refresh holds the lock %s — wait for it to "
        "finish, then retry" % path)

def sweep_stale_temps():
    """Under the held lock any install.tmp.* is provably a stranded temp
    from a killed run. Runs AFTER destination validation: the sweep deletes
    files and must never run in a state dir that overlaps a destination."""
    for fn in os.listdir(state_dir):
        if fn.startswith("install.tmp."):
            p = os.path.join(state_dir, fn)
            try:
                os.unlink(p)
            except OSError as e:
                err("WARNING: could not remove the stale temporary "
                    "record %s (%s) — delete it manually" % (p, e))

def write_record(rec, notes=None):
    os.makedirs(state_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="install.tmp.", dir=state_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(rec, f, indent=1)
        if os.environ.get("CLAUDE_SKILLS_INSTALL_TEST_FAIL") \
                == "record-replace":
            raise RuntimeError("injected record-replace failure")  # seam
        os.replace(tmp, record_path(rec["skill"], rec["dest"]))
    except BaseException:
        # a failed commit must not strand an anonymous temp in the state
        # dir — and when even the cleanup fails, that leftover is NAMED
        try:
            os.unlink(tmp)
        except OSError as e:
            msg = ("could not remove the temporary record %s (%s) — delete "
                   "it manually" % (tmp, e))
            if notes is not None:
                notes.append(msg)
            else:
                err("WARNING: " + msg)
        raise

def remove_tree_or_note(path, notes):
    """Cleanup that never lies: a leftover the filesystem refuses to delete
    is NAMED with its manual remedy instead of being silently ignored."""
    if not (os.path.islink(path) or os.path.exists(path)):
        return
    try:
        if os.path.islink(path) or os.path.isfile(path):
            os.remove(path)
        else:
            shutil.rmtree(path)
    except OSError as e:
        notes.append("could not remove %s (%s) — delete it manually"
                     % (path, e))

def check_mode_120000(skill):
    """In a git checkout, tracked symlink entries must be NATIVELY
    materialized, or refuse; when git cannot answer INSIDE a checkout, fail
    CLOSED. Exported trees of THIS repo cannot carry placeholders at all:
    tests/check-tree.sh forbids tracked mode-120000 entries at the source,
    so the class is extinguished before any archive is cut. This check
    remains for forks that drop the guard."""
    if not os.path.exists(os.path.join(src_root, ".git")):
        return
    try:
        out = subprocess.run(
            ["git", "-C", src_root, "ls-files", "-s", "--",
             "skills/%s" % skill],
            capture_output=True, timeout=30)
    except Exception as e:
        die("cannot determine tracked-entry modes in this git checkout "
            "(%s) — remedy: make `git -C %s ls-files` work, then retry"
            % (e, src_root))
    if out.returncode != 0:
        die("`git ls-files` failed in this checkout (%s) — remedy: repair "
            "the checkout or your git installation, then retry"
            % out.stderr.decode("utf-8", "replace").strip())
    for line in out.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0] == "120000":
            path = os.path.join(src_root, parts[3])
            if not os.path.islink(path):
                die("tracked symlink %s is checked out as a TEXT PLACEHOLDER "
                    "(core.symlinks=false) — installing it would ship a "
                    "broken file — remedy: re-clone with native symlinks "
                    "or drop the link from the repo" % parts[3])

def links_work(parent):
    """REAL capability test at the destination: create a DIRECTORY link —
    the shape the install actually makes; on Windows a file link can succeed
    while a directory link fails or is unusable — read a file back through
    it, and require it to actually BE a link."""
    os.makedirs(parent, exist_ok=True)
    probe_dir = tempfile.mkdtemp(dir=parent)
    try:
        target = os.path.join(probe_dir, "td")
        link = os.path.join(probe_dir, "l")
        os.mkdir(target)
        with open(os.path.join(target, "t"), "w", encoding="utf-8") as f:
            f.write("probe")
        try:
            os.symlink(target, link, target_is_directory=True)
        except (OSError, NotImplementedError):
            return False
        try:
            with open(os.path.join(link, "t"), encoding="utf-8") as f:
                ok = f.read() == "probe"
            return ok and os.path.islink(link)
        except OSError:
            return False
    finally:
        shutil.rmtree(probe_dir, ignore_errors=True)

def copy_tree(src, dst):
    for cur, dirs, files in os.walk(src, onerror=_walk_error):
        for d in dirs:
            p = os.path.join(cur, d)
            if os.path.relpath(p, src).replace(os.sep, "/") in ALLOWLIST:
                die("the source-side pin %s is a DIRECTORY — a pin must be "
                    "a regular file; replace it, then re-run" % p)
            if os.path.islink(p):
                die("internal DIRECTORY symlink in payload: %s — remove it "
                    "from the skill; copy mode refuses links" % p)
        rel = os.path.relpath(cur, src)
        tgt = dst if rel == "." else os.path.join(dst, rel)
        os.makedirs(tgt, exist_ok=True)
        for fn in files:
            sp, dp = os.path.join(cur, fn), os.path.join(tgt, fn)
            st = os.lstat(sp)
            if fn in ALLOWLIST and rel == ".":
                # only the ROOT pin is local state; nested = payload — but
                # classify BEFORE excluding (same law as hash_tree)
                if not stat.S_ISREG(st.st_mode):
                    die("the source-side pin %s is not a regular file — "
                        "replace it with a plain file, then re-run" % sp)
                continue
            if stat.S_ISLNK(st.st_mode):
                die("internal symlink in payload: %s — remove it from the "
                    "skill; copy mode refuses links" % sp)
            if not stat.S_ISREG(st.st_mode):
                die("unsupported special file in payload: %s — remove it "
                    "from the skill (opening a FIFO/socket/device would "
                    "hang or garble the copy)" % sp)
            with open(sp, "rb") as fi, open(dp, "wb") as fo:
                shutil.copyfileobj(fi, fo)
            os.chmod(dp, st.st_mode & 0o777)

def read_pin(path):
    """No-follow, identity-checked pin read. Where the platform has
    O_NOFOLLOW the open itself refuses a symlink (ELOOP). Where it does
    NOT (Windows — the primary copy-mode platform), lstat and the opened
    handle are BOUND by a (st_dev, st_ino) identity match: a symlink
    present at lstat time refuses outright, and a swap between lstat and
    open makes the handle a different file identity and refuses — no
    window follows a symlink silently. On a filesystem that cannot prove
    identity (st_ino == 0) and has no O_NOFOLLOW, the read fails CLOSED
    rather than trusting an unprovable path."""
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode):
        raise OSError(errno.EINVAL, "the pin must be a regular file", path)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, os.O_RDONLY | nofollow | getattr(os, "O_BINARY", 0))
    with os.fdopen(fd, "rb") as f:
        fst = os.fstat(f.fileno())
        if not stat.S_ISREG(fst.st_mode):
            raise OSError(errno.EINVAL, "the pin must be a regular file",
                          path)
        if not nofollow:
            if fst.st_ino == 0 and st.st_ino == 0:
                raise OSError(errno.EINVAL, "cannot prove the pin identity "
                              "on this filesystem (no O_NOFOLLOW, no file "
                              "index) — replace the pin with a regular file "
                              "on a filesystem with stable file ids", path)
            if (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino):
                raise OSError(errno.EINVAL, "the pin changed identity "
                              "between inspection and read — it must be a "
                              "regular file reached without symlinks", path)
        return f.read()

def read_local_state(dest):
    """Allowlisted local files from the CURRENT installation, read through
    whatever the destination is (real dir OR symlink) — a mode switch in
    either direction must never lose the pin. The pin ITSELF must be a
    regular file: following a pin symlink would read — and on migration
    write — state that lives outside the installation."""
    state = {}
    for name in ALLOWLIST:
        p = os.path.join(dest, name)
        try:
            state[name] = read_pin(p)
        except OSError as e:
            # ONLY proven absence reads as "no pin": an ACL or transient
            # error must never make an existing pin silently vanish from the
            # state that survives the reinstall
            if e.errno in (errno.ENOENT, errno.ENOTDIR):
                continue
            die("cannot read the local pin %s (%s) — remedy: fix its "
                "permissions, or replace it with a regular file, then "
                "re-run" % (p, e))
    return state

def backup_dest(skill, this_dest_root, dest):
    """Move ANY existing destination (dir, link or file) aside; the caller
    restores it on failure and removes it only after full success."""
    if not (os.path.islink(dest) or os.path.exists(dest)):
        return None
    bak = os.path.join(this_dest_root, ".old-%s-%d" % (skill, os.getpid()))
    os.rename(dest, bak)
    return bak

def quarantine_dest(skill, this_dest_root, dest, notes):
    """On a failed activation, move the bad tree ASIDE by rename — rename
    survives file locks that deletion cannot — so the backup can return."""
    if not (os.path.islink(dest) or os.path.exists(dest)):
        return
    if os.path.islink(dest):
        try:
            os.remove(dest)
            return
        except OSError:
            pass
    q = os.path.join(this_dest_root, ".failed-%s-%d" % (skill, os.getpid()))
    try:
        os.rename(dest, q)
        notes.append("the failed tree is quarantined at %s — inspect and "
                     "delete it manually" % q)
    except OSError as e:
        notes.append("could not move the failed tree aside (%s)" % e)

def restore_backup(bak, dest, notes):
    if bak is None:
        return
    try:
        if os.path.islink(dest) or os.path.exists(dest):
            raise OSError("destination %s is still occupied" % dest)
        os.rename(bak, dest)
    except OSError as e:
        notes.append("RESTORATION FAILED (%s): your previous install is "
                     "intact at %s — move it back to %s manually"
                     % (e, bak, dest))

def drop_backup(bak):
    if bak is None:
        return
    try:
        if os.path.islink(bak) or os.path.isfile(bak):
            os.remove(bak)
        else:
            shutil.rmtree(bak)
    except OSError as e:
        err("WARNING: could not remove the backup %s (%s) — delete it "
            "manually" % (bak, e))

def install_one(skill, mode, this_dest_root):
    # canonical DESTINATION identity: two lexical aliases of one physical
    # dest root must map to ONE record — otherwise installing through an
    # alias replaces the same physical tree under a second record, strands
    # the first one, and an immediate --verify fails. The final component
    # (the skill dir itself) is NOT resolved: in symlink mode it IS a link.
    this_dest_root = os.path.realpath(this_dest_root)
    src = os.path.join(skills_src, skill)
    if os.path.islink(src):
        die("skills/%s is a SYMLINK at the skill root — refusing to follow "
            "it; a skill must be a real directory" % skill)
    # canonicality of the WHOLE path, not just the final component: with
    # skills/ (or any ancestor below the realpathed checkout) replaced by a
    # symlink, the final dir looks real, the external payload installs, and
    # the record then fails verification immediately — refuse up front
    if os.path.normcase(os.path.realpath(src)) \
            != os.path.normcase(os.path.normpath(src)):
        die("the skill source %s is not canonical — skills/ or an ancestor "
            "is a symlink alias; a skill must be reached without symlinks"
            % src)
    if not os.path.isdir(src):
        die("no such skill in the source: %s" % src)
    # the CONSUMER entrypoint must exist in EVERY mode: an entrypoint-less
    # tree would install, record and verify consistently — and still not
    # be a loadable skill
    if not os.path.isfile(os.path.join(src, "SKILL.md")):
        die("the source skill %s has no SKILL.md — refusing to install an "
            "entrypoint-less consumer" % src)
    validate_dest_root(this_dest_root)
    check_mode_120000(skill)
    src_hashes = hash_tree_or_die(src)
    os.makedirs(this_dest_root, exist_ok=True)
    # FILESYSTEM-reported spelling, not just realpath: on case-insensitive
    # filesystems (macOS default) realpath keeps the caller's casing and
    # posix normcase is a no-op, so /Users/x and /users/x would produce two
    # records for one physical directory — and the stale twin would fail
    # --verify right after a successful reinstall. chdir/getcwd returns the
    # on-disk spelling (measured on macOS); on case-sensitive filesystems
    # it is the identity. Requires the dir to exist, hence after makedirs;
    # validation re-runs on the corrected spelling.
    prev_cwd = os.getcwd()
    try:
        os.chdir(this_dest_root)
        this_dest_root = os.getcwd()
    except OSError as e:
        die("cannot resolve the physical spelling of %s (%s) — remedy: "
            "make it an accessible directory" % (this_dest_root, e))
    finally:
        os.chdir(prev_cwd)
    validate_dest_root(this_dest_root)
    dest = os.path.join(this_dest_root, skill)
    local_state = read_local_state(dest)

    if mode == "auto":
        mode = "symlink" if links_work(this_dest_root) else "copy"

    if mode == "symlink":
        if not links_work(this_dest_root):
            die("symlink mode requested but links do not work at %s — use "
                "--mode copy (the primary mode; needs no privileges)"
                % this_dest_root)
        # (the SKILL.md entrypoint requirement is enforced for EVERY mode at
        # the top of install_one)
        # the pin must survive a copy->symlink switch: under a symlink
        # install the resolver reads it from the (gitignored) source skill
        # dir. When BOTH sides carry a pin and they differ, refusing beats
        # silently choosing one. EVERYTHING that mutates shared state — pin
        # creation included — runs inside ONE rollback-protected block, each
        # created pin registered BEFORE its write, and every cleanup on the
        # failure path is non-throwing (a cleanup that raises would strand
        # the backup and skip the remaining recovery steps).
        with defer_interrupts() as guard:
            created_pins, bak, notes = [], None, []
            activated = False
            tmp_link = os.path.join(this_dest_root,
                                    ".link-%s-%d" % (skill, os.getpid()))
            try:
                guard.checkpoint()   # before the first shared-state mutation
                for name, data in local_state.items():
                    src_pin = os.path.join(src, name)
                    try:
                        pst = os.lstat(src_pin)
                    except OSError as e:
                        # only PROVEN absence means "create it": any other error
                        # (ACL, transient I/O) would silently shadow an existing
                        # pin and then delete it as "ours" on rollback
                        if e.errno in (errno.ENOENT, errno.ENOTDIR):
                            pst = None
                        else:
                            raise RuntimeError(
                                "cannot inspect the source-side %s (%s) — fix "
                                "its permissions, then re-run" % (name, e))
                    if pst is not None and not stat.S_ISREG(pst.st_mode):
                        # a pin SYMLINK (dangling ones included) would be read —
                        # or created — THROUGH the link, planting state outside
                        # the checkout that no cleanup path knows about
                        raise RuntimeError(
                            "the source-side %s is a symlink or special file — "
                            "refusing to migrate the pin through it; replace %s "
                            "with a regular file, then re-run" % (name, src_pin))
                    if pst is not None:
                        # no-follow read: the lstat above races with a swap
                        try:
                            src_data = read_pin(src_pin)
                        except OSError as e:
                            raise RuntimeError(
                                "cannot read the source-side %s (%s) — fix "
                                "its permissions, or replace it with a "
                                "regular file, then re-run" % (name, e))
                        if src_data != data:
                            raise RuntimeError(
                                "both the current install and the source "
                                "carry a %s and they DIFFER — reconcile "
                                "manually (keep one of: %s , %s), then "
                                "re-run" % (name, os.path.join(dest, name),
                                            src_pin))
                    else:
                        # O_EXCL: never follow anything that appeared since the
                        # lstat above — create a NEW regular file or fail.
                        # Registration happens the INSTANT creation succeeds
                        # (before the write): registering earlier would make an
                        # EEXCL loss delete a pin some OTHER actor just created;
                        # SIGINT between the two lines is deferred by the
                        # enclosing defer_interrupts block
                        pfd = os.open(src_pin,
                                      os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                        created_pins.append(src_pin)
                        with os.fdopen(pfd, "wb") as f:
                            f.write(data)
                remove_tree_or_note(tmp_link, notes)   # stale residue can't block
                os.symlink(src, tmp_link, target_is_directory=True)
                guard.checkpoint()   # last stop before dest is displaced
                bak = backup_dest(skill, this_dest_root, dest)
                os.rename(tmp_link, dest)
                activated = True
                if not os.path.islink(dest):
                    raise RuntimeError("destination is not a link after "
                                       "activation")
                # explicit consumer read: SKILL.md THROUGH the link, byte-equal
                with open(os.path.join(dest, "SKILL.md"), "rb") as f1, \
                     open(os.path.join(src, "SKILL.md"), "rb") as f2:
                    if f1.read() != f2.read():
                        raise RuntimeError("SKILL.md read through the link "
                                           "differs from the source")
                if hash_tree(dest) != src_hashes:
                    raise RuntimeError("content read through the link does not "
                                       "match the source")
                if os.environ.get("CLAUDE_SKILLS_INSTALL_TEST_FAIL") \
                        == "record-commit":
                    raise RuntimeError("injected record-commit failure")  # seam
                if os.environ.get("CLAUDE_SKILLS_INSTALL_TEST_FAIL") \
                        == "record-interrupt":
                    raise KeyboardInterrupt   # seam: interrupts must roll back
                guard.checkpoint()   # last rollback-capable point
                write_record({"schema": SCHEMA, "skill": skill,
                              "mode": "symlink", "source": src_root,
                              "dest": dest, "files": src_hashes}, notes)
                guard.committed = True
            except BaseException as e:
                # BaseException: a Ctrl-C between backup and record commit must
                # roll back exactly like any failure, then keep its interrupt
                # semantics. Quarantine ONLY what THIS attempt activated — before
                # activation dest still holds the CURRENT installation (bak is
                # None), and quarantining it would destroy a working install
                # over a mere pin conflict.
                if activated:
                    quarantine_dest(skill, this_dest_root, dest, notes)
                remove_tree_or_note(tmp_link, notes)
                restore_backup(bak, dest, notes)
                for p in created_pins:
                    try:
                        os.remove(p)
                    except OSError as pe:
                        notes.append("could not remove the pin this attempt "
                                     "created at %s (%s) — delete it manually"
                                     % (p, pe))
                if not isinstance(e, Exception):
                    for n in notes:
                        err("WARNING: " + n)
                    raise
                die("symlink install failed: %s%s"
                    % (e, ("; " + "; ".join(notes)) if notes else ""))
            drop_backup(bak)
        print("installed %s -> %s (symlink)" % (skill, dest))
        return

    # copy mode: stage -> verify staged -> activate; the backup survives
    # until post-activation verification AND the record write succeed
    assert_no_links(src, src_hashes)
    stage = os.path.join(this_dest_root, ".stage-%s-%d" % (skill, os.getpid()))
    try:
        copy_tree(src, stage)
        staged = hash_tree(stage)
        if os.environ.get("CLAUDE_SKILLS_INSTALL_TEST_FAIL") == "stage-verify":
            staged = dict(staged, __injected__="0")   # fault-injection seam
        if staged != src_hashes:
            raise RuntimeError("staged bytes do not match the source")
        for name, data in local_state.items():
            with open(os.path.join(stage, name), "wb") as f:
                f.write(data)
    except BaseException as e:
        # SystemExit keeps its message, KeyboardInterrupt its semantics —
        # both AFTER the stage residue is cleaned
        notes = []
        remove_tree_or_note(stage, notes)
        if not isinstance(e, Exception):
            for n in notes:
                err("WARNING: " + n)
            raise
        die("staging failed, existing install untouched: %s%s"
            % (e, ("; " + "; ".join(notes)) if notes else ""))

    with defer_interrupts() as guard:
        bak, notes = None, []
        activated = False
        try:
            guard.checkpoint()   # last stop before dest is displaced
            bak = backup_dest(skill, this_dest_root, dest)
            os.rename(stage, dest)
            activated = True
            if os.environ.get("CLAUDE_SKILLS_INSTALL_TEST_FAIL") \
                    == "sigint-early":
                os.kill(os.getpid(), signal.SIGINT)   # seam: REAL signal
                # mid-transaction — deferred, then raised at the next
                # checkpoint, proving a real Ctrl-C rolls back
            if hash_tree(dest) != src_hashes:
                raise RuntimeError("post-activation verification failed")
            if os.environ.get("CLAUDE_SKILLS_INSTALL_TEST_FAIL") == "record-commit":
                raise RuntimeError("injected record-commit failure")  # test seam
            if os.environ.get("CLAUDE_SKILLS_INSTALL_TEST_FAIL") \
                    == "record-interrupt":
                raise KeyboardInterrupt   # seam: interrupts must roll back too
            guard.checkpoint()   # last rollback-capable point
            if os.environ.get("CLAUDE_SKILLS_INSTALL_TEST_FAIL") \
                    == "sigint-commit":
                os.kill(os.getpid(), signal.SIGINT)   # seam: REAL signal at
                # the commit point — the transaction closes consistently and
                # exits 130 with the explicit COMMITTED note
            write_record({"schema": SCHEMA, "skill": skill, "mode": "copy",
                          "source": src_root, "dest": dest,
                          "files": src_hashes}, notes)
            guard.committed = True
        except BaseException as e:
            # BaseException + activated flag: same law as the symlink branch —
            # interrupts roll back, and only a tree THIS attempt activated is
            # quarantined (a failure inside backup_dest leaves the CURRENT
            # install at dest; quarantining it would destroy it with bak=None)
            if activated:
                quarantine_dest(skill, this_dest_root, dest, notes)
            remove_tree_or_note(stage, notes)
            restore_backup(bak, dest, notes)
            if not isinstance(e, Exception):
                for n in notes:
                    err("WARNING: " + n)
                raise
            die("activation failed: %s%s"
                % (e, ("; " + "; ".join(notes)) if notes else ""))
        drop_backup(bak)
    print("installed %s -> %s (copy)" % (skill, dest))

def verify_record(rec):
    """0 = fresh, >0 = problems (each line carries its remedy)."""
    skill, dest = rec["skill"], rec["dest"]
    src = os.path.join(rec["source"], "skills", skill)
    # the record stores the CANONICAL source; if realpath(src) differs, some
    # component — the skill dir, skills/, or ANY ancestor of the checkout —
    # is now a symlink alias, and the recorded source has effectively moved
    if os.path.normcase(os.path.realpath(src)) \
            != os.path.normcase(os.path.normpath(src)):
        err("VERIFY FAIL %s at %s: recorded source %s is no longer "
            "canonical (a symlink now aliases it to %s) — refusing to trust "
            "an aliased source; remedy: reinstall from the checkout's real "
            "location" % (skill, dest, src, os.path.realpath(src)))
        return 1
    if not os.path.isdir(src):
        err("VERIFY FAIL %s at %s: recorded source %s moved or "
            "disappeared — remedy: reinstall from the checkout's new "
            "location (bash <checkout>/install.sh --dest %s %s); refusing "
            "to trust the installation blindly"
            % (skill, dest, src, os.path.dirname(dest), skill))
        return 1
    # destination-side canonicality, the mirror of the source rule: records
    # store dest as canonical-parent + skill name, so a parent that is no
    # longer canonical means the recorded destination was aliased away
    dparent = os.path.dirname(dest)
    if os.path.normcase(os.path.realpath(dparent)) \
            != os.path.normcase(os.path.normpath(dparent)):
        err("VERIFY FAIL %s at %s: the destination root %s is no longer "
            "canonical (a symlink now aliases it to %s) — remedy: reinstall "
            "into the real location"
            % (skill, dest, dparent, os.path.realpath(dparent)))
        return 1
    try:
        if rec["mode"] == "symlink":
            # consumer check: still a link AND the bytes read through it
            # match the CURRENT source (record hashes are deliberately not a
            # staleness bar here — `git pull` is the update path for links)
            if not os.path.islink(dest):
                err("VERIFY FAIL %s at %s: no longer a symlink — remedy: "
                    "re-run bash %s/install.sh --dest %s %s"
                    % (skill, dest, rec["source"], os.path.dirname(dest),
                       skill))
                return 1
            if hash_tree(dest) != hash_tree(src):
                err("VERIFY FAIL %s at %s: content read through the link "
                    "does not match the source — remedy: re-run bash "
                    "%s/install.sh --dest %s %s"
                    % (skill, dest, rec["source"], os.path.dirname(dest),
                       skill))
                return 1
            return 0
        problems = 0
        # a copy record is satisfied only by a REAL directory: isdir/os.walk
        # both follow a root symlink, so a link to any byte-identical tree
        # (the source itself included) would verify while silently disabling
        # every staleness/corruption guarantee the record exists for
        if os.path.islink(dest):
            err("VERIFY FAIL %s at %s: the record says COPY but the "
                "destination is a symlink — remedy: remove it and reinstall "
                "(bash %s/install.sh --dest %s %s)"
                % (skill, dest, rec["source"], os.path.dirname(dest), skill))
            return 1
        installed_now = hash_tree(dest) if os.path.isdir(dest) else {}
        if installed_now != rec["files"]:
            err("VERIFY FAIL %s at %s: installed copy differs from its "
                "record (corrupted or manually edited) — remedy: bash "
                "%s/install.sh --refresh %s"
                % (skill, dest, rec["source"], skill))
            problems += 1
        if hash_tree(src) != rec["files"]:
            err("VERIFY FAIL %s at %s: the source checkout changed since "
                "the install (stale copy) — remedy: bash %s/install.sh "
                "--refresh %s" % (skill, dest, rec["source"], skill))
            problems += 1
        return problems
    except OSError as e:
        # an unscannable side must FAIL the verification, never slim it
        err("VERIFY FAIL %s at %s: %s" % (skill, dest, scan_remedy(dest, e)))
        return 1

if action == "update":
    # Pull, then RE-EXEC the freshly pulled installer for the local work.
    # The running program text is already fully read (bash hands python a
    # complete heredoc before exec), so the pull cannot corrupt THIS run —
    # but the refresh/adoption logic must be the post-pull version, hence
    # the child invocation of the new install.sh.
    if not os.path.exists(os.path.join(src_root, ".git")):
        die("%s is not a git checkout — update it the way it was obtained "
            "(re-download it, or use your plugin manager), or clone the "
            "repo and install from the clone" % src_root)
    try:
        out = subprocess.run(["git", "-C", src_root, "pull", "--ff-only"],
                             capture_output=True, timeout=300)
    except Exception as e:
        die("git pull could not run (%s) — remedy: make `git -C %s pull` "
            "work, then re-run --update" % (e, src_root))
    sys.stdout.write(out.stdout.decode("utf-8", "replace"))
    sys.stdout.flush()
    if out.returncode != 0:
        die("git pull --ff-only failed in %s:\n%s— remedy: resolve the "
            "local changes or divergence it names (git -C %s status), "
            "then re-run --update"
            % (src_root, out.stderr.decode("utf-8", "replace"), src_root))
    child = subprocess.run(["bash", os.path.join(src_root, "install.sh"),
                            "--update-local"] + skills)
    sys.exit(child.returncode)

if action == "verify":
    total = 0
    recs = []
    if skills:
        for s in skills:
            found = load_records(s)
            if not found:
                err("VERIFY FAIL %s: no installation record — remedy: run "
                    "bash %s/install.sh %s" % (s, src_root, s))
                total += 1
            recs += found
    else:
        recs = load_records()
    for rec in recs:
        total += verify_record(rec)
    sys.exit(1 if total else 0)

def do_refresh(operands, skip_recordless=()):
    """The --refresh body. skip_recordless: skills without a record that the
    CALLER will handle right after (update's new-skill adoption) — for a
    plain refresh a recordless operand stays a named failure."""
    # validate every prospective destination BEFORE the state dir is
    # mutated (lock creation, temp sweep), then reload and re-validate
    # under the lock — records may have changed while unlocked
    for rec in load_records():
        validate_dest_root(os.path.dirname(rec["dest"]))
    acquire_install_lock()
    for rec in load_records():
        validate_dest_root(os.path.dirname(rec["dest"]))
    sweep_stale_temps()
    failures = 0
    targets = operands or sorted({r["skill"] for r in load_records()})
    if not targets:
        err("REFRESH: no installation records exist — nothing to refresh")
    for s in targets:
        recs = load_records(s)
        if not recs:
            if s in skip_recordless:
                continue
            err("REFRESH FAIL %s: no installation record — remedy: install "
                "first (bash %s/install.sh %s)" % (s, src_root, s))
            failures += 1
            continue
        for rec in recs:
            if os.path.realpath(rec["source"]) != src_root:
                err("REFRESH FAIL %s at %s: record points at source %s, but "
                    "this script runs from %s — remedy: refresh from the "
                    "recorded checkout, or reinstall from here explicitly"
                    % (s, rec["dest"], rec["source"], src_root))
                failures += 1
                continue
            dparent = os.path.dirname(rec["dest"])
            if os.path.normcase(os.path.realpath(dparent)) \
                    != os.path.normcase(os.path.normpath(dparent)):
                # refreshing through install_one would silently retarget the
                # physical tree behind the alias under a NEW record — refuse
                err("REFRESH FAIL %s at %s: the destination root is no "
                    "longer canonical (aliased through a symlink) — remedy: "
                    "reinstall into the real location" % (s, rec["dest"]))
                failures += 1
                continue
            install_one(s, rec["mode"], dparent)
    return failures

if action == "refresh":
    sys.exit(1 if do_refresh(skills) else 0)

if action == "update-local":
    src_skills = discover_source_skills()
    failures = do_refresh(skills, skip_recordless=set(src_skills))
    # NEW-skill adoption: a skill present in the (just pulled) source but
    # recorded NOWHERE at a destination root is installed there — an old
    # user's `--update` must deliver new functionality, not only refresh
    # what they already had. The root's mode is reused when its records
    # agree; mixed records fall back to the auto capability test. The lock
    # from do_refresh is still held (process-lifetime).
    recs = load_records()
    roots = {}
    for r in recs:
        roots.setdefault(os.path.dirname(r["dest"]), set()).add(r["mode"])
    if not roots:
        err("UPDATE: nothing is installed from this checkout yet — run a "
            "plain install first (bash %s/install.sh)" % src_root)
    wanted = [s for s in src_skills if not skills or s in skills]
    for root in sorted(roots):
        mode = list(roots[root])[0] if len(roots[root]) == 1 else "auto"
        have = set()
        for r in recs:
            if os.path.dirname(r["dest"]) == root:
                have.add(r["skill"])
        for s in wanted:
            if s in have:
                continue
            print("NEW skill %s — installing at %s" % (s, root))
            install_one(s, mode, root)
    sys.exit(1 if failures else 0)

validate_dest_root(dest_root)   # BEFORE the lock mutates the state dir
acquire_install_lock()
sweep_stale_temps()
for s in skills:
    install_one(s, mode_req, dest_root)
INSTALL_PY
