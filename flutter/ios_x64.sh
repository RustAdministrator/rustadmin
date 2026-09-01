#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/ios_common.sh" ios-simulator-x86_64 flutter/ios_x64.sh x86_64-apple-ios x86_64 7 "iOS simulator"
