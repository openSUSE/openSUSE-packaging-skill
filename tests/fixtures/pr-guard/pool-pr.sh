#!/bin/bash
# Stand-in for the canonical pool-pr.sh: it writes to pool pulls, so the guard
# refuses it unless it is the skill checkout's unmodified, committed copy.
set -u
curl -sS -X POST "https://src.opensuse.org/api/v1/repos/pool/$(basename "$1")/pulls" \
  -H "Content-Type: application/json" --data @-
