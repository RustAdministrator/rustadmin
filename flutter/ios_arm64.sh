#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/ios_common.sh" ios-device-arm64 flutter/ios_arm64.sh aarch64-apple-ios arm64 2 "iOS device"
