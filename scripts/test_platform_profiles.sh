#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/platform_profiles.py"

check() {
  python3 "$validator" check "$@" >/dev/null
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$(python3 "$validator" check "$@" 2>&1)"; then
    echo "error: invalid profile invocation unexpectedly passed: $*" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "error: expected diagnostic '$expected', got: $output" >&2
    exit 1
  fi
}

python3 "$validator" validate >/dev/null
python3 -m py_compile "$validator"
bash -n \
  "$repo_root/flutter/android_common.sh" \
  "$repo_root/flutter/build_android.sh" \
  "$repo_root/flutter/ios_common.sh" \
  "$repo_root/flutter/build_ios.sh" \
  "$repo_root/flutter/build_ios_sim.sh" \
  "$repo_root/flutter/ndk_arm64.sh" \
  "$repo_root/flutter/ndk_arm.sh" \
  "$repo_root/flutter/ndk_x64.sh" \
  "$repo_root/flutter/ndk_x86.sh" \
  "$repo_root/flutter/ios_arm64.sh" \
  "$repo_root/flutter/ios_sim_arm64.sh" \
  "$repo_root/flutter/ios_x64.sh" \
  "$repo_root/scripts/build_linux.sh" \
  "$repo_root/scripts/build_macos.sh"

check --profile android-release-package --wrapper flutter/build_android.sh \
  --target aarch64-linux-android --features flutter,hwcodec,mediacodec
check --profile android-arm64 --wrapper flutter/ndk_arm64.sh \
  --target aarch64-linux-android --abi arm64-v8a \
  --features flutter,hwcodec,mediacodec
check --profile android-armv7 --wrapper flutter/ndk_arm.sh \
  --target armv7-linux-androideabi --abi armeabi-v7a \
  --features flutter,hwcodec,mediacodec
check --profile android-x86_64 --wrapper flutter/ndk_x64.sh \
  --target x86_64-linux-android --abi x86_64 \
  --features flutter
check --profile android-x86 --wrapper flutter/ndk_x86.sh \
  --target i686-linux-android --abi x86 \
  --features flutter
check --profile ios-device-arm64 --wrapper flutter/build_ios.sh \
  --target aarch64-apple-ios --abi arm64 --features flutter,hwcodec
check --profile ios-device-arm64 --wrapper flutter/ios_arm64.sh \
  --target aarch64-apple-ios --abi arm64 \
  --features flutter,hwcodec
check --profile ios-simulator-arm64 --wrapper flutter/ios_sim_arm64.sh \
  --target aarch64-apple-ios-sim --abi arm64 \
  --features flutter,hwcodec
check --profile ios-simulator-x86_64 --wrapper flutter/ios_x64.sh \
  --target x86_64-apple-ios --abi x86_64 \
  --features flutter,hwcodec
check --profile ios-simulator-package --wrapper flutter/build_ios_sim.sh \
  --target x86_64-apple-ios --features flutter,hwcodec
check --profile macos-release --wrapper scripts/build_macos.sh \
  --target aarch64-apple-darwin \
  --features flutter,hwcodec,screencapturekit
check --profile windows-x86_64-release --wrapper scripts/build_windows.ps1 \
  --target x86_64-pc-windows-msvc \
  --features flutter,hwcodec
check --profile linux-x86_64-release --wrapper scripts/build_linux.sh \
  --target x86_64-unknown-linux-gnu \
  --features flutter,linux-pkg-config,hwcodec

expect_failure "requires ['mediacodec']" \
  --profile android-arm64 --wrapper flutter/ndk_arm64.sh \
  --target aarch64-linux-android --abi arm64-v8a \
  --features flutter,hwcodec
expect_failure "requires ['hwcodec']" \
  --profile android-arm64 --wrapper flutter/ndk_arm64.sh \
  --target aarch64-linux-android --abi arm64-v8a \
  --features flutter,mediacodec
expect_failure "ABI x86 does not match" \
  --profile android-arm64 --wrapper flutter/ndk_arm64.sh \
  --target aarch64-linux-android --abi x86 \
  --features flutter
expect_failure "is not supported" \
  --profile windows-x86_64-release --wrapper scripts/build_windows.ps1 \
  --target aarch64-pc-windows-msvc \
  --features flutter
expect_failure "missing required features ['linux-pkg-config']" \
  --profile linux-x86_64-release --wrapper scripts/build_linux.sh \
  --target x86_64-unknown-linux-gnu \
  --features flutter
expect_failure "forbidden features ['mediacodec']" \
  --profile windows-x86_64-release --wrapper scripts/build_windows.ps1 \
  --target x86_64-pc-windows-msvc \
  --features flutter,mediacodec
expect_failure "is not owned" \
  --profile linux-x86_64-release --wrapper scripts/build_macos.sh \
  --target x86_64-unknown-linux-gnu --features flutter,linux-pkg-config
expect_failure "required: --wrapper" \
  --profile android-arm64 --target aarch64-linux-android --abi arm64-v8a \
  --features flutter

echo "Platform profile validation tests passed."
