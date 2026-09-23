#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/macos/RustAdminUpdate/RustAdminUpdate.swift"
test_file="$repo_root/macos/RustAdminUpdate/Tests/UpdaterTests.swift"
test_root="$(mktemp -d "${TMPDIR:-/private/tmp}/rustadmin-updater-tests.XXXXXX")"
cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

[[ -f "$source_file" ]] || { echo "Updater source does not exist: $source_file" >&2; exit 1; }
[[ -f "$test_file" ]] || { echo "Updater tests do not exist: $test_file" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "xcrun is required" >&2; exit 1; }

module_cache="$test_root/module-cache"
test_binary="$test_root/RustAdminUpdaterTests"
mkdir -p "$module_cache"

xcrun swiftc \
  -swift-version 5 \
  -D RUSTADMIN_UPDATER_TESTS \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  -framework Foundation \
  "$source_file" \
  "$test_file" \
  -o "$test_binary"

"$test_binary"

if command -v osacompile >/dev/null 2>&1; then
  script_file="$test_root/RustAdminUpdate.applescript"
  compiled_script="$test_root/RustAdminUpdate.scpt"
  "$test_binary" --dump-test-privileged-script "$script_file"
  osacompile -o "$compiled_script" "$script_file"
  echo "AppleScript syntax check passed (return-shell-script substitution)"
else
  echo "osacompile not found; skipped AppleScript syntax check" >&2
fi
