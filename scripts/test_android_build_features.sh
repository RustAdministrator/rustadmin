#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_BUILD="${REPO_DIR}/flutter/android_common.sh"

validate() {
  RUSTADMIN_ANDROID_VALIDATE_FEATURES_ONLY=1 \
    bash "${ANDROID_BUILD}" aarch64-linux-android arm64-v8a "$1"
}

validate "flutter"
validate "flutter,hwcodec,mediacodec"

if validate "flutter,hwcodec" >/dev/null 2>&1; then
  echo "error: Android hwcodec validation accepted a build without mediacodec." >&2
  exit 1
fi

echo "Android build feature validation passed."
