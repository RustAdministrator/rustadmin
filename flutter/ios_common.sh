#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <rust-target> <lipo-arch> <platform-id> <platform-name>" >&2
  exit 2
fi

RUST_TARGET="$1"
LIPO_ARCH="$2"
EXPECTED_PLATFORM="$3"
PLATFORM_NAME="$4"
SDK_NAME="iphoneos"
if [[ "${EXPECTED_PLATFORM}" == "7" ]]; then
  SDK_NAME="iphonesimulator"
fi

: "${IPHONEOS_DEPLOYMENT_TARGET:=13.0}"
export IPHONEOS_DEPLOYMENT_TARGET

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

declare -a CODEC_ROOTS=()
declare -a CODEC_ROOT_LABELS=()
FOUND_COMPONENT_ROOT=""

add_unique_codec_root() {
  local root="$1"
  local label="$2"
  [[ -z "${root}" ]] && return 0

  if [[ -d "${root}" ]]; then
    root="$(cd "${root}" && pwd)"
  fi

  local existing
  for existing in "${CODEC_ROOTS[@]:-}"; do
    [[ "${existing}" == "${root}" ]] && return 0
  done

  CODEC_ROOTS+=("${root}")
  CODEC_ROOT_LABELS+=("${label}")
}

add_codec_root_candidate() {
  local root="$1"
  local label="$2"
  add_unique_codec_root "${root}" "${label}"

  case "$(basename "${root}")" in
    include|lib)
      add_unique_codec_root "$(dirname "${root}")" "${label} parent"
      ;;
  esac
}

add_path_list_candidates() {
  local value="$1"
  local label="$2"
  local old_ifs="${IFS}"
  local -a paths=()
  IFS=":;"
  read -r -a paths <<< "${value}"
  IFS="${old_ifs}"

  local path
  for path in "${paths[@]}"; do
    add_codec_root_candidate "${path}" "${label}"
  done
}

if [[ -n "${RUSTDESK_IOS_CODEC_ROOT:-}" ]]; then
  add_codec_root_candidate "${RUSTDESK_IOS_CODEC_ROOT}" "RUSTDESK_IOS_CODEC_ROOT"
fi

if [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
  add_path_list_candidates "${CMAKE_PREFIX_PATH}" "CMAKE_PREFIX_PATH"
fi

if [[ "${EXPECTED_PLATFORM}" == "7" ]]; then
  add_codec_root_candidate "${REPO_DIR}/.local/ios-simulator-codecs" ".local/ios-simulator-codecs"
  add_codec_root_candidate "/Volumes/Dev/MOemu/Release" "MOemu simulator prefix"
else
  add_codec_root_candidate "${REPO_DIR}/.local/ios-codecs" ".local/ios-codecs"
  add_codec_root_candidate "/Volumes/Dev/MOios/Release" "MOios device prefix"
fi

SDK_PATH="$(xcrun --sdk "${SDK_NAME}" --show-sdk-path)"
BINDGEN_TARGET=""
BINDGEN_ENV=""
case "${RUST_TARGET}" in
  aarch64-apple-ios)
    BINDGEN_TARGET="arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}"
    BINDGEN_ENV="BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios"
    ;;
  aarch64-apple-ios-sim)
    BINDGEN_TARGET="arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}-simulator"
    BINDGEN_ENV="BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim"
    ;;
  x86_64-apple-ios)
    BINDGEN_TARGET="x86_64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}-simulator"
    BINDGEN_ENV="BINDGEN_EXTRA_CLANG_ARGS_x86_64_apple_ios"
    ;;
esac
if [[ -n "${BINDGEN_ENV}" && -z "${!BINDGEN_ENV:-}" ]]; then
  export "${BINDGEN_ENV}=--target=${BINDGEN_TARGET} -isysroot ${SDK_PATH}"
fi

check_library_platform() {
  local component="$1"
  local library="$2"

  if ! lipo "${library}" -verify_arch "${LIPO_ARCH}" >/dev/null 2>&1; then
    echo "error: ${component} library does not contain ${LIPO_ARCH}: ${library}" >&2
    return 1
  fi

  local output
  if ! output="$(otool -arch "${LIPO_ARCH}" -l "${library}" 2>&1)"; then
    echo "error: failed to inspect ${component} library: ${library}" >&2
    echo "${output}" >&2
    return 1
  fi

  local platforms
  platforms="$(
    awk '
      /LC_BUILD_VERSION/ { in_build = 1; next }
      in_build && $1 == "platform" { print $2; in_build = 0 }
    ' <<< "${output}" | sort -u | tr '\n' ' '
  )"

  if [[ -z "${platforms// }" ]]; then
    if grep -q "LC_VERSION_MIN_IPHONEOS" <<< "${output}"; then
      return 0
    fi
    echo "error: ${component} library has no iOS platform marker: ${library}" >&2
    return 1
  fi

  local platform
  for platform in ${platforms}; do
    [[ "${platform}" == "${EXPECTED_PLATFORM}" ]] && return 0
  done

  echo "error: ${component} library is not built for ${PLATFORM_NAME}: ${library}" >&2
  echo "       found LC_BUILD_VERSION platform(s): ${platforms}" >&2
  echo "       expected platform ${EXPECTED_PLATFORM} for ${RUST_TARGET}" >&2
  if [[ " ${platforms} " == *" 1 "* ]]; then
    echo "       platform 1 is macOS, not iOS." >&2
  fi
  return 1
}

find_component_root() {
  local component="$1"
  local header="$2"
  local library="$3"

  local index
  for index in "${!CODEC_ROOTS[@]}"; do
    local root="${CODEC_ROOTS[${index}]}"
    local label="${CODEC_ROOT_LABELS[${index}]}"
    local header_path="${root}/${header}"
    local library_path="${root}/${library}"

    if [[ ! -f "${header_path}" || ! -f "${library_path}" ]]; then
      continue
    fi

    check_library_platform "${component}" "${library_path}"
    FOUND_COMPONENT_ROOT="${root}"
    echo "Using ${component} from ${root} (${label})"
    return 0
  done

  echo "error: no ${component} iOS codec prefix found for ${RUST_TARGET}." >&2
  echo "       required files: ${header} and ${library}" >&2
  return 1
}

if [[ ${#CODEC_ROOTS[@]} -eq 0 ]]; then
  echo "error: no iOS codec roots configured." >&2
  echo "       Set RUSTDESK_IOS_CODEC_ROOT, CMAKE_PREFIX_PATH, or create a local iOS codec prefix." >&2
  exit 1
fi

find_component_root "libyuv" "include/libyuv/convert.h" "lib/libyuv.a"
SELECTED_CODEC_ROOT="${FOUND_COMPONENT_ROOT}"
if [[ -z "${RUSTDESK_IOS_CODEC_ROOT:-}" ]]; then
  export RUSTDESK_IOS_CODEC_ROOT="${SELECTED_CODEC_ROOT}"
fi
if [[ -z "${CMAKE_PREFIX_PATH:-}" ]]; then
  export CMAKE_PREFIX_PATH="${SELECTED_CODEC_ROOT}"
fi
find_component_root "libvpx" "include/vpx/vpx_encoder.h" "lib/libvpx.a"
find_component_root "aom" "include/aom/aom.h" "lib/libaom.a"
find_component_root "opus" "include/opus/opus_multistream.h" "lib/libopus.a"
find_component_root "libsodium" "include/sodium.h" "lib/libsodium.a"
if [[ -z "${SODIUM_LIB_DIR:-}" ]]; then
  export SODIUM_LIB_DIR="${FOUND_COMPONENT_ROOT}/lib"
fi

cd "${REPO_DIR}"
cargo build --locked --features flutter --release --target "${RUST_TARGET}" --lib
