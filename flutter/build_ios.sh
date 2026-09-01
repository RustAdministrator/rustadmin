#!/usr/bin/env bash
set -euo pipefail

# https://docs.flutter.dev/deployment/ios
# flutter build ipa --release --obfuscate --split-debug-info=./split-debug-info
# no obfuscate, because no easy to check errors

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
: "${RUSTDESK_IOS_CARGO_FEATURES:=flutter,hwcodec}"
python3 "${REPO_DIR}/scripts/platform_profiles.py" check \
  --profile ios-device-arm64 \
  --wrapper flutter/build_ios.sh \
  --target aarch64-apple-ios \
  --abi arm64 \
  --features "${RUSTDESK_IOS_CARGO_FEATURES}"
source "${SCRIPT_DIR}/ios_flutter_common.sh"

prepare_ios_flutter_build "${RUSTADMIN_IOS_DEVICE_PUB_CACHE:-${HOME}/.pub-cache-rustadmin-ios-device}"
bash "${SCRIPT_DIR}/ios_arm64.sh"
cd "${SCRIPT_DIR}"
flutter build ipa --release
