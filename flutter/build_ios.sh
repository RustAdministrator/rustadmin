#!/usr/bin/env bash
set -euo pipefail

# https://docs.flutter.dev/deployment/ios
# flutter build ipa --release --obfuscate --split-debug-info=./split-debug-info
# no obfuscate, because no easy to check errors

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ios_flutter_common.sh"

prepare_ios_flutter_build "${RUSTADMIN_IOS_DEVICE_PUB_CACHE:-${HOME}/.pub-cache-rustadmin-ios-device}"
bash "${SCRIPT_DIR}/ios_arm64.sh"
cd "${SCRIPT_DIR}"
flutter build ipa --release
