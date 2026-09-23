#!/bin/bash
set -euo pipefail

# sync.sh: Fetch upstream kernel, apply CI files, force-push to linux/ repo.
# Usage: ./sync.sh /path/to/linux/clone
#
# This script synchronizes the linux/ repo with upstream (tip/objtool/core),
# applies CI files from this ci_files repo, and force-pushes the result.

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <path-to-linux-clone>"
    echo ""
    echo "Example: $0 ../linux"
    exit 1
fi

LINUX_DIR="$1"
if [[ ! -d "$LINUX_DIR/.git" ]]; then
    echo "Error: $LINUX_DIR is not a valid git repository"
    exit 1
fi

CI_FILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_ABS="$(cd "$LINUX_DIR" && pwd)"

echo "========================================"
echo "CI Files Sync Script"
echo "========================================"
echo "ci_files: $CI_FILES_DIR"
echo "linux:    $LINUX_ABS"
echo ""

# Get the current ci_files commit SHA for the commit message
CI_FILES_SHA=$(cd "$CI_FILES_DIR" && git rev-parse --short HEAD)

# Enter the linux repo
cd "$LINUX_ABS"

echo "Fetching upstream..."
git fetch tip objtool/core
UPSTREAM_SHA=$(git rev-parse tip/objtool/core)
echo "Upstream tip/objtool/core is at: $UPSTREAM_SHA"
echo ""

# Confirm intent before resetting
echo "About to reset main to upstream and apply CI files from $CI_FILES_SHA."
echo "This will force-push to origin. Continue? (yes/no)"
read -r confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Resetting main to upstream..."
git reset --hard tip/objtool/core

# Changes to the kernel itself cannot live in linux/: the reset above throws
# away anything that is not upstream.  Anything the CI needs from the tree --
# a test fix that has not landed yet, say -- is carried here as a patch and
# reapplied on each sync, and disappears from here once upstream has it.
#
# A patch that stops applying is the signal that this happened, or that
# upstream moved under it; either way it wants a person, so stop rather than
# push a tree with half of it applied.
shopt -s nullglob
patches=( "$CI_FILES_DIR"/patches/*.patch )
shopt -u nullglob

if (( ${#patches[@]} )); then
    echo "Applying ${#patches[@]} patch(es) from patches/..."
    if ! git am "${patches[@]}"; then
        git am --abort || true
        echo ""
        echo "Error: patches do not apply to $UPSTREAM_SHA."
        echo "Either upstream has moved, or upstream already carries the change"
        echo "-- in which case drop the patch from ci_files/patches/."
        exit 1
    fi
fi

echo "Copying CI files from ci_files..."
# Copy .github and ci directories, removing any that were deleted in ci_files
rsync -a --delete "$CI_FILES_DIR/.github" "$LINUX_ABS/"
if [[ -d "$CI_FILES_DIR/ci" ]]; then
    rsync -a --delete "$CI_FILES_DIR/ci" "$LINUX_ABS/"
fi

echo "Staging CI files for commit..."
git add -f .github
if [[ -d "$LINUX_ABS/ci" ]]; then
    git add ci
fi

echo "Creating commit..."
git commit -m "Add CI files from ci_files@$CI_FILES_SHA"

echo ""
echo "========================================"
echo "Commit created. Ready to force-push."
echo ""
git log --oneline -1
echo "Branch: $(git rev-parse --abbrev-ref HEAD)"
echo "Remote: origin ($(cd "$LINUX_ABS" && git remote get-url origin))"
echo ""
echo "About to force-push to origin/main. Continue? (yes/no)"
read -r confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted. Commit is local only."
    exit 0
fi

echo ""
echo "Force-pushing to origin..."
git push --force origin main
echo "✓ Force-push complete."
echo ""
echo "========================================"
