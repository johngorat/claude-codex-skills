#!/usr/bin/env bash
# Tree portability guard.
#
# Verifies invariants that keep the skills runnable on every platform:
#   1. No *.sh contains a CR byte — in the HEAD blob (what a clean checkout
#      materializes under .gitattributes), in the INDEX blob (what the next
#      commit will contain), NOR in this worktree (what a copy-install copies).
#   2. Every tracked *.sh has the executable bit IN THE GIT INDEX (100755).
#      The index is the source of truth: Windows filesystems have no exec bit,
#      so `test -x` proves nothing there.
#   3. No tracked symlinks (mode 120000) — in the INDEX and in HEAD: they
#      become broken text placeholders in core.symlinks=false checkouts and
#      in every exported archive (archives are cut from HEAD).
#
# Usage:
#   bash tests/check-tree.sh            # check this checkout
#   bash tests/check-tree.sh <dir>      # check an INSTALLED skill directory
#                                       # (byte scan; follows symlinks)
#
# Exit 0 = clean. Exit 1 = violation or incomplete scan (each with a remedy).
# Bash 3.2 compatible; no GNU-only flags.
set -u

fail=0
say() { printf '%s\n' "$*"; }

has_cr() { # stdin: file content. Returns 0 if a CR byte is present.
  ! tr -d '\r' | cmp -s - "$1"
}

if [ $# -ge 1 ]; then
  # Installed-copy mode: no git metadata — scan bytes. -L follows symlinks
  # (a symlink install must have its TARGETS scanned, not skipped).
  dir=$1
  [ -d "$dir" ] || { say "ERROR: not a directory: $dir"; exit 1; }
  list=$(mktemp) || exit 1
  if ! find -L "$dir" -name '*.sh' -type f > "$list" 2> "$list.err"; then
    say "ERROR: scan of $dir is INCOMPLETE (unreadable entries below) — a clean result cannot be claimed:"
    sed 's/^/  /' "$list.err"
    rm -f "$list" "$list.err"; exit 1
  fi
  n=0
  while IFS= read -r f; do
    n=$((n + 1))
    if tr -d '\r' < "$f" | cmp -s - "$f"; then :; else
      say "CRLF in installed script: $f"
      say "  remedy: re-install from a checkout that has the .gitattributes fix"
      fail=1
    fi
  done < "$list"
  rm -f "$list" "$list.err"
  say "scanned $n script(s) under $dir"
  [ "$fail" -eq 0 ] && say "OK: installed scripts are CR-free"
  exit "$fail"
fi

# Checkout mode — must run inside the repo, and git enumeration itself must
# WORK: an ls-files failure yielding an empty list would let every check
# below pass vacuously and certify a tree nobody actually scanned.
# Enumeration is anchored at the repo TOP LEVEL: run from a subdirectory,
# git ls-files/ls-tree list only that subdirectory, and a "repo-wide" guard
# that scanned tests/ alone would still print OK.
top=$(git rev-parse --show-toplevel 2>/dev/null) || { say "ERROR: not a git checkout"; exit 1; }
cd "$top" || { say "ERROR: cannot enter the repo top level $top"; exit 1; }
git ls-files -s >/dev/null || { say "ERROR: git ls-files failed — the tree cannot be certified; remedy: repair the checkout or its index"; exit 1; }

# Every enumeration and every cat-file below is STATUS-CHECKED into a temp
# file: a missing/unreadable blob makes `git cat-file` emit an EMPTY stream,
# and a naive pipeline compare of empty-vs-empty would certify a tree nobody
# actually read. An unreadable blob is a hard stop, not a skipped file.
blob=$(mktemp) || exit 1

# 1a. CR bytes in the COMMITTED tree (HEAD). Skipped only on an unborn branch.
if git rev-parse --verify -q HEAD >/dev/null; then
  head_list=$(git ls-tree -r HEAD --name-only) || {
    say "ERROR: git ls-tree HEAD failed — the tree cannot be certified; remedy: repair the repository (git fsck)"
    rm -f "$blob"; exit 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case $f in *.sh) ;; *) continue ;; esac
    if ! git cat-file blob "HEAD:$f" > "$blob" 2>/dev/null; then
      say "ERROR: cannot read HEAD blob $f — the tree cannot be certified; remedy: repair the repository (git fsck)"
      rm -f "$blob"; exit 1
    fi
    if tr -d '\r' < "$blob" | cmp -s - "$blob"; then :; else
      say "CR byte in COMMITTED blob (HEAD): $f"
      say "  remedy: strip CR (tr -d '\r'), git add --renormalize, commit"
      fail=1
    fi
  done <<HEADLIST
$head_list
HEADLIST
else
  say "note: unborn HEAD — committed-tree check skipped"
fi

# 1b + 1c share one status-checked enumeration of the index.
idx_list=$(git ls-files '*.sh') || {
  say "ERROR: git ls-files failed — the tree cannot be certified; remedy: repair the checkout or its index"
  rm -f "$blob"; exit 1; }

# 1b. CR bytes in the INDEX (what the next commit would contain).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! git cat-file blob ":$f" > "$blob" 2>/dev/null; then
    say "ERROR: cannot read INDEX blob $f — the tree cannot be certified; remedy: repair the checkout or its index (git fsck)"
    rm -f "$blob"; exit 1
  fi
  if tr -d '\r' < "$blob" | cmp -s - "$blob"; then :; else
    say "CR byte in INDEX blob: $f"
    say "  remedy: strip CR in the worktree, then git add --renormalize $f"
    fail=1
  fi
done <<IDXLIST1
$idx_list
IDXLIST1

# 1c. CR bytes in the worktree (a copy-install copies THESE bytes).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  if tr -d '\r' < "$f" | cmp -s - "$f"; then :; else
    say "CR byte in worktree file: $f"
    say "  remedy: git rm --cached -r . && git reset --hard  (re-materialize under .gitattributes)"
    fail=1
  fi
done <<IDXLIST2
$idx_list
IDXLIST2
rm -f "$blob"

# 2. Executable bit in the git index.
modes=$(git ls-files -s '*.sh') || { say "ERROR: git ls-files failed mid-run — remedy: repair the checkout or its index"; exit 1; }
while IFS= read -r line; do
  [ -n "$line" ] || continue
  mode=${line%% *}
  file=${line#*	}
  if [ "$mode" != "100755" ]; then
    say "missing exec bit in index ($mode): $file"
    say "  remedy: git update-index --chmod=+x $file"
    fail=1
  fi
done <<EOF2
$modes
EOF2

# 3. No tracked symlinks AT ALL — in the INDEX and in HEAD. A mode-120000
# entry becomes a TEXT PLACEHOLDER in any core.symlinks=false checkout and
# in every exported archive; archives are cut from HEAD, so an index-only
# check would print OK while a committed symlink (staged over with a
# regular file) still ships in every export. Forbidding the class in both
# places extinguishes it at the source.
allmodes=$(git ls-files -s) || { say "ERROR: git ls-files failed mid-run — remedy: repair the checkout or its index"; exit 1; }
while IFS= read -r line; do
  [ -n "$line" ] || continue
  mode=${line%% *}
  file=${line#*	}
  if [ "$mode" = "120000" ]; then
    say "tracked symlink (mode 120000): $file"
    say "  remedy: replace the link with a real file — exported archives and core.symlinks=false checkouts turn tracked links into broken text placeholders"
    fail=1
  fi
done <<EOF3
$allmodes
EOF3

if git rev-parse --verify -q HEAD >/dev/null; then
  headmodes=$(git ls-tree -r HEAD) || { say "ERROR: git ls-tree HEAD failed — the tree cannot be certified; remedy: repair the repository (git fsck)"; exit 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mode=${line%% *}
    file=${line#*	}
    if [ "$mode" = "120000" ]; then
      say "tracked symlink in HEAD (mode 120000): $file"
      say "  remedy: replace the link with a real file and COMMIT — archives are cut from HEAD, so a staged replacement alone still ships the placeholder"
      fail=1
    fi
  done <<EOF4
$headmodes
EOF4
fi

[ "$fail" -eq 0 ] && say "OK: tree is portable (LF scripts in HEAD/index/worktree, exec bits in index)"
exit "$fail"
