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
REQUIRE_FFMPEG=0

case ",${CARGO_FEATURES}," in
  *,hwcodec,*) REQUIRE_FFMPEG=1 ;;
esac

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

case "${RUST_TARGET}" in
  aarch64-linux-android) NDK_TARGET="aarch64-linux-android" ;;
  armv7-linux-androideabi) NDK_TARGET="arm-linux-androideabi" ;;
  x86_64-linux-android) NDK_TARGET="x86_64-linux-android" ;;
  i686-linux-android) NDK_TARGET="i686-linux-android" ;;
  *)
    echo "error: unsupported Android Rust target ${RUST_TARGET}." >&2
    exit 2
    ;;
esac

NDK_PREBUILT_DIRS=("${ANDROID_NDK_HOME}"/toolchains/llvm/prebuilt/*)
if [[ "${#NDK_PREBUILT_DIRS[@]}" -ne 1 || ! -d "${NDK_PREBUILT_DIRS[0]}" ]]; then
  echo "error: expected one NDK LLVM prebuilt host directory." >&2
  exit 1
fi
LIBCXX_SHARED="${NDK_PREBUILT_DIRS[0]}/sysroot/usr/lib/${NDK_TARGET}/libc++_shared.so"
if [[ ! -f "${LIBCXX_SHARED}" ]]; then
  echo "error: NDK libc++_shared.so was not found for ${ANDROID_ABI}." >&2
  exit 1
fi

declare -a PREFIX_CANDIDATES=()

add_prefix_candidate() {
  local root="$1"
  [[ -z "${root}" ]] && return 0
  PREFIX_CANDIDATES+=("${root}")
  if [[ "$(basename "${root}")" != "${ANDROID_ABI}" ]]; then
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
  if [[ ! -f "${prefix}/lib/libndk_compat.a" ||
        ! -f "${prefix}/lib/libopus.a" ||
        ! -f "${prefix}/lib/libvpx.a" ||
        ! -f "${prefix}/lib/libaom.a" ||
        ! -f "${prefix}/lib/libyuv.a" ||
        ! -f "${prefix}/include/opus/opus_multistream.h" ||
        ! -f "${prefix}/include/vpx/vpx_encoder.h" ||
        ! -f "${prefix}/include/aom/aom.h" ||
        ! -f "${prefix}/include/libyuv/convert.h" ]]; then
    continue
  fi
  if [[ "${REQUIRE_FFMPEG}" == "1" ]] &&
     [[ ! -f "${prefix}/lib/libavcodec.a" ||
        ! -f "${prefix}/lib/libavformat.a" ||
        ! -f "${prefix}/lib/libavutil.a" ||
        ! -f "${prefix}/lib/libswresample.a" ||
        ! -f "${prefix}/include/libavcodec/avcodec.h" ||
        ! -f "${prefix}/include/libavformat/avformat.h" ||
        ! -f "${prefix}/include/libavutil/avutil.h" ||
        ! -f "${prefix}/lib/pkgconfig/libavcodec.pc" ||
        ! -f "${prefix}/lib/pkgconfig/libavformat.pc" ||
        ! -f "${prefix}/lib/pkgconfig/libavutil.pc" ||
        ! -f "${prefix}/lib/pkgconfig/libswresample.pc" ]]; then
    continue
  fi
  ANDROID_NATIVE_PREFIX="${prefix}"
  break
done

if [[ -z "${ANDROID_NATIVE_PREFIX}" ]]; then
  echo "error: native Android dependencies for ${ANDROID_ABI} were not found." >&2
  echo "       Set RUSTADMIN_ANDROID_NATIVE_ROOT or CMAKE_PREFIX_PATH to the dedicated" >&2
  echo "       ${ANDROID_ABI} prefix containing include/ and lib/." >&2
  exit 1
fi

export RUSTADMIN_ANDROID_NATIVE_ROOT="${ANDROID_NATIVE_PREFIX}"
export CMAKE_PREFIX_PATH="${ANDROID_NATIVE_PREFIX}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
export CARGO_PROFILE_RELEASE_RPATH=false
mkdir -p "${JNI_LIBS_DIR}"

cd "${REPO_DIR}"
cargo ndk \
  --platform "${ANDROID_API_LEVEL}" \
  --target "${RUST_TARGET}" \
  --output-dir "${JNI_LIBS_DIR}" \
  --bindgen \
  build \
  --locked \
  --lib \
  --release \
  --features "${CARGO_FEATURES}"

ABI_JNI_LIBS_DIR="${JNI_LIBS_DIR}/${ANDROID_ABI}"
GENERATED_RUST_LIBRARY="${ABI_JNI_LIBS_DIR}/liblibrustdesk.so"
if [[ ! -f "${GENERATED_RUST_LIBRARY}" ]]; then
  echo "error: cargo-ndk did not produce ${GENERATED_RUST_LIBRARY}." >&2
  exit 1
fi
mv -f "${GENERATED_RUST_LIBRARY}" "${ABI_JNI_LIBS_DIR}/librustdesk.so"
cp -f "${LIBCXX_SHARED}" "${ABI_JNI_LIBS_DIR}/libc++_shared.so"
