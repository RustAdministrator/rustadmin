#!/usr/bin/env bash
set -euo pipefail

# Builds the iOS simulator Flutter app after producing the matching Rust static
# library. The default package cache is intentionally separate from macOS and
# iOS device builds because Flutter rewrites package/build state per target.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ios_flutter_common.sh"

prepare_ios_flutter_build "${RUSTADMIN_IOS_SIMULATOR_PUB_CACHE:-${HOME}/.pub-cache-rustadmin-ios-simulator}"

SIMULATOR_ARCH="${RUSTADMIN_IOS_SIMULATOR_ARCH:-arm64}"
case "${SIMULATOR_ARCH}" in
  arm64)
    bash "${SCRIPT_DIR}/ios_sim_arm64.sh"
    ;;
  x86_64)
    bash "${SCRIPT_DIR}/ios_x64.sh"
    ;;
  *)
    echo "error: unsupported RUSTADMIN_IOS_SIMULATOR_ARCH=${SIMULATOR_ARCH}" >&2
    echo "       Supported values: arm64, x86_64" >&2
    exit 1
    ;;
esac

cd "${SCRIPT_DIR}"
flutter build ios --simulator --debug --config-only
xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "${RUSTADMIN_IOS_SIMULATOR_DESTINATION:-generic/platform=iOS Simulator}" \
  ARCHS="${SIMULATOR_ARCH}" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
