#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/run_toolbar_lab_linux.sh [--clean] [--hwcodec] [--skip-cargo] [--device DEVICE] [-- FLUTTER_RUN_ARGS...]

Environment overrides:
  RUSTDESK_FLUTTER_ROOT       Flutter SDK root. Default: /mnt/f/GH/flutter
  RUSTDESK_LINUX_CODEC_ROOT   Native dependency prefix. Default: .local/linux-codecs, then /mnt/f/UBc/Release
  PUB_CACHE                   Dart package cache. Default: /mnt/f/GH/flutter-pub-cache-linux
  CARGO_TARGET_DIR            Cargo output dir. Default: /mnt/f/GH/rustdesk-target-linux
USAGE
}

clean=0
hwcodec=0
skip_cargo=0
device="linux"
flutter_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) clean=1 ;;
    --hwcodec) hwcodec=1 ;;
    --skip-cargo) skip_cargo=1 ;;
    --device)
      shift
      if [[ $# -eq 0 ]]; then
        echo "--device requires a value." >&2
        usage
        exit 2
      fi
      device="$1"
      ;;
    --)
      shift
      flutter_args=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_dir="$repo_root/flutter"

flutter_root="${RUSTDESK_FLUTTER_ROOT:-/mnt/f/GH/flutter}"
if [[ -z "${RUSTDESK_LINUX_CODEC_ROOT:-}" ]]; then
  if [[ -e "$repo_root/.local/linux-codecs" ]]; then
    deps_root="$repo_root/.local/linux-codecs"
  else
    deps_root="/mnt/f/UBc/Release"
  fi
else
  deps_root="$RUSTDESK_LINUX_CODEC_ROOT"
fi

export PATH="$flutter_root/bin:$PATH"
export PUB_CACHE="${PUB_CACHE:-/mnt/f/GH/flutter-pub-cache-linux}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/mnt/f/GH/rustdesk-target-linux}"
export RUSTDESK_LINUX_CODEC_ROOT="$deps_root"
export PKG_CONFIG_PATH="$repo_root/pkgconfig:$deps_root/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

if [[ ! -x "$flutter_root/bin/flutter" ]]; then
  echo "Flutter was not found at '$flutter_root/bin/flutter'." >&2
  echo "Set RUSTDESK_FLUTTER_ROOT or pass the right SDK in PATH." >&2
  exit 1
fi
if [[ ! -e "$deps_root" ]]; then
  echo "Dependency prefix was not found at '$deps_root'." >&2
  echo "Set RUSTDESK_LINUX_CODEC_ROOT." >&2
  exit 1
fi

mkdir -p "$PUB_CACHE" "$CARGO_TARGET_DIR"

package_config="$flutter_dir/.dart_tool/package_config.json"
if [[ "$clean" -eq 1 ]] ||
   [[ ! -f "$package_config" ]] ||
   grep -Eq 'file:///([A-Z]:|[A-Za-z]%3A)|flutter-win|\\|file:///Users/|/Users/' "$package_config" 2>/dev/null; then
  echo "Refreshing Linux Flutter metadata..."
  rm -rf "$flutter_dir/.dart_tool" "$flutter_dir/.flutter-plugins-dependencies" "$flutter_dir/build/linux"
fi

(cd "$flutter_dir" && flutter pub get)

features="flutter linux-pkg-config"
if [[ "$hwcodec" -eq 1 ]]; then
  features="$features hwcodec"
fi

if [[ "$skip_cargo" -eq 0 ]]; then
  (cd "$repo_root" && cargo build --features "$features" --lib)
fi

(
  cd "$flutter_dir"
  flutter run -d "$device" -t lib/prototyping/main_toolbar_lab.dart "${flutter_args[@]}"
)
