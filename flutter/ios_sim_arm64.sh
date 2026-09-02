#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/ios_common.sh" ios-simulator-arm64 flutter/ios_sim_arm64.sh aarch64-apple-ios-sim arm64 7 "iOS simulator"
