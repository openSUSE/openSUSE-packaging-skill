#!/bin/bash
# Assert a .changes edit is INSERTION-ONLY: every already-committed entry must
# survive byte-for-byte. A new entry is prepended at the top; nothing below it
# may change. This is the mechanical enforcement of the hard rule "inserting a
# new .changes entry must leave every existing entry byte-for-byte intact"
# (real breach: a fan-out agent folded a standalone prior entry into its new
# one, deleting that entry's separator+date header — factory-auto passes it,
# but it silently rewrites history and misdates past work).
#
# It is the integrity companion to changes-lint.sh (which checks *format* of
# the newest entries). Run BOTH at every commit gate, alongside source_validator.
#
# Check: the committed baseline must be an exact byte-suffix of the working
# file. That holds iff all new bytes are prepended above the old content —
# a deletion or a mid-file insertion shifts the suffix and trips it.
#
# Usage: changes-guard.sh [--base FILE] [--amend-top AUTHOR] <pkg>.changes [...]
#   --base FILE  compare against FILE instead of the auto-detected baseline
#                (useful outside a checkout, or to diff two arbitrary versions)
#   --amend-top AUTHOR
#                Also allow the TOPMOST committed entry to be amended — grown,
#                reworded, or rewritten, date refreshed — provided BOTH the
#                committed top entry and its replacement carry AUTHOR (e.g.
#                'Jane Packager') in the header. Use this only for an update
#                already committed to the devel project but NOT yet accepted
#                into openSUSE:Factory: that entry describes an unreleased
#                revision, so it is a draft, not history, and keeping ONE
#                coherent entry per submission beats stacking fixup bullets.
#                Everything BELOW the top entry is still required to be
#                byte-for-byte identical, and a foreign top entry is still
#                refused. Once the SR is accepted, stop using it — the entry
#                became history; write a new one.
#   Baseline auto-detection order: .osc/sources/<name> (classic osc checkout),
#   .osc/<name> (older osc), then `git show HEAD:<name>` (scmsync/git package).
#   A package with no prior committed .changes (new package) passes trivially.
#
# The one sanctioned exception — adding a boo#/CVE ref to an OLD entry — is a
# deliberate human edit and is expected to fail this guard; do it consciously,
# do not wire an override into the automated flow.
#
#   Exit: 0 = insertion-only (or an allowed --amend-top edit, or new file),
#         1 = a prior entry was modified, 2 = usage error.
set -euo pipefail

base_override=""
amend_author=""
while :; do
  case "${1:-}" in
    -h|--help|"") sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    --base) base_override=$2; shift 2 ;;
    --amend-top) amend_author=$2; shift 2 ;;
    *) break ;;
  esac
done

find_base() {                      # $1 = working .changes path; echoes baseline to stdout
  local work=$1 dir bn
  if [ -n "$base_override" ]; then
    [ -r "$base_override" ] && cat -- "$base_override"
    return
  fi
  dir=$(dirname -- "$work"); bn=$(basename -- "$work")
  if [ -r "$dir/.osc/sources/$bn" ]; then
    cat -- "$dir/.osc/sources/$bn"
  elif [ -r "$dir/.osc/$bn" ]; then
    cat -- "$dir/.osc/$bn"
  elif git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$dir" show "HEAD:./$bn" 2>/dev/null || true
  fi
}

SEP='^-------------------------------------------------------------------$'

# Byte offset just past the FIRST entry (separator + header + body) of a file,
# i.e. the start of the second separator line. Echoes nothing if there is no
# second separator (single-entry file).
rest_from_second_entry() {         # $1 = file
  awk -v sep="$SEP" 'NR>1 && $0 ~ sep {found=1} found' "$1"
}
first_entry_header() {             # $1 = file -> the header (date - author) line
  awk 'NR==2 {print; exit}' "$1"
}
first_entry_body() {               # $1 = file -> body lines of entry 1 (after header)
  awk -v sep="$SEP" 'NR>2 { if ($0 ~ sep) exit; print }' "$1"
}

# True iff: (a) everything from the baseline's SECOND entry onward is byte-identical
# in the working file, (b) BOTH top-entry headers name $3 (the caller's own
# author — the entry being replaced must be the caller's, and so must its
# replacement), and (c) the working top entry is non-empty. The top entry's
# body may be freely reworded, shrunk, or grown: it describes an update that
# has not been accepted into openSUSE:Factory yet, so its text is not history —
# it is a draft. The date on the header may also be refreshed. Everything that
# IS history (the second entry down) stays byte-protected.
amend_top_ok() {                   # $1 = work, $2 = base, $3 = author substring
  local work=$1 base=$2 author=$3 wh bh
  wh=$(first_entry_header "$work"); bh=$(first_entry_header "$base")
  [ -n "$bh" ] && [ -n "$wh" ] || return 1
  case "$bh" in *"$author"*) ;; *) return 1 ;; esac   # replaced entry is the caller's
  case "$wh" in *"$author"*) ;; *) return 1 ;; esac   # and so is the replacement
  [ -n "$(first_entry_body "$work" | grep -v '^[[:space:]]*$' || true)" ] || return 1
  diff -q <(rest_from_second_entry "$base") <(rest_from_second_entry "$work") \
       >/dev/null 2>&1
}

rc=0
for work in "$@"; do
  [ -r "$work" ] || { echo "$work: unreadable" >&2; rc=1; continue; }
  base=$(mktemp); find_base "$work" > "$base"
  if [ ! -s "$base" ]; then
    echo "$work: OK — no prior committed .changes to protect (new file)"
    rm -f "$base"; continue
  fi
  bsize=$(wc -c < "$base")
  # The last $bsize bytes of the working file must equal the baseline verbatim.
  if tail -c "$bsize" -- "$work" | cmp -s - "$base"; then
    echo "$work: OK — all pre-existing entries byte-for-byte intact (insertion-only)"
  elif [ -n "$amend_author" ] && amend_top_ok "$work" "$base" "$amend_author"; then
    echo "$work: OK — everything below the top entry is intact; the top entry is" \
         "yours (--amend-top: amendable while the update is not yet accepted)"
  else
    echo "$work: ERROR — the committed .changes is not an exact suffix of the new file;" >&2
    echo "  a previously-committed entry was modified, reordered, or deleted." >&2
    echo "  Only a NEW entry prepended at the top is allowed. Baseline -> working diff:" >&2
    diff -u "$base" "$work" | sed -n '1,60p' | sed 's/^/  /' >&2 || true
    rc=1
  fi
  rm -f "$base"
done
exit $rc
