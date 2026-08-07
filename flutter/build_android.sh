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
EXPECTED_FLUTTER_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/FLUTTER_VERSION")"

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

FLUTTER_VERSION_JSON="$("${FLUTTER_BIN}" --version --machine)"
ACTUAL_FLUTTER_VERSION="$(sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "${FLUTTER_VERSION_JSON}")"
if [[ "${ACTUAL_FLUTTER_VERSION}" != "${EXPECTED_FLUTTER_VERSION}" ]]; then
  echo "error: Flutter ${EXPECTED_FLUTTER_VERSION} is required; found ${ACTUAL_FLUTTER_VERSION:-unknown}." >&2
  exit 1
fi

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
