#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="lib/prototyping/main_mobile_remote_lab.dart"

case "$(uname -s)" in
  Darwin)
    runner="$script_dir/run_toolbar_lab_macos.sh"
    ;;
  Linux)
    runner="$script_dir/run_toolbar_lab_linux.sh"
    ;;
  *)
    echo "Unsupported host. Use run_mobile_remote_lab_windows.ps1 on Windows." >&2
    exit 1
    ;;
esac

exec "$runner" --target "$target" "$@"
