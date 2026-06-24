#!/usr/bin/env bash
set -euo pipefail

# https://docs.flutter.dev/deployment/ios
# flutter build ipa --release --obfuscate --split-debug-info=./split-debug-info
# no obfuscate, because no easy to check errors

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLUTTER_BIN="$(command -v flutter)"
FLUTTER_ROOT="$(cd "$(dirname "$(dirname "${FLUTTER_BIN}")")" && pwd)"
DEFAULT_FLUTTER_PATCH="${REPO_DIR}/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"

apply_flutter_patch_if_requested() {
  [[ "${APPLY_FLUTTER_PATCH:-0}" == "1" ]] || return 0

  local patch_file="${FLUTTER_DROPDOWN_PATCH:-${DEFAULT_FLUTTER_PATCH}}"
  if [[ ! -f "${patch_file}" ]]; then
    echo "error: Flutter patch not found: ${patch_file}" >&2
    exit 1
  fi

  if git -C "${FLUTTER_ROOT}" apply --check "${patch_file}" >/dev/null 2>&1; then
    git -C "${FLUTTER_ROOT}" apply "${patch_file}"
  else
    echo "warning: Flutter patch was not applied; it may already be applied or incompatible with this Flutter version." >&2
  fi
}

find_frb_codegen() {
  if [[ -n "${FRB_CODEGEN:-}" ]]; then
    [[ -x "${FRB_CODEGEN}" ]] && printf '%s\n' "${FRB_CODEGEN}" && return 0
    echo "error: FRB_CODEGEN is not executable: ${FRB_CODEGEN}" >&2
    return 1
  fi

  if command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    command -v flutter_rust_bridge_codegen
    return 0
  fi

  local cargo_home="${CARGO_HOME:-${HOME}/.cargo}"
  local cargo_codegen="${cargo_home}/bin/flutter_rust_bridge_codegen"
  if [[ -x "${cargo_codegen}" ]]; then
    printf '%s\n' "${cargo_codegen}"
    return 0
  fi

  return 1
}

generate_ios_bridge_header_if_needed() {
  local ios_header="${SCRIPT_DIR}/ios/Runner/bridge_generated.h"
  [[ -f "${ios_header}" ]] && return 0

  local frb_codegen
  if ! frb_codegen="$(find_frb_codegen)"; then
    echo "error: missing ${ios_header}" >&2
    echo "       Set FRB_CODEGEN or install flutter_rust_bridge_codegen before packaging." >&2
    exit 1
  fi

  "${frb_codegen}" \
    --rust-input "${REPO_DIR}/src/flutter_ffi.rs" \
    --dart-output "${SCRIPT_DIR}/lib/generated_bridge.dart" \
    --c-output "${ios_header}" \
    --class-name Rustadmin
}

apply_flutter_patch_if_requested
generate_ios_bridge_header_if_needed
bash "${SCRIPT_DIR}/ios_arm64.sh"
cd "${SCRIPT_DIR}"
flutter build ipa --release
