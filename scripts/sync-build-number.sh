#!/usr/bin/env bash
#
# Sync the committed build number (CURRENT_PROJECT_VERSION) to the git commit
# count, the same value Xcode Cloud's ci_post_clone.sh will ship.
#
# Run this before tagging a release if you want local builds and the committed
# project to match what CI uploads. It's optional — CI sets the real number on
# its own — but it keeps the repo's baseline honest.
#
# Usage: scripts/sync-build-number.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="$(git rev-list --count HEAD)"
xcrun agvtool new-version -all "$BUILD_NUMBER" >/dev/null
echo "Build number (CURRENT_PROJECT_VERSION) set to ${BUILD_NUMBER}."
echo "Commit this change so local builds match CI."
