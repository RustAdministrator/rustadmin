#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="lib/prototyping/main_mobile_remote_lab.dart"

case "$(uname -s)" in
  Darwin)
    runner="$script_dir/run_toolbar_lab_macos.sh"
    runner_args=()
    ;;
  Linux)
    runner="$script_dir/run_toolbar_lab_linux.sh"
    export RUSTADMIN_FLUTTER_LAB=1
    runner_args=(--skip-cargo)
    ;;
  *)
    echo "Unsupported host. Use run_mobile_remote_lab_windows.ps1 on Windows." >&2
    exit 1
    ;;
esac

exec "$runner" "${runner_args[@]}" --target "$target" "$@"
