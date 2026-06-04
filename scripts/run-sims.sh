#!/usr/bin/env bash
#
# run-sims.sh — spin up a mix of iOS simulators, install Make-A-Million on
# each, and launch them. Lets you test multipeer (host + clients) on one Mac
# without extra physical devices. MultipeerConnectivity works simulator-to-
# simulator on the same machine (they talk over the shared network stack).
#
# Usage:
#   scripts/run-sims.sh [SPEC ...]
#     SPEC = COUNT:TYPE   e.g. 4:iPhone, 1:iPad   (TYPE is a simctl device-type
#                         filter; the newest match is used)
#          | TYPE         a single sim of that type   e.g. iPad
#          | COUNT        that many iPhones            e.g. 3
#     (no args) defaults to: 3:iPhone
#
#   scripts/run-sims.sh clean     # delete all MAM-* sims and exit
#
# Examples:
#   scripts/run-sims.sh                 # 3 iPhone sims
#   scripts/run-sims.sh 1:iPad 4:iPhone # 1 iPad + 4 iPhone sims
#
# Reuse / speed:
#   Sims are named MAM-<type>-<n> and are REUSED across runs. Leave them open
#   and a re-run just reinstalls + relaunches the app — no cold boot / Apple
#   logo wait. Use `clean` (or quit the simulators) when you want a fresh boot.
#
# Notes:
#   • Give each running app a DISTINCT player name — identical names collide
#     on the persisted MCPeerID.
#   • To watch a host's [NET] / [MPC-HOST] logs, run that one from Xcode, or:
#       xcrun simctl launch --console-pty <UDID> com.truebluedev.Make-A-Million

set -euo pipefail

SCHEME="Make-A-Million"
BUNDLE_ID="com.truebluedev.Make-A-Million"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

find_udid() {  # exact device name -> UDID (empty if none)
  xcrun simctl list devices \
    | awk -v n="$1" '$0 ~ ("(^| )" n " \\(") { if (match($0, /[0-9A-Fa-f-]{36}/)) { print substr($0, RSTART, RLENGTH); exit } }'
}

# `clean` subcommand: remove every MAM-* sim and exit.
if [[ "${1:-}" == "clean" ]]; then
  echo "==> Deleting MAM-* simulators…"
  for udid in $(xcrun simctl list devices \
    | awk '/ MAM-[A-Za-z0-9]+-[0-9]+ \(/ { if (match($0, /[0-9A-Fa-f-]{36}/)) print substr($0, RSTART, RLENGTH) }'); do
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  done
  echo "Done."
  exit 0
fi

# Specs: default to three iPhones.
SPECS=("$@")
[[ ${#SPECS[@]} -eq 0 ]] && SPECS=("3:iPhone")

echo "==> Building $SCHEME for the simulator…"
xcodebuild build -project "$SCHEME.xcodeproj" -scheme "$SCHEME" \
  -destination 'generic/platform=iOS Simulator' -configuration Debug -quiet

APP="$(xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')"
[[ -d "$APP" ]] || { echo "error: built .app not found at: $APP" >&2; exit 1; }
echo "==> App: $APP"

# Newest available iOS runtime.
RT_ID="$(xcrun simctl list runtimes | grep -E '^iOS ' | grep -vi unavailable \
  | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS[-0-9]+' | tail -1)"
[[ -n "$RT_ID" ]] || { echo "error: no available iOS runtime (install one in Xcode ▸ Settings ▸ Components)" >&2; exit 1; }
echo "==> Runtime: $RT_ID"

# Newest device type matching a filter. simctl lists newest-first, legacy last.
resolve_device_type() {
  xcrun simctl list devicetypes | grep -iE "$1" \
    | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9-]+' | head -1
}

open -a Simulator

# Per-type counters so names are stable across runs (sims get reused & stay
# booted instead of cold-booting every time). bash-3.2-safe (no assoc arrays).
seen_types=()
seen_counts=()
IDX=0
# Sets IDX to the next 1-based index for the given type token. Must be called
# as a statement (not via $(...)) so its array mutations persist — command
# substitution would run it in a subshell and lose the counters.
next_index() {
  local tok="$1" i
  for i in "${!seen_types[@]}"; do
    if [[ "${seen_types[$i]}" == "$tok" ]]; then
      seen_counts[$i]=$(( ${seen_counts[$i]} + 1 )); IDX="${seen_counts[$i]}"; return
    fi
  done
  seen_types+=("$tok"); seen_counts+=("1"); IDX=1
}

declare -a UDIDS=()
for spec in "${SPECS[@]}"; do
  # Parse COUNT:TYPE | TYPE | COUNT
  if [[ "$spec" == *:* ]]; then
    COUNT="${spec%%:*}"; FILTER="${spec#*:}"
  elif [[ "$spec" =~ ^[0-9]+$ ]]; then
    COUNT="$spec"; FILTER="iPhone"
  else
    COUNT=1; FILTER="$spec"
  fi
  [[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -ge 1 ]] || { echo "error: bad count in spec '$spec'" >&2; exit 1; }

  DT_ID="$(resolve_device_type "$FILTER")"
  [[ -n "$DT_ID" ]] || { echo "error: no device type matching '$FILTER'." >&2; xcrun simctl list devicetypes >&2; exit 1; }
  TOKEN="$(printf '%s' "$FILTER" | tr -cd '[:alnum:]')"
  echo "==> $COUNT × $FILTER  ($DT_ID)"

  for ((k = 1; k <= COUNT; k++)); do
    next_index "$TOKEN"
    NAME="MAM-${TOKEN}-${IDX}"
    UDID="$(find_udid "$NAME")"
    if [[ -z "$UDID" ]]; then
      UDID="$(xcrun simctl create "$NAME" "$DT_ID" "$RT_ID")"
      echo "    created $NAME"
    fi
    xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true   # boots only if not already booted
    xcrun simctl install "$UDID" "$APP"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
    echo "    $NAME ($UDID) ready"
    UDIDS+=("$UDID")
  done
done

echo
echo "Running ${#UDIDS[@]} simulators. In each app, choose a DISTINCT player name."
echo "Leave them open — a re-run skips the boot and just reinstalls the app."
echo "Fresh start: scripts/run-sims.sh clean   (or quit the simulators)"
echo "Host logs:   xcrun simctl launch --console-pty <UDID> $BUNDLE_ID"
echo "UDIDs: ${UDIDS[*]}"
