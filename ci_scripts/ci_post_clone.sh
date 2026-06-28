#!/bin/sh
#
# Xcode Cloud post-clone hook.
#
# Sets a deterministic, monotonic build number (CFBundleVersion) from the git
# commit count, so every TestFlight / App Store upload increases on its own —
# no manual bumping, and the same number you'd get building locally.
#
# Xcode Cloud runs this automatically after cloning, before the build. The
# committed CURRENT_PROJECT_VERSION in the project is only a baseline for local
# builds; this script overrides it with the exact commit count for the build
# that actually ships.
#
# Requires VERSIONING_SYSTEM = apple-generic on the app target (set in the
# project) so `agvtool` can write CURRENT_PROJECT_VERSION across configs.
#
set -e

REPO="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO"

# Xcode Cloud may perform a shallow clone; a full history is needed for an
# accurate commit count. Unshallow when necessary (no-op if already complete).
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  git fetch --unshallow --quiet || git fetch --depth=100000 --quiet || true
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "ci_post_clone: setting build number to ${BUILD_NUMBER} (git commit count)"

xcrun agvtool new-version -all "${BUILD_NUMBER}"
