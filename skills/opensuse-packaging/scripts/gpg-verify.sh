#!/bin/bash
# Verify a signed source tarball against a package keyring.
# Avoids the gpgv trap: gpgv --keyring FAILS on an ASCII-armored keyring
# ("invalid packet (ctb=2d)"), so import into a throwaway homedir and gpg --verify.
#
# Usage: gpg-verify.sh <tarball> <keyring> [signature]
#   signature defaults to <tarball>.asc, then <tarball>.sig
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,7p' "$0"; exit 0;;
esac
[ $# -ge 2 ] || { sed -n '2,7p' "$0"; exit 2; }
tarball="$1" ; keyring="$2"
sig="${3:-}"
if [ -z "$sig" ]; then
  for c in "$tarball.asc" "$tarball.sig"; do [ -f "$c" ] && { sig="$c"; break; }; done
fi
[ -f "$sig" ] || { echo "no signature found for $tarball" >&2; exit 2; }

export GNUPGHOME="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME"' EXIT
if ! imp=$(gpg --import "$keyring" 2>&1); then
  echo "keyring import FAILED (corrupt/empty keyring '$keyring'?):" >&2
  echo "$imp" >&2
  exit 2
fi
# `gpg --import` exits 0 on a file holding no key at all (e.g. a detached
# .sig passed where the keyring was meant — the args are easy to transpose).
# Without this check the run reaches the verify with an EMPTY keyring and
# reports "BAD or UNVERIFIABLE signature ... upstream may have rotated keys",
# which is a false alarm on a perfectly good tarball. Fail loudly instead.
if ! gpg --list-keys --with-colons 2>/dev/null | grep -q '^pub:'; then
  echo "'$keyring' contains no OpenPGP public key — is it really a keyring?" >&2
  echo "usage: gpg-verify.sh <tarball> <keyring> [signature]" >&2
  echo "$imp" >&2
  exit 2
fi

# Run the verify ONCE and grep the captured output (also avoids the
# pipefail + `grep -q` SIGPIPE flake in an if-condition).
out=$(gpg --verify "$sig" "$tarball" 2>&1) || true
if grep -q "Good signature" <<<"$out"; then
  grep -iE "Good signature|using" <<<"$out"
  echo "OK"
else
  echo "BAD or UNVERIFIABLE signature — upstream may have rotated keys; update the keyring." >&2
  tail -3 <<<"$out" >&2
  exit 1
fi
