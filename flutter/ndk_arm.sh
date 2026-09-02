#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/android_common.sh" android-armv7 flutter/ndk_arm.sh armv7-linux-androideabi armeabi-v7a flutter,hwcodec,mediacodec
