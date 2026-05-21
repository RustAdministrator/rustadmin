#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build_linux.sh [--clean] [--hwcodec] [--skip-cargo]

Environment overrides:
  RUSTDESK_FLUTTER_ROOT       Flutter SDK root. Default: /mnt/f/GH/flutter
  RUSTDESK_LINUX_CODEC_ROOT   Native dependency prefix. Default: .local/linux-codecs, then /mnt/f/UBc/Release
  RUSTADMIN_LINUX_DIST_DIR    Release zip output dir. Default: rustdesk-client/dist/linux
  PUB_CACHE                   Dart package cache. Default: /mnt/f/GH/flutter-pub-cache-linux
  CARGO_TARGET_DIR            Cargo output dir. Default: /mnt/f/GH/rustdesk-target-linux
USAGE
}

clean=0
hwcodec=0
skip_cargo=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) clean=1 ;;
    --hwcodec) hwcodec=1 ;;
    --skip-cargo) skip_cargo=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
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
if ! command -v zip >/dev/null 2>&1; then
  echo "zip was not found. Install it with: sudo apt install zip" >&2
  exit 1
fi

mkdir -p "$PUB_CACHE" "$CARGO_TARGET_DIR"

read_version_info() {
  local revision_file="$repo_root/rustadmin_revision.txt"

  version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$repo_root/Cargo.toml" | head -n 1)"
  if [[ -z "$version" ]]; then
    echo "Could not read package version from $repo_root/Cargo.toml" >&2
    exit 1
  fi
  if [[ ! -f "$revision_file" ]]; then
    echo "Missing RustAdmin revision file: $revision_file" >&2
    exit 1
  fi
  revision="$(tr -d '[:space:]' < "$revision_file")"
  if [[ -z "$revision" ]]; then
    echo "RustAdmin revision file is empty: $revision_file" >&2
    exit 1
  fi
  archive_name="RustAdmin_Release_${version}.${revision}.zip"
}

generate_version_file() {
  local version_file="$repo_root/src/version.rs"

  cat > "$version_file" <<EOF
#[allow(dead_code)]
pub const VERSION: &str = "$version";
#[allow(dead_code)]
pub const RUSTADMIN_REVISION: &str = "$revision";
#[allow(dead_code)]
pub const FULL_VERSION: &str = "$version rev $revision";
#[allow(dead_code)]
pub const BUILD_DATE: &str = "$(date '+%Y-%m-%d %H:%M')";
EOF
}

package_release_zip() {
  local bundle_dir="$flutter_dir/build/linux/x64/release/bundle"
  local dist_dir="${RUSTADMIN_LINUX_DIST_DIR:-$repo_root/dist/linux}"
  local archive_path="$dist_dir/$archive_name"

  if [[ ! -d "$bundle_dir" ]]; then
    echo "Linux bundle was not found at $bundle_dir" >&2
    exit 1
  fi

  mkdir -p "$dist_dir"
  rm -f "$archive_path"
  (cd "$bundle_dir" && zip -qr "$archive_path" .)

  echo "Linux archive:"
  echo "$archive_path"
}

read_version_info

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
  generate_version_file
  (cd "$repo_root" && cargo build --features "$features" --lib --release)
fi

(cd "$flutter_dir" && flutter build linux --release)

echo "Linux bundle:"
bundle_dir="$flutter_dir/build/linux/x64/release/bundle"
echo "$bundle_dir"
package_release_zip
