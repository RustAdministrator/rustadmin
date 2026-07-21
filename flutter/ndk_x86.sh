#!/usr/bin/env bash
set -euo pipefail

#
# Fix OpenSSL build with Android NDK clang on 32-bit architectures
#

export CFLAGS="-DBROKEN_CLANG_ATOMICS"
export CXXFLAGS="-DBROKEN_CLANG_ATOMICS"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/android_common.sh" i686-linux-android x86 flutter
