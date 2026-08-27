#!/usr/bin/env bash
# Launcher process-contract harness — OBSERVE-ONLY (rev 8, contract-narrowed
# redesign after two exhausted review budgets; see the project plan record).
#
# THE SIGNAL LAW. This harness delivers signals at exactly THREE sites, and
# each of them IS the contract under test — never housekeeping:
#   1. C4: one operator-style `kill <recorded pid>` of the pid-file value —
#      the termination contract itself — after the value is validated to be
#      the harness's own tracked payload (map to native, compare image AND
#      start identity against the record captured at track time).
#   2. C5 control: one `kill -HUP` to the PID of a wrapper shell the
#      harness just spawned (the control measures whether shell death alone
#      reaps a child that was NOT nohup'd).
#   3. C5 subject: the same shell-pid HUP to the wrapper that ran the real
#      launcher (the detach contract: the child must survive the parent
#      shell exiting).
# `kill -0` is a liveness PROBE (signal 0 delivers nothing) — observation.
# There is NO other kill: no cleanup kills, no escalation ladders, no group
# kills, no fallback kills. Anything that outlives its clause is left to
# EXPIRE BY CONSTRUCTION and is REPORTED, never chased.
#
# THE EXPIRY LAW. Every process this harness starts is bounded by
# construction — fake payloads sleep at most FAKE_HANG (2x deadline);
# wrapper shells sleep at most HOLD (3x deadline); the C7 codex child's
# stdin is a harness-held fd whose close (including on harness death) EOFs
# the whole chain (cat EOF -> pipe close -> codex stdin EOF) — with ONE
# stated exception: the launcher under test itself (and a C7 codex that
# ignores stdin EOF) cannot be bounded by construction without killing it,
# which observe-only forbids. Such a process exceeding its deadline is a
# FAILED clause and a NAMED leftover; the harness proceeds — it never hangs
# on it and never kills it. Before the verdict a QUIESCENCE step waits out
# every construction bound and asserts all tracked processes died by
# themselves: a tracked process still ALIVE past its bound fails the run
# (exit 1); one whose state is unqueryable makes the run INCOMPLETE (exit 2)
# — QUERYFAIL is NOT dead. The workdir is then removed (or refused, with
# every leftover named: pid, image, start identity, construction bound)
# BEFORE the report, and the traps are disarmed — the verdict lines spawn
# nothing and trigger no trap-time work; the EXIT/interrupt trap covers
# only abnormal mid-run exits.
#
# Residual window, stated rather than claimed away: the C4/C5 gestures are
# pid/group-addressed because that is the OPERATOR's gesture — the contract
# is that this gesture works. Between the validate step and the signal there
# is an inherent instant in which the pid could in principle be reused; it
# would require the just-validated, self-bounded, unkilled payload to die
# AND the OS to reissue its pid within that instant. Replacing the gesture
# with a handle-based terminate would test a different contract.
#
# Clauses over review-round.sh, the gate-critical detached launcher:
#   C1 launch returns within the deadline; on timeout the harness FAILS and
#      REPORTS the survivors (recorded child, payload identity) — no kills;
#      everything it started expires by its own bound
#   C2 liveness true while the child runs
#   C3 completion: liveness turns false; verdict.json PARSES to shape
#   C4 termination: recorded-pid value validated as the tracked payload
#      (native mapping + image + start identity vs the track-time record),
#      proven ALIVE, then the ONE operator kill; observed DEAD after —
#      a transition attributable to that kill. Validation failure = REFUSE,
#      no signal
#   C5 detach: HUP delivered to the wrapper SHELL PID with preconditions
#      (payload natively ALIVE, shell alive, delivery successful, shell
#      OBSERVED DEAD). The wrapper sleeps 3x the observation deadline so
#      natural expiry can never mimic a HUP death. A no-nohup CONTROL
#      attests whether shell death alone reaps children. The clause matches
#      the contract text — "survives the parent shell exiting" — so the
#      shell is the target. A group (terminal-hangup) delivery is
#      deliberately NOT simulated: on MSYS ANY emulated signal addressed to
#      a native process terminates it regardless of nohup (measured
#      2026-08-27 — a group HUP killed the nohup'd native payload), so
#      terminal-close survival on this platform comes from the detached
#      child not being in the signalled set, which detachment provides.
#      No job control is enabled anywhere in the harness
#   C6 pid-file honesty: the RUNTIME record format is inspected
#   C7 the PRODUCTION boundary: `nohup codex mcp-server` from bash, stdin
#      bridged by cat over a fifo whose writer fd is HELD BY THE HARNESS.
#      Residency is observed at the NATIVE layer; teardown is ONLY the
#      fd-close EOF chain, then exit is OBSERVED. A child that survives EOF
#      is REPORTED, never killed. Native pid OWNED via /proc/$!/winpid
#      ($! on POSIX), STRICT: no mapping -> no native ops -> INCOMPLETE.
#      REQUIRED: a skip yields exit 2 (CHECK_LAUNCHER_ALLOW_NO_CODEX=1
#      downgrades only the exit code, only for codex-availability skips)
#
# Identity rails: EVERY tracked process — natives and wrapper shells alike —
# carries image+START IDENTITY captured at track time, and liveness is
# classified ALIVE/DEAD/QUERYFAIL at the native layer (an identity mismatch
# on a live pid means the ORIGINAL is dead and the pid was reused; a failed
# identity query is QUERYFAIL, never death). A blank or LOW-RESOLUTION start
# identity (the ps-lstart fallback resolves whole seconds) disqualifies the
# pid from ever being a signal target — C4 and C5 refuse rather than signal
# at less-than-reuse precision. Every signal site re-validates the target's
# identity against its track-time record immediately before delivery, and a
# signal whose DELIVERY fails (nonzero kill status) fails its clause — a
# natural death during the observation window must never masquerade as an
# attributable transition. QUERYFAIL never means dead. The C5 holder sleeps
# are spawned in background with their pids PUBLISHED and tracked, so no
# process the harness caused to exist escapes the quiescence assertion. Sealed PATH: fake +
# DENY stub; the real codex is unreachable from any harness-launched path.
# All waits are polled deadlines (CHECK_LAUNCHER_DEADLINE, default 15s).
# Env knobs tune deadlines and downgrade exit codes; none disables a clause
# or widens a capability. ATTESTATION BOUNDARY, stated precisely: every
# artifact is hashed BEFORE the clauses run, and all executed artifacts are
# re-verified at a fixed boundary after the clauses and before quiescence
# (a hash of different bytes than were exercised is worthless). The
# quiescence measurement itself necessarily runs the already-verified
# interpreter path AFTER that boundary — the attestation covers bytes up to
# the boundary, and that limit is disclosed here rather than claimed away.
# Version identity IS the content hash — the harness never executes any
# binary to ASK its version (an execution-based probe would be an unbounded,
# untracked spawn); the codex resolver is executed exactly once, by C7, AS
# the boundary subject under test; the C7 image is hashed at OBSERVATION
# time, not resolved from PATH. After quiescence and the in-window cleanup
# the harness only prints precomputed strings and exits, with traps
# disarmed. Fail closed. Bash 3.2 compatible; BSD/GNU neutral.
set -u
fail=0
inc_c7=0
inc_other=0
say() { printf '%s\n' "$*"; }
pass() { say "PASS: $1"; }
flunk() { say "FAIL: $1"; fail=1; }
DEADLINE=${CHECK_LAUNCHER_DEADLINE:-15}
HOLD=$((DEADLINE * 3))       # wrapper-shell bound (C5 holder)
FAKE_HANG=$((DEADLINE * 2))  # hang-payload bound
TAB=$(printf '\t')

HERE=$(cd "$(dirname "$0")" && pwd)
LAUNCHER="$HERE/../skills/codex-debate/scripts/review-round.sh"
[ -f "$LAUNCHER" ] || { say "ERROR: launcher not found: $LAUNCHER"; exit 1; }
PY=$(command -v python3 || command -v python) || { say "ERROR: no python"; exit 1; }
NOHUP=$(command -v nohup) || { say "ERROR: no nohup"; exit 1; }
# environment strings captured ONCE, pre-run: the post-quiescence report is
# pure printing and must not execute anything to compose itself
UNAME_STR=$(uname -srm)
PY_VER=$("$PY" -c 'import sys;print(sys.version.split()[0])')

T=$(mktemp -d "${TMPDIR:-/tmp}/launcher-contract.XXXXXX") || exit 1
TN=$(cygpath -m "$T" 2>/dev/null || printf %s "$T")
PIDS="$T/native.pids"    # lines: <pid>TAB<image>TAB<start-identity>TAB<bound note>
SHELLS="$T/shell.pids"   # lines: <pid>TAB<bound note>

# ---- identity: image + start time, read together -----------------------------
ident_of() { # $1 = native pid; prints "<image>TAB<start>" or nothing
  "$PY" - "$1" <<'PI' 2>/dev/null
import os,sys
pid=int(sys.argv[1])
if os.name=="nt":
    import ctypes
    from ctypes import wintypes
    k=ctypes.windll.kernel32
    h=k.OpenProcess(0x1000,False,pid)
    if not h: sys.exit(0)
    buf=ctypes.create_unicode_buffer(2048); n=wintypes.DWORD(2048)
    img=""
    if k.QueryFullProcessImageNameW(h,0,buf,ctypes.byref(n)): img=buf.value
    ct=ctypes.c_ulonglong(); et=ctypes.c_ulonglong()
    kt=ctypes.c_ulonglong(); ut=ctypes.c_ulonglong()
    st=""
    if k.GetProcessTimes(h,ctypes.byref(ct),ctypes.byref(et),
                         ctypes.byref(kt),ctypes.byref(ut)):
        st=str(ct.value)
    k.CloseHandle(h)
    if img: sys.stdout.write("%s\t%s" % (img,st))
else:
    img=""; st=""
    try: img=os.path.realpath(os.readlink("/proc/%d/exe" % pid))
    except OSError: pass
    try:
        with open("/proc/%d/stat" % pid) as f:
            st=f.read().rsplit(")",1)[1].split()[19]   # starttime field
    except OSError:
        if sys.platform=="darwin":
            # high-resolution creation identity: proc_pidpath for the image,
            # sysctl kern.proc.pid for p_starttime (sec.usec) — ps lstart is
            # whole-second and would pass a within-the-second pid reuse
            try:
                import ctypes,struct
                libc=ctypes.CDLL("/usr/lib/libSystem.B.dylib",use_errno=True)
                buf=ctypes.create_string_buffer(4096)
                libc.proc_pidpath.restype=ctypes.c_int
                if libc.proc_pidpath(ctypes.c_int(pid),buf,ctypes.c_uint32(4096))>0:
                    img=os.path.realpath(buf.value.decode("utf-8","replace"))
                sz=ctypes.c_size_t(0)
                mib=(ctypes.c_int*4)(1,14,1,pid)  # CTL_KERN, KERN_PROC, KERN_PROC_PID
                if libc.sysctl(mib,4,None,ctypes.byref(sz),None,0)==0 and sz.value:
                    raw=ctypes.create_string_buffer(sz.value)
                    if libc.sysctl(mib,4,raw,ctypes.byref(sz),None,0)==0:
                        sec,usec=struct.unpack_from("@li",raw.raw,0)  # timeval at offset 0
                        if sec: st="%d.%06d" % (sec,usec)
            except Exception:
                pass
        if not (img and st):
            # last resort, explicitly LOW-RESOLUTION: lstart has 1s grain, so
            # this identity is valid for tracking but DISQUALIFIED for signals
            import subprocess
            out=subprocess.run(["ps","-p",str(pid),"-o","lstart=,comm="],
                               capture_output=True,text=True).stdout.strip()
            if out:
                st="LOWRES:"+" ".join(out.split()[:5]); img=img or out.split(None,5)[-1]
    if img or st: sys.stdout.write("%s\t%s" % (img,st))
PI
}

# ALIVE / DEAD / QUERYFAIL at the NATIVE layer (WaitForSingleObject, never
# the exit-code-259 heuristic; a query failure is never treated as death).
native_state() { # $1 = native pid
  "$PY" - "$1" <<'PS' 2>/dev/null || printf 'QUERYFAIL'
import os,sys
pid=int(sys.argv[1])
if os.name=="nt":
    import ctypes
    from ctypes import wintypes
    k=ctypes.windll.kernel32
    k.OpenProcess.restype=wintypes.HANDLE
    k.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD]
    k.WaitForSingleObject.restype=wintypes.DWORD
    k.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD]
    h=k.OpenProcess(0x00100000,False,pid)  # SYNCHRONIZE
    if not h:
        err=k.GetLastError()
        sys.stdout.write("DEAD" if err==87 else "QUERYFAIL")
        sys.exit(0)
    r=k.WaitForSingleObject(h,0)
    k.CloseHandle(h)
    sys.stdout.write("ALIVE" if r==0x102 else "DEAD" if r==0 else "QUERYFAIL")
else:
    try:
        os.kill(pid,0); sys.stdout.write("ALIVE")
    except ProcessLookupError:
        sys.stdout.write("DEAD")
    except OSError:
        sys.stdout.write("QUERYFAIL")
PS
}

wait_for() { # $1 = predicate function name
  i=0; lim=$((DEADLINE * 5))
  while [ $i -lt $lim ]; do "$1" && return 0; sleep 0.2; i=$((i+1)); done
  return 1
}

# Native pid of an MSYS job pid. STRICT: on MSYS poll /proc/<pid>/winpid and
# FAIL (no output) if it never appears — the raw $! is an MSYS-table number
# that may collide with an unrelated native pid and must never be used for
# native operations. On POSIX $! IS the native pid.
native_of_job() { # $1 = $! value
  case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*)
      i=0
      while [ $i -lt 25 ]; do
        if [ -r "/proc/$1/winpid" ]; then cat "/proc/$1/winpid"; return 0; fi
        sleep 0.2; i=$((i+1))
      done
      return 1 ;;
    *) printf %s "$1" ;;
  esac
}

# ---- tracking (observation records; cleanup only ever WAITS on these) --------
# SHELLS lines: <msys-pid>TAB<native-pid>TAB<image>TAB<start>TAB<note> —
# wrapper shells carry the same native identity as native records, so their
# liveness gets the same three-state classification (an identity mismatch on
# a live pid means the ORIGINAL died and the pid was reused; a failed query
# is QUERYFAIL, never death).
track_shell() { # $1 msys pid, $2 bound note — native identity captured NOW
  sn=$(native_of_job "$1") || sn=""
  sid=""
  [ -n "$sn" ] && sid=$(ident_of "$sn")
  printf '%s\t%s\t%s\t%s\n' "$1" "${sn:-}" "${sid:-$TAB}" "$2" >> "$SHELLS"
}
track_native() { # $1 pid, $2 image, $3 bound note — start identity NOW
  id=$(ident_of "$1")
  st=${id#*"$TAB"}
  if [ -z "$st" ] && [ "$(native_state "$1")" != DEAD ]; then
    say "note: start identity BLANK for live native pid $1 ($2) — this pid is disqualified as a kill target"
  fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${st:-}" "$3" >> "$PIDS"
}
# Identity-aware liveness. Only a COMPLETE, DIFFERING start identity proves
# reuse; a partial or failed identity query on a live pid is QUERYFAIL,
# never death. The start time is the invariant (an image change on the same
# pid+start is the same process after exec, not a reuse), so lifecycle
# comparison is start-only; the stricter full image+start match is reserved
# for SIGNAL validation, where a mismatch merely refuses.
native_rec_state() { # $1 pid, $2 image (unused for lifecycle), $3 start -> ALIVE/DEAD/QUERYFAIL
  s=$(native_state "$1")
  if [ "$s" = ALIVE ]; then
    if [ -z "$3" ]; then
      s=QUERYFAIL   # no track-time start identity: a live pid here is unattributable
    else
      cur=$(ident_of "$1"); curst=${cur#*"$TAB"}
      if [ -z "$cur" ] || [ -z "$curst" ]; then
        s=QUERYFAIL   # partial query is NOT evidence of reuse
      else
        rlow=0; clow=0
        [ "${3#LOWRES:}" != "$3" ] && rlow=1
        [ "${curst#LOWRES:}" != "$curst" ] && clow=1
        if [ "$rlow" -ne "$clow" ]; then
          s=QUERYFAIL   # identities from different resolution domains are incomparable
        elif [ "$curst" != "$3" ]; then
          s=DEAD        # complete, same-domain, differing start: pid reused, original gone
        fi
      fi
    fi
  fi
  printf %s "$s"
}
shell_state() { # $1 msys pid, $2 native pid, $3 image, $4 start -> ALIVE/DEAD/QUERYFAIL
  if [ -n "$2" ]; then
    native_rec_state "$2" "$3" "$4"
  else
    # never natively mapped (it died before the mapping appeared). It is our
    # own DIRECT child, so kill(0) failure is ESRCH, not EPERM; the msys-table
    # reuse window is the residual disclosed in the header.
    kill -0 "$1" 2>/dev/null && printf ALIVE || printf DEAD
  fi
}
untrack_dead() { # drop ONLY explicitly-DEAD records; ALIVE and QUERYFAIL stay
  if [ -f "$PIDS" ]; then
    : > "$PIDS.new"
    while IFS= read -r line; do
      p=${line%%"$TAB"*}; rest=${line#*"$TAB"}
      pimg=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
      pst=${rest%%"$TAB"*}
      [ -n "$p" ] && [ "$(native_rec_state "$p" "$pimg" "$pst")" != DEAD ] && printf '%s\n' "$line" >> "$PIDS.new"
    done < "$PIDS"
    mv "$PIDS.new" "$PIDS"
  fi
  if [ -f "$SHELLS" ]; then
    : > "$SHELLS.new"
    while IFS= read -r line; do
      sp=${line%%"$TAB"*}; rest=${line#*"$TAB"}
      snat=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
      simg=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
      sst=${rest%%"$TAB"*}
      [ -n "$sp" ] && [ "$(shell_state "$sp" "$snat" "$simg" "$sst")" != DEAD ] \
        && printf '%s\n' "$line" >> "$SHELLS.new"
    done < "$SHELLS"
    mv "$SHELLS.new" "$SHELLS"
  fi
}
inventory() { # name every tracked thing that is not verifiably dead
  if [ -f "$SHELLS" ]; then
    while IFS= read -r line; do
      sp=${line%%"$TAB"*}; rest=${line#*"$TAB"}
      snat=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
      simg=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
      sst=${rest%%"$TAB"*}; snote=${rest#*"$TAB"}
      [ -n "$sp" ] || continue
      s=$(shell_state "$sp" "$snat" "$simg" "$sst")
      [ "$s" = DEAD ] || say "  survivor (shell): msys=$sp native=${snat:-?} state=$s image=${simg:-?} start=${sst:-?} bound=$snote"
    done < "$SHELLS"
  fi
  if [ -f "$PIDS" ]; then
    while IFS= read -r line; do
      p=${line%%"$TAB"*}; rest=${line#*"$TAB"}
      img=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
      stid=${rest%%"$TAB"*}; note=${rest#*"$TAB"}
      [ -n "$p" ] || continue
      s=$(native_rec_state "$p" "$img" "$stid")
      [ "$s" = DEAD ] || say "  survivor (native): pid=$p state=$s image=$img start=$stid bound=$note"
    done < "$PIDS"
  fi
}

# Observe-only cleanup: close the C7 holder fd (the EOF chain unwinds
# itself), then WAIT — bounded by the largest construction bound — for
# everything tracked to die by itself. Refuse to delete the workdir while
# anything tracked is alive or unqueryable; name the leftovers.
cleanup() {
  exec 8>&-
  i=0; lim=$(((HOLD + DEADLINE) * 5))
  while :; do
    untrack_dead
    { [ -s "$SHELLS" ] || [ -s "$PIDS" ]; } || break
    [ $i -ge $lim ] && break
    sleep 0.2; i=$((i+1))
  done
  if [ -s "$SHELLS" ] || [ -s "$PIDS" ]; then
    say "CLEANUP: a tracked process has not expired within its construction bound — leaving workdir (deny stub included) in place: $T" >&2
    inventory >&2
    return 0
  fi
  rm -rf "$T"
}
on_signal() { # cleanup AND EXIT — never resume into a deleted $T
  sig=$1
  trap - EXIT INT TERM HUP
  cleanup
  exit $((128 + sig))
}
trap cleanup EXIT
trap 'on_signal 2' INT
trap 'on_signal 15' TERM
trap 'on_signal 1' HUP

# --- fake reviewer: bash shim -> NATIVE python payload (shim topology is
# attested as such; C7 covers the direct production boundary). The beacon is
# ONE atomically-renamed record: <pid>TAB<canonical image>. The hang mode is
# BOUNDED: the payload sleeps at most the bound passed by the shim.
mkdir -p "$T/bin"
cat > "$T/fakepayload.py" <<'PYP'
import os,sys,time
beacon=sys.argv[1]; mode=sys.argv[2]
bound=float(sys.argv[3]) if len(sys.argv)>3 else 120.0
tmp=beacon+".tmp"
with open(tmp,"w") as f: f.write("%d\t%s" % (os.getpid(),os.path.realpath(sys.executable)))
os.replace(tmp,beacon)   # atomic: readers never see a partial record
sys.stdout.write("EVENT-MARKER-STDOUT\n"); sys.stdout.flush()
sys.stderr.write("EVENT-MARKER-STDERR\n"); sys.stderr.flush()
if mode=="hang":
    time.sleep(bound)
else:
    i=sys.argv.index("-o") if "-o" in sys.argv else -1
    if i>0:
        with open(sys.argv[i+1],"w") as f:
            f.write('{"verdict":"APPROVED","summary":"fake","findings":[]}')
PYP
cat > "$T/bin/codex" <<FAKE
#!/usr/bin/env bash
exec "$PY" "$TN/fakepayload.py" "$TN/beacon" "\$(cat "$T/fake.mode" 2>/dev/null || echo hang)" "$FAKE_HANG" "\$@"
FAKE
chmod +x "$T/bin/codex"
mkdir -p "$T/deny"
cat > "$T/deny/codex" <<'DENY'
#!/usr/bin/env bash
echo "DENIED: fake codex missing — harness refuses to touch the real codex" >&2
exit 86
DENY
chmod +x "$T/deny/codex"
SEALED_PATH="$T/bin:$T/deny:$PATH"

have_beacon() { [ -s "$T/beacon" ] && grep -q "$TAB" "$T/beacon"; }
beacon_pid() { cut -f1 "$T/beacon" 2>/dev/null; }
payload_img() { cut -f2 "$T/beacon" 2>/dev/null; }
beacon_start() { # start identity of the tracked beacon pid (from PIDS)
  grep "^$(beacon_pid)$TAB" "$PIDS" 2>/dev/null | tail -1 | cut -f3
}
track_beacon() { # $1 bound note
  have_beacon || return 1
  track_native "$(beacon_pid)" "$(payload_img)" "$1"
}
run_dir_new() { rm -rf "$T/run"; mkdir -p "$T/run"; printf 'x\n' > "$T/run/round.input"; rm -f "$T/beacon"; }

assert_fake() { # true only when codex resolves to OUR fake on the sealed path
  resolved=$(PATH="$SEALED_PATH" command -v codex)
  [ "$resolved" = "$T/bin/codex" ]
}

# ---- attestation baseline: hash BEFORE anything runs --------------------------
hash16() { # $1 = path in any form; prints 16 hex chars or UNHASHABLE
  h=$("$PY" - "$(cygpath -m "$1" 2>/dev/null || printf %s "$1")" <<'PH' 2>/dev/null
import hashlib,sys
h=hashlib.sha256()
with open(sys.argv[1],"rb") as f:
    for b in iter(lambda: f.read(1<<20), b""): h.update(b)
print(h.hexdigest()[:16])
PH
) || h=""
  if [ -n "$h" ]; then printf %s "$h"; else printf UNHASHABLE; fi
}
H_BASH=$(hash16 "$BASH");            [ "$H_BASH" = UNHASHABLE ] && flunk "attestation: bash unhashable"
H_PY=$(hash16 "$PY");                [ "$H_PY" = UNHASHABLE ] && flunk "attestation: python unhashable"
H_NOHUP=$(hash16 "$NOHUP");          [ "$H_NOHUP" = UNHASHABLE ] && flunk "attestation: nohup unhashable"
H_SELF=$(hash16 "$HERE/check-launcher.sh"); [ "$H_SELF" = UNHASHABLE ] && flunk "attestation: harness unhashable"
H_FAKE=$(hash16 "$T/fakepayload.py"); [ "$H_FAKE" = UNHASHABLE ] && flunk "attestation: fake payload unhashable"
H_SHIM=$(hash16 "$T/bin/codex");     [ "$H_SHIM" = UNHASHABLE ] && flunk "attestation: fake shim unhashable"
H_LAUNCH=$(hash16 "$LAUNCHER");      [ "$H_LAUNCH" = UNHASHABLE ] && flunk "attestation: launcher unhashable"
# The codex resolver binary is hashed here and re-verified after the run.
# It is executed exactly ONCE — by C7, as the production-boundary subject
# under test — and never for version probing: version identity IS the
# content hash (an execution-based --version probe would be an unbounded,
# untracked spawn). The C7 image is hashed at observation time inside the
# clause.
CODEX_BIN=$(command -v codex || true)
H_CODEXBIN=none
if [ -n "$CODEX_BIN" ]; then
  H_CODEXBIN=$(hash16 "$CODEX_BIN")
  [ "$H_CODEXBIN" = UNHASHABLE ] && flunk "attestation: codex resolver binary unhashable"
fi

# ---- C1 (watchdog OBSERVES; on timeout it fails and names the survivors) -----
echo hang > "$T/fake.mode"; run_dir_new
assert_fake || { flunk "SAFETY: codex does not resolve to the fake on the sealed path — refusing every launch"; exit 1; }
bash -c "[ -x \"$T/bin/codex\" ] || exit 86; PATH=\"$SEALED_PATH\" bash \"$LAUNCHER\" \"$T/run\" fake-model low \"$LAUNCHER\"" > "$T/launch.out" 2>/dev/null &
LW=$!; track_shell "$LW" "C1 launch wrapper (a hung launcher is a FAILED clause and a named leftover)"
launch_done() { ! kill -0 "$LW" 2>/dev/null; }
t0=$SECONDS
if wait_for launch_done; then
  t1=$((SECONDS - t0))
  [ "$t1" -le 5 ] && pass "C1 launch returned in ${t1}s (deadline 5s)" \
    || flunk "C1 launch took ${t1}s (over the 5s deadline)"
else
  flunk "C1 WATCHDOG: launch still blocked at ${DEADLINE}s — no signal sent; survivors expire by construction and are named here"
  if [ -s "$T/run/pid" ]; then
    recp=$(cat "$T/run/pid")
    if recnat=$(native_of_job "$recp") && [ -n "$recnat" ]; then
      recid=$(ident_of "$recnat"); recimg=${recid%%"$TAB"*}
      [ -n "$recimg" ] && track_native "$recnat" "$recimg" "C1 recorded child (payload bound ${FAKE_HANG}s)"
    else
      say "  survivor (unmapped): recorded MSYS pid $recp has no native mapping — no native ops attempted"
    fi
  fi
  have_beacon && track_beacon "C1 payload (hang bound ${FAKE_HANG}s)"
  inventory
fi
out=$(cat "$T/launch.out" 2>/dev/null)
case $out in *launched\ pid=*) pass "C1 pid line printed" ;; *) flunk "C1 no pid line: $out" ;; esac
[ -s "$T/run/pid" ] && pass "C1 pid file written" || flunk "C1 pid file missing"
c1_tracked=0
if wait_for have_beacon; then track_beacon "C1 payload (hang bound ${FAKE_HANG}s)" && c1_tracked=1
else flunk "C1 native child never started"; fi
evmark() { grep -q 'EVENT-MARKER-STDOUT' "$T/run/events.jsonl" 2>/dev/null; }
wait_for evmark && pass "C1 stdout redirected into events.jsonl (marker found)" \
  || flunk "C1 stdout marker never reached events.jsonl"
grep -q 'EVENT-MARKER-STDERR' "$T/run/stderr.log" 2>/dev/null \
  && pass "C1 stderr redirected into stderr.log" \
  || flunk "C1 stderr marker not in stderr.log"

# ---- C2 ----------------------------------------------------------------------
pidrec=$(cat "$T/run/pid" 2>/dev/null)
case $pidrec in
  ''|*[!0-9]*) flunk "C2 pid record unusable ('$pidrec') — liveness not probed"; pidrec="" ;;
  *) if kill -0 "$pidrec" 2>/dev/null; then pass "C2 liveness true while running"
     else flunk "C2 kill -0 false while the native child runs"; fi ;;
esac

# ---- C4 (THE operator kill: validate the recorded value, then signal once) ----
if [ -z "$pidrec" ]; then
  flunk "C4 refuse: no usable pid record — no signal sent"
elif [ "$c1_tracked" -ne 1 ]; then
  flunk "C4 refuse: payload was never tracked — no signal sent"
else
  bnat=$(beacon_pid); bst=$(beacon_start)
  st=$(native_state "$bnat")
  if [ "$st" != ALIVE ]; then
    flunk "C4 vacuous: child state was $st before the kill — nothing attested, no signal sent"
  elif ! recnat=$(native_of_job "$pidrec") || [ -z "$recnat" ]; then
    flunk "C4 refuse: recorded pid $pidrec has no native mapping — no signal sent"
  elif [ "$recnat" != "$bnat" ]; then
    flunk "C4 refuse: recorded pid maps to native $recnat, but the tracked payload is $bnat — pid record does not identify the child; no signal sent"
  elif [ -z "$bst" ]; then
    inc_other=1
    say "C4 REFUSE (INCOMPLETE): tracked start identity is blank — kill target unverifiable; no signal sent"
  elif [ "${bst#LOWRES:}" != "$bst" ]; then
    inc_other=1
    say "C4 REFUSE (INCOMPLETE): start identity is low-resolution on this platform (1s grain cannot exclude pid reuse) — no signal sent"
  else
    curid=$(ident_of "$recnat")
    curimg=$(printf %s "${curid%%"$TAB"*}" | tr '[:upper:]' '[:lower:]')
    curst=${curid#*"$TAB"}
    wantimg=$(payload_img | tr '[:upper:]' '[:lower:]')
    if [ -z "$curimg" ] || [ "$curimg" != "$wantimg" ] || [ "$curst" != "$bst" ]; then
      flunk "C4 refuse: identity mismatch at validation (image '$curimg' vs '$wantimg', start '$curst' vs '$bst') — no signal sent"
    else
      pass "C4 precondition: recorded pid validated as the tracked payload (native $recnat, image+start match), ALIVE"
      if kill "$pidrec" 2>/dev/null; then   # SIGNAL SITE 1 of 3: the termination contract
        dead_now() { [ "$(native_state "$bnat")" = DEAD ]; }
        if wait_for dead_now; then pass "C4 native child DEAD after killing the recorded pid"
        else
          flunk "C4 native child survived the recorded-pid kill (state=$(native_state "$bnat")) — REPORTED, not chased; it expires by its ${FAKE_HANG}s bound"
        fi
      else
        flunk "C4 signal DELIVERY failed (kill returned nonzero) — no transition is attributable; a later natural death would not be this contract"
      fi
    fi
  fi
fi
untrack_dead

# ---- C3 (async like every launcher invocation: a hung launcher must not
#          hang the harness — it fails the clause and becomes a named leftover)
echo quick > "$T/fake.mode"; run_dir_new
if assert_fake; then
  bash -c "PATH=\"$SEALED_PATH\" bash \"$LAUNCHER\" \"$T/run\" fake-model low \"$LAUNCHER\"" >/dev/null 2>&1 &
  C3W=$!; track_shell "$C3W" "C3 launch wrapper (a hung launcher is a FAILED clause and a named leftover)"
  c3_done() { ! kill -0 "$C3W" 2>/dev/null; }
  wait_for c3_done || flunk "C3 launch did not return within ${DEADLINE}s"
else
  flunk "SAFETY: codex does not resolve to the fake on the sealed path — C3 not launched"
fi
wait_for have_beacon && track_beacon "C3 payload (quick mode, exits by itself)"
done_now() { pr=$(cat "$T/run/pid" 2>/dev/null); [ -n "$pr" ] && ! kill -0 "$pr" 2>/dev/null; }
wait_for done_now && pass "C3 liveness false after completion" \
  || flunk "C3 liveness stuck true after exit"
if "$PY" - "$TN/run/verdict.json" <<'PV' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
ok=(d.get("verdict")=="APPROVED" and isinstance(d.get("findings"),list))
sys.exit(0 if ok else 1)
PV
then pass "C3 verdict.json parses with the expected shape"
else flunk "C3 verdict.json missing, truncated or wrong shape"; fi
untrack_dead

# ---- C5 (holder = 3x deadline: natural expiry cannot mimic a HUP death) -------
# The HUP targets are wrapper-shell PIDS, never groups (see the header:
# group delivery is unfaithful on MSYS, where any emulated signal kills a
# native process regardless of nohup). Each wrapper receives exactly one
# HUP and nothing else, ever; every member expires by its own bound.
# A wrapper is a valid HUP target only while its identity (native image +
# start, captured at spawn) still matches — a reused pid must never be
# signalled, and a LOW-RESOLUTION start identity (1s lstart grain) is not
# precise enough to exclude reuse, so it disqualifies the target. The holder
# sleep is spawned in BACKGROUND with its pid PUBLISHED for tracking, and
# the shell stays resident in the `wait` builtin (so bash cannot
# exec-replace itself with the final command and the HUP target stays a
# shell); on HUP the wait is interrupted and the shell exits.
wrap_ident() { # $1 = wrapper job pid; prints "<nat>TAB<img>TAB<st>", fails if unidentifiable
  wn=$(native_of_job "$1") || return 1
  [ -n "$wn" ] || return 1
  wi=$(ident_of "$wn")
  wimg=${wi%%"$TAB"*}
  wst=${wi#*"$TAB"}
  # BOTH fields must be present — ident_of can return a start with no image
  # when the image query fails, and a signal target needs the full identity
  [ -n "$wimg" ] && [ -n "$wst" ] || return 1
  case $wst in LOWRES:*) return 1 ;; esac
  printf '%s\t%s\n' "$wn" "$wi"
}
echo hang > "$T/fake.mode"; run_dir_new
rm -f "$T/beacon" "$T/ctl.hold.pid" "$T/subj.hold.pid"
bash -c "\"$PY\" \"$TN/fakepayload.py\" \"$TN/beacon\" hang $FAKE_HANG > \"$T/ctl.out\" 2>&1 & sleep $HOLD & printf %s \"\$!\" > \"$T/ctl.hold.pid\"; wait" 2>/dev/null &
CTLJOB=$!
# The signal-target baseline IS the tracking record: captured once, here,
# and used verbatim for the pre-HUP re-validation — never re-baselined.
CTLWREC=$(wrap_ident "$CTLJOB") || CTLWREC=""
if [ -n "$CTLWREC" ]; then
  printf '%s\t%s\t%s\n' "$CTLJOB" "$CTLWREC" "C5 control shell (holds <= ${HOLD}s)" >> "$SHELLS"
else
  track_shell "$CTLJOB" "C5 control shell (holds <= ${HOLD}s)"
fi
disown "$CTLJOB" 2>/dev/null || true   # bookkeeping only: silences the shell's async job notice for the HUP'd wrapper; liveness checks are pid probes, not job-table lookups
ctl_hold_seen() { [ -s "$T/ctl.hold.pid" ]; }
if wait_for ctl_hold_seen; then
  track_shell "$(cat "$T/ctl.hold.pid")" "C5 control holder sleep (${HOLD}s)"
elif kill -0 "$CTLJOB" 2>/dev/null; then
  inc_other=1; say "C5 control INCOMPLETE: holder sleep pid never published while the wrapper lives — its quiet exit cannot be attested"
fi
ctl_ok=1
if wait_for have_beacon && track_beacon "C5 control payload (hang bound ${FAKE_HANG}s)"; then :
else flunk "C5 control payload never started"; ctl_ok=0; fi
CTLPID=$(beacon_pid)
ctl_state=UNTESTED
if [ "$ctl_ok" -eq 1 ]; then
  CTLWNAT=${CTLWREC%%"$TAB"*}
  if [ -z "$CTLWREC" ]; then
    ctl_state=WRAPPER_UNIDENTIFIABLE
  elif [ "$(native_state "$CTLPID")" != ALIVE ]; then
    ctl_state=CRASHED_PRE_HUP
  elif [ "$(ident_of "$CTLWNAT")" != "${CTLWREC#*"$TAB"}" ]; then
    ctl_state=WRAPPER_IDENTITY_DRIFT
  elif ! kill -0 "$CTLJOB" 2>/dev/null; then
    ctl_state=SHELLGONE
  elif kill -HUP "$CTLJOB" 2>/dev/null; then   # SIGNAL SITE 2 of 3: the shell-exit control
    ctl_shell_dead() { ! kill -0 "$CTLJOB" 2>/dev/null; }
    if wait_for ctl_shell_dead; then ctl_state=$(native_state "$CTLPID")
    else ctl_state=SHELL_IGNORED_HUP; fi
  else
    ctl_state=SIGFAIL
  fi
fi
case $ctl_state in
  DEAD|ALIVE) : ;;   # conclusive: the control measured something
  UNTESTED) : ;;     # already flunked above (payload never started)
  *) inc_other=1
     say "C5 control INCOMPLETE (state=$ctl_state) — signal site 2 was refused or not exercised conclusively; no signal sent on the refusal paths" ;;
esac
# no cleanup kills: the control payload/shell expire by their own bounds
run_dir_new
bash -c "[ -x \"$T/bin/codex\" ] || exit 86; PATH=\"$SEALED_PATH\" bash \"$LAUNCHER\" \"$T/run\" fake-model low \"$LAUNCHER\" >/dev/null 2>&1; sleep $HOLD & printf %s \"\$!\" > \"$T/subj.hold.pid\"; wait" 2>/dev/null &
LJOB=$!
LWREC=$(wrap_ident "$LJOB") || LWREC=""   # baseline = tracking record, captured once
if [ -n "$LWREC" ]; then
  printf '%s\t%s\t%s\n' "$LJOB" "$LWREC" "C5 subject shell (holds <= ${HOLD}s)" >> "$SHELLS"
else
  track_shell "$LJOB" "C5 subject shell (holds <= ${HOLD}s)"
fi
disown "$LJOB" 2>/dev/null || true   # bookkeeping only: silences the async job notice
subj_hold_seen() { [ -s "$T/subj.hold.pid" ]; }
if wait_for subj_hold_seen; then
  track_shell "$(cat "$T/subj.hold.pid")" "C5 subject holder sleep (${HOLD}s)"
elif kill -0 "$LJOB" 2>/dev/null; then
  inc_other=1; say "C5 subject INCOMPLETE: holder sleep pid never published while the wrapper lives — its quiet exit cannot be attested"
fi
LWNAT=${LWREC%%"$TAB"*}
wait_for have_beacon && track_beacon "C5 subject payload (hang bound ${FAKE_HANG}s)" \
  || flunk "C5 launcher payload never started"
if [ -z "$LWREC" ]; then
  inc_other=1
  say "C5 REFUSE (INCOMPLETE): subject wrapper unidentifiable at the native layer — no signal sent"
elif [ "$(native_state "$(beacon_pid)")" != ALIVE ]; then
  flunk "C5 precondition: launcher payload not ALIVE before HUP"
elif [ "$(ident_of "$LWNAT")" != "${LWREC#*"$TAB"}" ]; then
  flunk "C5 refuse: subject wrapper identity drifted since spawn — no signal sent"
elif ! kill -0 "$LJOB" 2>/dev/null; then
  flunk "C5 precondition: launching shell already dead before HUP"
elif kill -HUP "$LJOB" 2>/dev/null; then      # SIGNAL SITE 3 of 3: the detach contract
  l_shell_dead() { ! kill -0 "$LJOB" 2>/dev/null; }
  if ! wait_for l_shell_dead; then
    flunk "C5 launching shell did NOT die on HUP — the shell-exit consequence never occurred; clause unproven"
  else
    l_state=$(native_state "$(beacon_pid)")
    if [ "$l_state" = ALIVE ]; then
      case $ctl_state in
        DEAD) pass "C5 nohup is LOAD-BEARING here: control died on HUP, launcher child survived" ;;
        ALIVE) pass "C5 launcher child survives HUP (ATTEST: control survived too — HUP does not propagate to native children on this platform; detach comes from platform semantics, nohup untested-by-consequence here)" ;;
        *) pass "C5 launcher child survives HUP (ATTEST: control inconclusive: $ctl_state)" ;;
      esac
    else
      flunk "C5 launcher child not alive after HUP (state=$l_state)"
    fi
  fi
else
  flunk "C5 HUP delivery to the launching shell FAILED — clause not exercised"
fi
# no post-clause kills: the subject payload expires by its own bound
untrack_dead

# ---- C6 ----------------------------------------------------------------------
pidrec=$(cat "$T/run/pid" 2>/dev/null)
case $pidrec in
  ''|*[!0-9]*) flunk "C6 pid record is not even a bare integer: '$pidrec' — unknown format" ;;
  *) say "ATTEST C6: runtime pid record is a BARE integer ('$pidrec') — after completion the number can be reused by an unrelated process; poll promptly (KNOWN limitation, recorded, not enforced)" ;;
esac

# ---- C7 (production boundary; teardown = fd-close EOF, observed — no kill) ----
c7_attested=0
C7IMG=""
H_CODEX=none
if [ -n "$CODEX_BIN" ]; then
  mkdir -p "$T/nohome"   # CODEX_HOME must EXIST (empty = isolated, no auth)
  if mkfifo "$T/hold" 2>/dev/null && [ -p "$T/hold" ]; then
    # cat (an MSYS/POSIX process) bridges the fifo to a REAL anonymous pipe
    # that the native codex can read. The harness holds the fifo's writer on
    # fd 8: closing fd 8 -> cat EOF -> pipe close -> codex stdin EOF -> codex
    # exits. Teardown is this EOF chain and nothing else; the harness only
    # OBSERVES the exit. ORDER MATTERS: a fifo open-for-write BLOCKS until a
    # reader exists, so the cat|codex pipeline (cat = the reader) must start
    # FIRST; the exec then unblocks the moment cat opens its end.
    cat "$T/hold" | CODEX_HOME="$T/nohome" "$NOHUP" "$CODEX_BIN" mcp-server > "$T/c7.out" 2>&1 &
    C7JOB=$!; track_shell "$C7JOB" "C7 bridge chain (bounded by held-fd EOF at harness exit)"
    exec 8> "$T/hold"
    if C7NAT=$(native_of_job "$C7JOB") && [ -n "$C7NAT" ]; then
      C7ID=$(ident_of "$C7NAT"); C7IMG=${C7ID%%"$TAB"*}; C7ST=${C7ID#*"$TAB"}
      c7base=${C7IMG##*\\}; c7base=${c7base##*/}   # basename across both separators
      case $(printf %s "$c7base" | tr '[:upper:]' '[:lower:]') in
        codex|codex.exe)   # EXACT basename — a path merely CONTAINING "codex" is not the binary
          printf '%s\t%s\t%s\t%s\n' "$C7NAT" "$C7IMG" "${C7ST:-}" "C7 codex child (bounded by held-fd EOF)" >> "$PIDS"
          H_CODEX=$(hash16 "$C7IMG")   # hash the OBSERVED image, at observation time
          c7_alive() { [ "$(native_state "$C7NAT")" = ALIVE ]; }
          if wait_for c7_alive && sleep 1 && c7_alive; then
            pass "C7 real native codex resident at NATIVE pid $C7NAT via nohup (image: $C7IMG)"
            exec 8>&-   # teardown = the EOF chain; nothing is signalled
            c7_gone() { [ "$(native_state "$C7NAT")" = DEAD ]; }
            if wait_for c7_gone; then
              pass "C7 native codex exited on stdin EOF (fd-close teardown observed at the native layer)"
              c7_attested=1
            else
              flunk "C7 native codex survived the EOF teardown (state=$(native_state "$C7NAT")) — REPORTED, not killed: pid=$C7NAT image=$C7IMG start=${C7ST:-?}"
            fi
          else
            flunk "C7 observed codex image exited or vanished before residency was established ($(head -1 "$T/c7.out" 2>/dev/null)) — a launched-and-identified reviewer that does not stay resident violates the boundary contract"
          fi ;;
        *)
          say "note: C7 mapping refused — native pid $C7NAT image is '$C7IMG' (basename '$c7base'), not the codex binary; no native operation performed"
          inc_c7=1 ;;
      esac
    else
      say "note: C7 direct-boundary attestation UNAVAILABLE — winpid mapping never appeared for job $C7JOB; refusing to touch any native pid"
      inc_c7=1
    fi
    # close the holder on EVERY path (idempotent); the chain unwinds itself
    exec 8>&-
    c7_job_gone() { ! kill -0 "$C7JOB" 2>/dev/null; }
    wait_for c7_job_gone \
      || flunk "C7 bridge chain still alive after EOF (job $C7JOB) — REPORTED, not killed; cleanup will wait out its bound"
  else
    rm -f "$T/hold"
    say "note: C7 skipped — no usable fifo for the stdin bridge on this machine"
    inc_c7=1
  fi
else
  say "note: C7 — no codex on PATH"
  inc_c7=1
fi
[ "$c7_attested" -eq 1 ] || inc_c7=1
untrack_dead

# ---- attestation re-verification: the bytes recorded are the bytes exercised.
#      This runs BEFORE quiescence — after quiescence the harness executes
#      nothing, so every verification that spawns the interpreter happens here.
[ "$(hash16 "$HERE/check-launcher.sh")" = "$H_SELF" ] || flunk "attestation: harness bytes changed during the run"
[ "$(hash16 "$LAUNCHER")" = "$H_LAUNCH" ]             || flunk "attestation: launcher bytes changed during the run"
[ "$(hash16 "$T/fakepayload.py")" = "$H_FAKE" ]       || flunk "attestation: fake-payload bytes changed during the run"
[ "$(hash16 "$T/bin/codex")" = "$H_SHIM" ]            || flunk "attestation: fake-shim bytes changed during the run"
[ "$(hash16 "$BASH")" = "$H_BASH" ]                   || flunk "attestation: bash bytes changed during the run"
[ "$(hash16 "$PY")" = "$H_PY" ]                       || flunk "attestation: python bytes changed during the run"
[ "$(hash16 "$NOHUP")" = "$H_NOHUP" ]                 || flunk "attestation: nohup bytes changed during the run"
if [ -n "$CODEX_BIN" ]; then
  [ "$(hash16 "$CODEX_BIN")" = "$H_CODEXBIN" ] || flunk "attestation: codex resolver binary bytes changed during the run"
fi
[ "$H_CODEX" = UNHASHABLE ] && flunk "attestation: exercised codex image unhashable"

# ---- quiescence: the FINAL process activity before the verdict ----------------
i=0; qlim=$(((HOLD + DEADLINE) * 5))
while [ $i -lt $qlim ]; do
  untrack_dead
  [ -s "$SHELLS" ] || [ -s "$PIDS" ] || break
  sleep 0.2; i=$((i+1))
done
untrack_dead
if [ -s "$SHELLS" ] || [ -s "$PIDS" ]; then
  q_alive=0
  if [ -s "$SHELLS" ]; then
    while IFS= read -r line; do
      sp=${line%%"$TAB"*}; rest=${line#*"$TAB"}
      snat=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
      simg=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
      sst=${rest%%"$TAB"*}
      [ -n "$sp" ] && [ "$(shell_state "$sp" "$snat" "$simg" "$sst")" = ALIVE ] && q_alive=1
    done < "$SHELLS"
  fi
  if [ -s "$PIDS" ]; then
    while IFS= read -r line; do
      p=${line%%"$TAB"*}; rest=${line#*"$TAB"}
      pimg=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
      pst=${rest%%"$TAB"*}
      [ -n "$p" ] && [ "$(native_rec_state "$p" "$pimg" "$pst")" = ALIVE ] && q_alive=1
    done < "$PIDS"
  fi
  if [ "$q_alive" -eq 1 ]; then
    flunk "QUIESCENCE: a tracked process is still alive past its construction bound — the expiry law did not hold on this run"
  else
    inc_other=1
    say "QUIESCENCE INCOMPLETE: a tracked process is unqueryable (QUERYFAIL is not dead) — the run cannot attest its own quiet exit"
  fi
  inventory
else
  pass "QUIESCENCE: every tracked process died by itself within its construction bound"
fi

# ---- final cleanup INSIDE the measured window, then disarm the traps: the
#      report and the exit spawn nothing and trigger no trap-time work
if [ -s "$SHELLS" ] || [ -s "$PIDS" ]; then
  say "workdir left in place with its deny stub (survivors named above): $T"
else
  rm -rf "$T" || { say "CLEANUP: workdir removal failed — left in place: $T"; inc_other=1; }
fi
trap - EXIT INT TERM HUP

# ---- attestation report: pure printing of precomputed strings — nothing
#      executes after quiescence (version identity IS the content hash)
say "----- ATTESTATION (record is keyed to ALL of these; hashes taken BEFORE the run, re-verified at the pre-quiescence boundary — the disclosed attestation limit) -----"
say "bash: $BASH_VERSION at $BASH ($H_BASH)"
say "uname: $UNAME_STR"
say "python: $PY_VER at $PY ($H_PY)"
say "nohup: $NOHUP ($H_NOHUP)"
say "harness: $H_SELF   fake-payload: $H_FAKE   fake-shim: $H_SHIM"
say "launcher: $H_LAUNCH"
[ -n "$CODEX_BIN" ] && say "codex resolver: $CODEX_BIN ($H_CODEXBIN — executed only as the C7 boundary subject, never for version probing; the hash is the version identity)"
say "codex observed image (C7): ${C7IMG:-none} ($H_CODEX)"
say "signal law: 3 signal sites total (C4 operator kill, C5 control HUP, C5 subject HUP); kill -0 probes only; zero cleanup/escalation kills"
say "----------------------------------------------------------"
if [ "$fail" -ne 0 ]; then
  say "check-launcher: CONTRACT VIOLATIONS above"; exit 1
fi
if [ "$inc_other" -ne 0 ]; then
  say "check-launcher: contract INCOMPLETE — a clause was refused unexercised (not a codex-availability skip; no downgrade)"
  exit 2
fi
if [ "$inc_c7" -ne 0 ]; then
  say "check-launcher: contract INCOMPLETE — direct native boundary (C7) unattested on this machine"
  [ "${CHECK_LAUNCHER_ALLOW_NO_CODEX:-0}" = 1 ] && exit 0 || exit 2
fi
say "check-launcher: contract HOLDS on this machine"
exit 0
