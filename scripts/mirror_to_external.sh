#!/bin/bash
# Mirror this repo's tracked files to the public repo, as one new commit summarizing what
# changed -- not a `git push --mirror`. This repo (data-citations-pipeline, formerly
# ds-make-data-count-pipeline-public) keeps the full internal build history; the external repo
# is the clean public face and should never see that history, only the resulting file state.
#
# Why a script and not a manual copy-commit-push each time: the same two steps (denylist check,
# then sync) must happen identically every release, and skipping the check once is the failure
# mode this guards against.
#
# Usage:  scripts/mirror_to_external.sh [commit message]
#         DENYLIST_FILE=~/path/to/denylist.txt scripts/mirror_to_external.sh
#         EXTERNAL_REMOTE=git@github.com:org/other-repo.git scripts/mirror_to_external.sh
set -euo pipefail
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

DENYLIST_FILE="${DENYLIST_FILE:?set DENYLIST_FILE to your private denylist path}"
EXTERNAL_REMOTE="${EXTERNAL_REMOTE:-git@github.com:digital-science/ds-make-data-count-pipeline-external.git}"
MSG="${1:-Sync from internal repo ($(git rev-parse --short HEAD))}"

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree has uncommitted changes -- commit or stash first" >&2
  exit 1
fi

BUILD_DIR="$(mktemp -d)"
EXTERNAL_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$EXTERNAL_DIR"' EXIT

# Export exactly what's tracked here -- respects .gitignore, so tables.yaml and friends never
# reach the build dir in the first place.
git ls-files -z | rsync -a --files-from=- --from0 ./ "$BUILD_DIR/"

echo "checking the export for denylisted internal identifiers..."
( cd "$BUILD_DIR" && DENYLIST_FILE="$DENYLIST_FILE" bash scripts/check_no_internal_refs.sh )
echo "clean."

git clone --quiet "$EXTERNAL_REMOTE" "$EXTERNAL_DIR"
rsync -a --delete --exclude='.git' "$BUILD_DIR/" "$EXTERNAL_DIR/"

cd "$EXTERNAL_DIR"
git add -A
if git diff --cached --quiet; then
  echo "no changes to mirror."
  exit 0
fi
git commit -q -m "$MSG"
git push -q origin HEAD
echo "mirrored: $(git log -1 --oneline)"
