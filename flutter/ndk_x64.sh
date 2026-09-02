#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/android_common.sh" android-x86_64 flutter/ndk_x64.sh x86_64-linux-android x86_64 flutter
