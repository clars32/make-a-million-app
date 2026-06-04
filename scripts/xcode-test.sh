#!/usr/bin/env bash
#
# Build/test Make-A-Million with a clean Xcode environment.
#
# Usage:
#   scripts/xcode-test.sh              # run tests on MAM-iPhone-1 if present
#   scripts/xcode-test.sh build        # compile generic iOS Simulator app
#   scripts/xcode-test.sh test --quiet # pass extra args through to xcodebuild
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
ACTION="${1:-test}"
if [[ $# -gt 0 ]]; then shift; fi

case "$ACTION" in
  test|build) ;;
  *)
    echo "usage: scripts/xcode-test.sh [test|build] [extra xcodebuild args...]" >&2
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
elif [[ "$ACTION" == "test" ]]; then
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

echo "==> $ACTION $SCHEME"
echo "==> destination: $DESTINATION"
echo "==> derived data: $DERIVED_DATA"

mam_xcodebuild "$ACTION" \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "$@"
