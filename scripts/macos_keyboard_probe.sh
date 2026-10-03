#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/macos_keyboard_probe.sh [--help | --self-test]

Compiles the dependency-free AppKit keyboard probe into a private temporary
directory, runs it in the foreground, and removes the temporary build on exit.
USAGE
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 && ! ( $# -eq 1 && "$1" == "--self-test" ) ]]; then
  echo "Unknown argument: $1" >&2
  usage >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_file="$script_dir/macos_keyboard_probe.swift"

command -v xcrun >/dev/null 2>&1 || {
  echo "xcrun is required to compile the macOS keyboard probe" >&2
  exit 1
}
[[ -f "$source_file" ]] || {
  echo "Probe source does not exist: $source_file" >&2
  exit 1
}

architecture="${RUSTADMIN_MACOS_PROBE_ARCH:-$(uname -m)}"
case "$architecture" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported macOS probe architecture: $architecture" >&2
    exit 1
    ;;
esac

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustadmin-keyboard-probe.XXXXXX")"
cleanup() {
  rm -rf -- "$build_dir"
}
trap cleanup EXIT

probe_binary="$build_dir/macos_keyboard_probe"
xcrun swiftc \
  -swift-version 5 \
  -target "$architecture-apple-macos12.0" \
  -sdk "$sdk_path" \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  "$source_file" \
  -o "$probe_binary"

"$probe_binary" "$@"
