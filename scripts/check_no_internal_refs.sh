#!/bin/bash
# Fails if any denylisted internal identifier appears in the repo tree.
# The denylist is NOT part of this repo: point DENYLIST_FILE at a private file, e.g.
#   DENYLIST_FILE=~/.config/mdc/denylist.txt scripts/check_no_internal_refs.sh
# with one pattern per line (internal project ids, dataset names, hostnames).
set -euo pipefail
DENYLIST_FILE="${DENYLIST_FILE:?set DENYLIST_FILE to your private denylist path}"
FAIL=0
while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  if grep -rIn --exclude-dir=.git --exclude='tables.yaml' -e "$pattern" .; then
    echo "DENYLISTED REFERENCE FOUND: pattern '$pattern'" >&2
    FAIL=1
  fi
done < "$DENYLIST_FILE"
exit $FAIL
