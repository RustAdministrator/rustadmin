#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <rust-target> <android-abi> <cargo-features>" >&2
  exit 2
fi

RUST_TARGET="$1"
ANDROID_ABI="$2"
CARGO_FEATURES="$3"
ANDROID_API_LEVEL=24
EXPECTED_NDK_VERSION=28.2.13676358

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
JNI_LIBS_DIR="${SCRIPT_DIR}/android/app/src/main/jniLibs"

if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "${ANDROID_NDK_HOME}" ]]; then
  echo "error: ANDROID_NDK_HOME must point to Android NDK ${EXPECTED_NDK_VERSION}." >&2
  exit 1
fi

NDK_VERSION="$(sed -n 's/^Pkg.Revision[[:space:]]*=[[:space:]]*//p' "${ANDROID_NDK_HOME}/source.properties")"
if [[ "${NDK_VERSION}" != "${EXPECTED_NDK_VERSION}" ]]; then
  echo "error: Android NDK ${EXPECTED_NDK_VERSION} is required; found ${NDK_VERSION:-unknown}." >&2
  exit 1
fi

declare -a PREFIX_CANDIDATES=()

add_prefix_candidate() {
  local root="$1"
  [[ -z "${root}" ]] && return 0
  if [[ "$(basename "${root}")" == "${ANDROID_ABI}" ]]; then
    PREFIX_CANDIDATES+=("${root}")
  else
    PREFIX_CANDIDATES+=("${root}/${ANDROID_ABI}")
  fi
}

if [[ -n "${RUSTADMIN_ANDROID_NATIVE_ROOT:-}" ]]; then
  add_prefix_candidate "${RUSTADMIN_ANDROID_NATIVE_ROOT}"
fi

if [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
  OLD_IFS="${IFS}"
  IFS=':;'
  read -r -a CMAKE_PREFIXES <<< "${CMAKE_PREFIX_PATH}"
  IFS="${OLD_IFS}"
  for root in "${CMAKE_PREFIXES[@]}"; do
    add_prefix_candidate "${root}"
  done
fi

ANDROID_NATIVE_PREFIX=""
for prefix in "${PREFIX_CANDIDATES[@]:-}"; do
  if [[ -f "${prefix}/lib/liboboe.a" &&
        -f "${prefix}/lib/libndk_compat.a" &&
        -f "${prefix}/lib/libopus.a" &&
        -f "${prefix}/lib/libvpx.a" &&
        -f "${prefix}/lib/libaom.a" &&
        -f "${prefix}/lib/libyuv.a" &&
        -f "${prefix}/include/opus/opus_multistream.h" &&
        -f "${prefix}/include/vpx/vpx_encoder.h" &&
        -f "${prefix}/include/aom/aom.h" &&
        -f "${prefix}/include/libyuv/convert.h" ]]; then
    ANDROID_NATIVE_PREFIX="${prefix}"
    break
  fi
done

if [[ -z "${ANDROID_NATIVE_PREFIX}" ]]; then
  echo "error: native Android dependencies for ${ANDROID_ABI} were not found." >&2
  echo "       Set RUSTADMIN_ANDROID_NATIVE_ROOT to a root containing ${ANDROID_ABI}/include and ${ANDROID_ABI}/lib," >&2
  echo "       or add that ABI-specific prefix to CMAKE_PREFIX_PATH." >&2
  exit 1
fi

export CMAKE_PREFIX_PATH="${ANDROID_NATIVE_PREFIX}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
mkdir -p "${JNI_LIBS_DIR}"

cd "${REPO_DIR}"
cargo ndk \
  --platform "${ANDROID_API_LEVEL}" \
  --target "${RUST_TARGET}" \
  --output-dir "${JNI_LIBS_DIR}" \
  --bindgen \
  build \
  --locked \
  --release \
  --features "${CARGO_FEATURES}"
