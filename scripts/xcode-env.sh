#!/usr/bin/env bash
#
# Shared Xcode command wrapper.
#
# The local shell may have Conda's cross-toolchain variables exported
# (LD/LIPO/CC/SDKROOT/etc.). Xcode inherits those and can accidentally invoke
# Conda tools instead of Apple's toolchain. Run Xcode-related commands through
# these helpers so builds/tests start from a small, predictable environment.

set -euo pipefail

MAM_DEVELOPER_DIR="${MAM_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MAM_XCODE_PATH="/usr/bin:/bin:/usr/sbin:/sbin:${MAM_DEVELOPER_DIR}/usr/bin"

mam_clean_env() {
  /usr/bin/env -i \
    HOME="${HOME:-}" \
    USER="${USER:-}" \
    LOGNAME="${LOGNAME:-${USER:-}}" \
    SHELL="${SHELL:-/bin/zsh}" \
    TMPDIR="${MAM_TMPDIR:-/private/tmp}" \
    PATH="$MAM_XCODE_PATH" \
    DEVELOPER_DIR="$MAM_DEVELOPER_DIR" \
    "$@"
}

mam_xcodebuild() {
  mam_clean_env xcodebuild "$@"
}

mam_xcrun() {
  mam_clean_env xcrun "$@"
}
