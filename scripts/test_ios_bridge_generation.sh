#!/usr/bin/env bash
set -euo pipefail

TEST_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${TEST_REPO_DIR}/flutter/ios_flutter_common.sh"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustadmin-ios-bridge.XXXXXX")"
test_dir="$(cd "${test_dir}" && pwd)"
trap 'rm -rf "${test_dir}"' EXIT
REPO_DIR="${test_dir}"
SCRIPT_DIR="${test_dir}/flutter"
mkdir -p "${SCRIPT_DIR}/ios/Runner"

calls=0
codegen_status=0
mock_codegen() {
  [[ "$#" == 8 ]] || exit 1
  [[ "$1" == --rust-input && "$2" == "${REPO_DIR}/src/flutter_ffi.rs" ]] || exit 1
  [[ "$3" == --dart-output && "$4" == "${SCRIPT_DIR}/lib/generated_bridge.dart" ]] || exit 1
  [[ "$5" == --c-output && "$6" == "${SCRIPT_DIR}/ios/Runner/bridge_generated.h" ]] || exit 1
  [[ "$7" == --class-name && "$8" == Rustadmin ]] || exit 1
  calls=$((calls + 1))
  return "${codegen_status}"
}
find_frb_codegen() { printf '%s\n' mock_codegen; }

# Fresh checkout and an existing (possibly stale or partial) header both generate.
generate_ios_bridge
[[ "${calls}" == 1 ]]
touch "${SCRIPT_DIR}/ios/Runner/bridge_generated.h"
generate_ios_bridge
[[ "${calls}" == 2 ]]

# A failed generator must never let the packaging wrapper compile stale outputs.
codegen_status=17
status=0
generate_ios_bridge || status=$?
[[ "${status}" == 17 && "${calls}" == 3 ]]

resolve_flutter_tools() { FLUTTER_BIN=mock_flutter; }
configure_ios_pub_cache() { :; }
apply_flutter_patch_if_requested() { :; }
mock_flutter() { [[ "$PWD" == "${SCRIPT_DIR}" && "$*" == 'pub get' ]]; }
if prepare_ios_flutter_build unused; then
  echo 'error: preparation ignored a codegen failure' >&2
  exit 1
fi
[[ "${calls}" == 4 ]]
codegen_status=0
prepare_ios_flutter_build unused
[[ "${calls}" == 5 ]]

mock_flutter() { return 1; }
if prepare_ios_flutter_build unused; then
  echo 'error: preparation ignored a pub get failure' >&2
  exit 1
fi
[[ "${calls}" == 5 ]]

find_frb_codegen() { return 1; }
if generate_ios_bridge; then
  echo 'error: an existing header bypassed the missing generator check' >&2
  exit 1
fi
echo 'iOS bridge generation checks passed.'
