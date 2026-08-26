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

# Checkout mode — must run inside the repo.
git rev-parse --show-toplevel >/dev/null 2>&1 || { say "ERROR: not a git checkout"; exit 1; }

# 1a. CR bytes in the COMMITTED tree (HEAD). Skipped only on an unborn branch.
if git rev-parse --verify -q HEAD >/dev/null; then
  for f in $(git ls-tree -r HEAD --name-only | grep '\.sh$'); do
    if git cat-file blob "HEAD:$f" | tr -d '\r' | cmp -s - <(git cat-file blob "HEAD:$f"); then :; else
      say "CR byte in COMMITTED blob (HEAD): $f"
      say "  remedy: strip CR (tr -d '\r'), git add --renormalize, commit"
      fail=1
    fi
  done
else
  say "note: unborn HEAD — committed-tree check skipped"
fi

# 1b. CR bytes in the INDEX (what the next commit would contain).
for f in $(git ls-files '*.sh'); do
  if git cat-file blob ":$f" | tr -d '\r' | cmp -s - <(git cat-file blob ":$f"); then :; else
    say "CR byte in INDEX blob: $f"
    say "  remedy: strip CR in the worktree, then git add --renormalize $f"
    fail=1
  fi
done

# 1c. CR bytes in the worktree (a copy-install copies THESE bytes).
for f in $(git ls-files '*.sh'); do
  [ -f "$f" ] || continue
  if tr -d '\r' < "$f" | cmp -s - "$f"; then :; else
    say "CR byte in worktree file: $f"
    say "  remedy: git rm --cached -r . && git reset --hard  (re-materialize under .gitattributes)"
    fail=1
  fi
done

# 2. Executable bit in the git index.
modes=$(git ls-files -s '*.sh')
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

[ "$fail" -eq 0 ] && say "OK: tree is portable (LF scripts in HEAD/index/worktree, exec bits in index)"
exit "$fail"
