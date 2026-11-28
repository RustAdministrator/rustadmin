#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-release}"
case "${MODE}" in
  debug|profile|release) ;;
  *)
    echo "error: MODE must be debug, profile, or release." >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
python3 "${REPO_DIR}/scripts/platform_profiles.py" check \
  --profile android-release-package \
  --wrapper flutter/build_android.sh \
  --target aarch64-linux-android \
  --features flutter,hwcodec,mediacodec

resolve_flutter_bin() {
  if [[ -n "${FLUTTER_BIN:-}" ]]; then
    printf '%s\n' "${FLUTTER_BIN}"
    return
  fi

  local properties="${SCRIPT_DIR}/android/local.properties"
  local flutter_sdk=""
  if [[ -f "${properties}" ]]; then
    flutter_sdk="$(sed -n 's/^flutter\.sdk=//p' "${properties}" | tail -n 1)"
  fi
  if [[ -n "${flutter_sdk}" && -x "${flutter_sdk}/bin/flutter" ]]; then
    printf '%s\n' "${flutter_sdk}/bin/flutter"
    return
  fi

  command -v flutter
}

if ! FLUTTER_BIN="$(resolve_flutter_bin)" || [[ ! -x "${FLUTTER_BIN}" ]]; then
  echo "error: Flutter was not found. Set FLUTTER_BIN or flutter.sdk in android/local.properties." >&2
  exit 1
fi

# The Flutter SDK is checked against the newest release of its channel at every build, as
# for Windows and Linux (this used to require the version in flutter/FLUTTER_VERSION, 3.44.7).
# RUSTADMIN_FLUTTER_CHANNEL=beta checks against beta; RUSTADMIN_UPDATE_FLUTTER=1 switches
# an older SDK to that release; RUSTADMIN_ALLOW_OUTDATED_FLUTTER=1 builds with it anyway.
# shellcheck source=../scripts/flutter_release_check.sh
source "${REPO_DIR}/scripts/flutter_release_check.sh"
case "$(uname -s)" in
  Darwin) FLUTTER_HOST_PLATFORM=macos ;;
  *) FLUTTER_HOST_PLATFORM=linux ;;
esac
check_flutter_release "$(cd "$(dirname "${FLUTTER_BIN}")/.." && pwd)" "${FLUTTER_HOST_PLATFORM}" \
  "${RUSTADMIN_FLUTTER_CHANNEL:-stable}" "${RUSTADMIN_UPDATE_FLUTTER:-0}" \
  "${RUSTADMIN_ALLOW_OUTDATED_FLUTTER:-0}" \
  RUSTADMIN_UPDATE_FLUTTER=1 RUSTADMIN_ALLOW_OUTDATED_FLUTTER=1 || exit 1

export PUB_CACHE="${PUB_CACHE:-${HOME}/.cache/rustadmin-flutter-pub}"

if [[ "${SKIP_RUST_BUILD:-0}" != "1" ]]; then
  bash "${SCRIPT_DIR}/ndk_arm64.sh"
  bash "${SCRIPT_DIR}/ndk_arm.sh"
  bash "${SCRIPT_DIR}/ndk_x64.sh"
fi

cd "${SCRIPT_DIR}"
"${FLUTTER_BIN}" pub get

declare -a FLUTTER_MODE_ARGS=("--${MODE}")
if [[ "${MODE}" == "release" ]]; then
  FLUTTER_MODE_ARGS+=(--obfuscate --split-debug-info=./split-debug-info)
fi

"${FLUTTER_BIN}" build apk \
  --split-per-abi \
  --target-platform android-arm64,android-arm,android-x64 \
  "${FLUTTER_MODE_ARGS[@]}"
"${FLUTTER_BIN}" build appbundle \
  --target-platform android-arm64,android-arm,android-x64 \
  "${FLUTTER_MODE_ARGS[@]}"
