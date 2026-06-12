#!/usr/bin/env bash
#
# Build/test Make-A-Million with a clean Xcode environment.
#
# Usage:
#   scripts/xcode-test.sh              # quick verification: non-arena unit tests
#   scripts/xcode-test.sh quick        # same as default
#   scripts/xcode-test.sh build        # compile generic iOS Simulator app
#   scripts/xcode-test.sh smoke        # cheap AI arena smoke tests
#   scripts/xcode-test.sh arena        # all AI arena benchmarks/experiments
#   scripts/xcode-test.sh all          # every test target, including arena + UI
#   scripts/xcode-test.sh quick -quiet # pass extra args through to xcodebuild
#
# Overrides:
#   MAM_DESTINATION='id=<UDID>' scripts/xcode-test.sh
#   MAM_SIMULATOR_NAME='MAM-iPhone-2' scripts/xcode-test.sh
#   MAM_DERIVED_DATA=/tmp/MAMDerivedData scripts/xcode-test.sh build

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/xcode-env.sh
source "$PROJECT_DIR/scripts/xcode-env.sh"

cd "$PROJECT_DIR"

SCHEME="${MAM_SCHEME:-Make-A-Million}"
PROJECT="${MAM_PROJECT:-$SCHEME.xcodeproj}"
DERIVED_DATA="${MAM_DERIVED_DATA:-$PROJECT_DIR/.derivedData}"
MODE="${1:-quick}"
if [[ $# -gt 0 ]]; then shift; fi

XCODE_ACTION="test"
MODE_ARGS=()

case "$MODE" in
  build)
    XCODE_ACTION="build"
    ;;
  quick|test)
    # Everyday correctness/regression pass: skip statistical AI experiments
    # and UI tests. Use `all` when you truly want the whole suite.
    MODE_ARGS=(
      "-skip-testing:Make-A-MillionTests/AIArenaTests"
      "-skip-testing:Make-A-MillionUITests"
    )
    ;;
  smoke|ai-smoke)
    # Fast arena wiring sanity without the long self-play benchmarks.
    MODE_ARGS=(
      "-only-testing:Make-A-MillionTests/AIArenaTests/testTraceOneHand"
      "-only-testing:Make-A-MillionTests/AIArenaTests/testArenaSmall"
    )
    ;;
  arena|ai|bench|benchmark)
    # Statistical AI benchmark/instrument suite. This can take a long time.
    MODE_ARGS=(
      "-only-testing:Make-A-MillionTests/AIArenaTests"
    )
    ;;
  all|full)
    ;;
  *)
    cat >&2 <<'EOF'
usage: scripts/xcode-test.sh [quick|build|smoke|arena|all] [extra xcodebuild args...]

Modes:
  quick   default; non-arena unit tests, skips UI tests
  build   compile the app for a generic iOS Simulator
  smoke   cheap AI arena smoke tests only
  arena   all AI arena benchmarks/experiments; intentionally slow
  all     every test target, including arena + UI
EOF
    exit 64
    ;;
esac

find_sim_udid() {
  local preferred="${MAM_SIMULATOR_NAME:-MAM-iPhone-1}"

  # Prefer the stable simulator used by scripts/run-sims.sh.
  mam_xcrun simctl list devices available 2>/dev/null \
    | awk -v name="$preferred" '
        $0 ~ (" " name " \\(") {
          if (match($0, /[0-9A-Fa-f-]{36}/)) {
            print substr($0, RSTART, RLENGTH)
            exit
          }
        }'
}

fallback_sim_udid() {
  # Any available iPhone simulator is good enough for compile/test sanity.
  mam_xcrun simctl list devices available 2>/dev/null \
    | awk '
        / iPhone .* \(/ {
          if (match($0, /[0-9A-Fa-f-]{36}/)) {
            print substr($0, RSTART, RLENGTH)
            exit
          }
        }'
}

if [[ -n "${MAM_DESTINATION:-}" ]]; then
  DESTINATION="$MAM_DESTINATION"
elif [[ "$XCODE_ACTION" == "test" ]]; then
  UDID="$(find_sim_udid || true)"
  [[ -n "$UDID" ]] || UDID="$(fallback_sim_udid || true)"
  if [[ -z "$UDID" ]]; then
    cat >&2 <<'EOF'
error: no available iPhone simulator was found.

Try:
  scripts/run-sims.sh 1:iPhone
  xcrun simctl list devices available

Or pass an explicit destination:
  MAM_DESTINATION='id=<UDID>' scripts/xcode-test.sh
EOF
    exit 70
  fi
  DESTINATION="id=$UDID"
else
  DESTINATION="generic/platform=iOS Simulator"
fi

echo "==> $MODE $SCHEME"
echo "==> xcode action: $XCODE_ACTION"
echo "==> destination: $DESTINATION"
echo "==> derived data: $DERIVED_DATA"

# Serialize runs. Concurrent xcodebuild sessions against the same simulator
# tear each other's test runners down mid-run (each boots the device and
# shuts it down when it exits) — xcodebuild surfaces that as "Mach error
# -308 ... (ipc/mig) server died" / "Test crashed with signal term", which
# looks like a crashing test but is pure infrastructure (observed 2026-06-11
# when several test invocations overlapped on MAM-iPhone-1). Concurrent
# builds also race on the shared derived data, so the lock covers both
# actions. Fixed /tmp path (not $TMPDIR): sessions get distinct TMPDIRs,
# and the whole point is locking ACROSS sessions.
LOCK="/tmp/mam-xcode-test.$(id -u).lock"
waited=0
while ! mkdir "$LOCK" 2>/dev/null; do
  owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && ! kill -0 "$owner" >/dev/null 2>&1; then
    rm -rf "$LOCK"   # stale: owning process is gone
    continue
  fi
  if (( waited == 0 )); then
    echo "==> another xcode-test.sh run (pid ${owner:-?}) is active; waiting…"
  fi
  sleep 5
  waited=$(( waited + 5 ))
  if (( waited >= 1200 )); then
    echo "error: gave up waiting for $LOCK (held by pid ${owner:-?})." >&2
    echo "       If no other test run is really active: rm -rf '$LOCK'" >&2
    exit 75
  fi
done
echo "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

mam_xcodebuild "$XCODE_ACTION" \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  ${MODE_ARGS[@]+"${MODE_ARGS[@]}"} \
  "$@"
