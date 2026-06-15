#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build_linux.sh [--clean] [--hwcodec] [--skip-cargo] [--package zip|deb|all] [--deb]

Environment overrides:
  RUSTADMIN_FLUTTER_ROOT      Flutter SDK root. Default: flutter found in PATH,
                              then nearby checkout candidates.
  RUSTADMIN_SKIP_BRIDGE_GEN   Set to 1 to skip flutter_rust_bridge codegen. Default: 0
  RUSTADMIN_FORCE_BRIDGE_GEN  Set to 1 to regenerate bridge files even if current. Default: 0
  RUSTADMIN_VERBOSE_BRIDGE_GEN
                              Set to 1 to print bridge generator output on success. Default: 0
  RUSTADMIN_BRIDGE_LLVM_PATH  LLVM prefix for bridge codegen, e.g. /usr/lib/llvm-20.
                              Default: llvm-config/llvm-config-* prefix when found.
  RUSTADMIN_BRIDGE_LLVM_COMPILER_OPTS
                              Extra clang opts for bridge codegen. Optional
  RUSTADMIN_LINUX_CODEC_ROOT  Native dependency prefix. Default: .local/linux-codecs
                              when present, otherwise system pkg-config
                              packages are used.
  RUSTADMIN_LINUX_CODEC_LINK_MODE
                              FFmpeg link mode for hwcodec: auto, static, or dynamic.
                              Default: auto.
  RUSTADMIN_LINUX_DIST_DIR    Release zip output dir. Default: dist/linux
  PUB_CACHE                   Dart package cache. Default: $XDG_CACHE_HOME/rustadmin/flutter-pub-cache-linux,
                              or $HOME/.cache/rustadmin/flutter-pub-cache-linux.
  CARGO_TARGET_DIR            Cargo output dir. Default: target

Legacy RUSTDESK_* variable names are still accepted for compatibility.
USAGE
}

clean=0
hwcodec=0
skip_cargo=0
package_mode="zip"
skip_bridge_gen="${RUSTADMIN_SKIP_BRIDGE_GEN:-${RUSTDESK_SKIP_BRIDGE_GEN:-0}}"
force_bridge_gen="${RUSTADMIN_FORCE_BRIDGE_GEN:-${RUSTDESK_FORCE_BRIDGE_GEN:-0}}"
verbose_bridge_gen="${RUSTADMIN_VERBOSE_BRIDGE_GEN:-${RUSTDESK_VERBOSE_BRIDGE_GEN:-0}}"
bridge_class_name="Rustadmin"
bridge_llvm_path="${RUSTADMIN_BRIDGE_LLVM_PATH:-${RUSTDESK_BRIDGE_LLVM_PATH:-}}"
bridge_llvm_compiler_opts="${RUSTADMIN_BRIDGE_LLVM_COMPILER_OPTS:-${RUSTDESK_BRIDGE_LLVM_COMPILER_OPTS:-}}"
codec_link_mode="${RUSTADMIN_LINUX_CODEC_LINK_MODE:-${RUSTDESK_LINUX_CODEC_LINK_MODE:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) clean=1 ;;
    --hwcodec) hwcodec=1 ;;
    --skip-cargo) skip_cargo=1 ;;
    --deb) package_mode="deb" ;;
    --package)
      shift
      if [[ $# -eq 0 ]]; then
        echo "--package requires one of: zip, deb, all." >&2
        usage
        exit 2
      fi
      case "$1" in
        zip|deb|all) package_mode="$1" ;;
        *) echo "Unknown package mode: $1" >&2; usage; exit 2 ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_dir="$repo_root/flutter"

resolve_flutter_root() {
  local configured_root="${RUSTADMIN_FLUTTER_ROOT:-${RUSTDESK_FLUTTER_ROOT:-}}"
  if [[ -n "$configured_root" ]]; then
    printf '%s\n' "$configured_root"
    return
  fi

  local flutter_bin
  flutter_bin="$(command -v flutter || true)"
  if [[ -n "$flutter_bin" ]]; then
    cd "$(dirname "$flutter_bin")/.." && pwd
    return
  fi

  local candidate
  for candidate in \
    "$repo_root/../flutter" \
    "$repo_root/../../flutter" \
    "${HOME:-}/flutter"; do
    if [[ -x "$candidate/bin/flutter" ]]; then
      cd "$candidate" && pwd
      return
    fi
  done
}

default_pub_cache() {
  if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    printf '%s\n' "$XDG_CACHE_HOME/rustadmin/flutter-pub-cache-linux"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "$HOME/.cache/rustadmin/flutter-pub-cache-linux"
  else
    printf '%s\n' "$repo_root/.local/flutter-pub-cache-linux"
  fi
}

append_pkg_config_path() {
  local path="$1"
  if [[ -n "$path" ]]; then
    if [[ -n "${PKG_CONFIG_PATH:-}" ]]; then
      export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$path"
    else
      export PKG_CONFIG_PATH="$path"
    fi
  fi
}

flutter_root="$(resolve_flutter_root || true)"
if [[ -n "$flutter_root" ]]; then
  export PATH="$flutter_root/bin:$PATH"
fi

export PUB_CACHE="${PUB_CACHE:-$(default_pub_cache)}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$repo_root/target}"

deps_root=""
configured_deps_root="${RUSTADMIN_LINUX_CODEC_ROOT:-${RUSTDESK_LINUX_CODEC_ROOT:-}}"
if [[ -n "$configured_deps_root" ]]; then
  deps_root="$configured_deps_root"
  if [[ ! -e "$deps_root" ]]; then
    echo "Dependency prefix was not found at '$deps_root'." >&2
    echo "Fix RUSTADMIN_LINUX_CODEC_ROOT or unset it to use system pkg-config packages." >&2
    exit 1
  fi
elif [[ -e "$repo_root/.local/linux-codecs" ]]; then
  deps_root="$repo_root/.local/linux-codecs"
fi
if [[ -n "$deps_root" ]]; then
  export RUSTADMIN_LINUX_CODEC_ROOT="$deps_root"
  export RUSTDESK_LINUX_CODEC_ROOT="$deps_root"
else
  unset RUSTADMIN_LINUX_CODEC_ROOT || true
  unset RUSTDESK_LINUX_CODEC_ROOT || true
fi
if [[ -n "$codec_link_mode" ]]; then
  export RUSTADMIN_LINUX_CODEC_LINK_MODE="$codec_link_mode"
  export RUSTDESK_LINUX_CODEC_LINK_MODE="$codec_link_mode"
else
  unset RUSTADMIN_LINUX_CODEC_LINK_MODE || true
  unset RUSTDESK_LINUX_CODEC_LINK_MODE || true
fi

if [[ -z "$bridge_llvm_path" ]]; then
  for llvm_config in llvm-config llvm-config-20 llvm-config-19 llvm-config-18 llvm-config-17 llvm-config-16 llvm-config-15 llvm-config-14 llvm-config-13 llvm-config-12 llvm-config-11 llvm-config-10 llvm-config-9; do
    if command -v "$llvm_config" >/dev/null 2>&1; then
      bridge_llvm_path="$("$llvm_config" --prefix 2>/dev/null || true)"
      if [[ -n "$bridge_llvm_path" ]]; then
        break
      fi
    fi
  done
fi
user_pkg_config_path="${PKG_CONFIG_PATH:-}"
system_pkg_config_path=""
if command -v pkg-config >/dev/null 2>&1; then
  system_pkg_config_path="$(pkg-config --variable pc_path pkg-config 2>/dev/null || true)"
fi
unset PKG_CONFIG_PATH || true
append_pkg_config_path "$repo_root/pkgconfig"
append_pkg_config_path "$system_pkg_config_path"
if [[ -n "$deps_root" && -d "$deps_root/lib/pkgconfig" ]]; then
  append_pkg_config_path "$deps_root/lib/pkgconfig"
fi
append_pkg_config_path "$user_pkg_config_path"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter was not found." >&2
  echo "Set RUSTADMIN_FLUTTER_ROOT or put flutter in PATH." >&2
  exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
  echo "zip was not found. Install it with: sudo apt install zip" >&2
  exit 1
fi
if [[ "$package_mode" == "deb" || "$package_mode" == "all" ]] &&
   ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb was not found. Install it with: sudo apt install dpkg-dev" >&2
  exit 1
fi
if ! command -v pkg-config >/dev/null 2>&1; then
  echo "pkg-config was not found." >&2
  echo "Install Linux build dependencies, for example:" >&2
  echo "  Debian/Ubuntu: sudo apt install pkg-config libgtk-3-dev" >&2
  echo "  Fedora/RHEL:   sudo dnf install pkgconf-pkg-config gtk3-devel" >&2
  echo "  Arch:          sudo pacman -S pkgconf gtk3" >&2
  exit 1
fi
if ! pkg-config --exists 'gdk-3.0 >= 3.22'; then
  echo "GTK 3 development metadata was not found by pkg-config." >&2
  echo "The Rust crate gdk-sys needs gdk-3.0.pc from the GTK 3 development package." >&2
  echo "Install Linux build dependencies, for example:" >&2
  echo "  Debian/Ubuntu: sudo apt install libgtk-3-dev" >&2
  echo "  Fedora/RHEL:   sudo dnf install gtk3-devel" >&2
  echo "  Arch:          sudo pacman -S gtk3" >&2
  echo "Current PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:-<unset>}" >&2
  exit 1
fi
if [[ ! -f /usr/include/security/pam_appl.h ]]; then
  echo "PAM development headers were not found." >&2
  echo "The Rust crate pam-sys needs security/pam_appl.h from the PAM development package." >&2
  echo "Install Linux build dependencies, for example:" >&2
  echo "  Debian/Ubuntu: sudo apt install libpam0g-dev" >&2
  echo "  Fedora/RHEL:   sudo dnf install pam-devel" >&2
  echo "  Arch:          sudo pacman -S pam" >&2
  exit 1
fi

codec_dependency_available() {
  local pkg_name="$1"
  local header_path="$2"
  local static_lib="$3"
  local shared_lib="$4"

  if pkg-config --exists "$pkg_name"; then
    return 0
  fi
  if [[ -n "$deps_root" &&
        -f "$deps_root/include/$header_path" &&
        ( -f "$deps_root/lib/$static_lib" || -f "$deps_root/lib/$shared_lib" ) ]]; then
    return 0
  fi
  return 1
}

missing_codecs=()
codec_dependency_available "libyuv" "libyuv/convert.h" "libyuv.a" "libyuv.so" || missing_codecs+=("libyuv")
codec_dependency_available "vpx" "vpx/vpx_encoder.h" "libvpx.a" "libvpx.so" || missing_codecs+=("libvpx")
codec_dependency_available "aom" "aom/aom.h" "libaom.a" "libaom.so" || missing_codecs+=("aom")
codec_dependency_available "opus" "opus/opus_multistream.h" "libopus.a" "libopus.so" || missing_codecs+=("opus")
if [[ "${#missing_codecs[@]}" -gt 0 ]]; then
  echo "Codec development dependencies were not found: ${missing_codecs[*]}" >&2
  echo "Install distro packages such as libyuv-dev libvpx-dev libaom-dev libopus-dev," >&2
  echo "or set RUSTADMIN_LINUX_CODEC_ROOT to a prefix with include/ and lib/." >&2
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

generate_bridge_files() {
  if [[ "$skip_bridge_gen" == "1" ]]; then
    echo "Skipping flutter_rust_bridge generation because RUSTADMIN_SKIP_BRIDGE_GEN=1."
    return
  fi

  local bridge_input="$repo_root/src/flutter_ffi.rs"
  local bridge_outputs=(
    "$flutter_dir/lib/generated_bridge.dart"
    "$flutter_dir/lib/generated_bridge.freezed.dart"
    "$repo_root/src/bridge_generated.rs"
    "$repo_root/src/bridge_generated.io.rs"
  )
  if [[ "$force_bridge_gen" != "1" ]]; then
    local current=1
    local output
    for output in "${bridge_outputs[@]}"; do
      if [[ ! -f "$output" || "$output" -ot "$bridge_input" ]]; then
        current=0
        break
      fi
    done
    if [[ "$current" == "1" ]] &&
       ! grep -Fq "abstract class $bridge_class_name" "$flutter_dir/lib/generated_bridge.dart"; then
      current=0
    fi
    if [[ "$current" == "1" ]]; then
      echo "flutter_rust_bridge files are current."
      return
    fi
  fi

  local bridge_codegen
  bridge_codegen="$(command -v flutter_rust_bridge_codegen || true)"
  if [[ -z "$bridge_codegen" &&
        -n "${HOME:-}" &&
        -x "$HOME/.cargo/bin/flutter_rust_bridge_codegen" ]]; then
    bridge_codegen="$HOME/.cargo/bin/flutter_rust_bridge_codegen"
  fi
  if [[ -z "$bridge_codegen" ]]; then
    cat >&2 <<'EOF'
flutter_rust_bridge_codegen was not found.
Install it with:
  cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid
or set RUSTADMIN_SKIP_BRIDGE_GEN=1 if the generated files are already current.
EOF
    exit 1
  fi

  echo "Generating flutter_rust_bridge files..."
  local bridge_log
  bridge_log="$(mktemp "${TMPDIR:-/tmp}/rustadmin-bridge-gen.log.XXXXXX")"
  local -a bridge_codegen_args
  bridge_codegen_args=(
    --rust-input "$bridge_input" \
    --dart-output "$flutter_dir/lib/generated_bridge.dart" \
    --class-name "$bridge_class_name"
  )
  if [[ -n "$bridge_llvm_path" ]]; then
    bridge_codegen_args+=(--llvm-path "$bridge_llvm_path")
  fi
  if [[ -n "$bridge_llvm_compiler_opts" ]]; then
    bridge_codegen_args+=(--llvm-compiler-opts="$bridge_llvm_compiler_opts")
  fi
  if "$bridge_codegen" "${bridge_codegen_args[@]}" >"$bridge_log" 2>&1; then
    if [[ "$verbose_bridge_gen" == "1" ]]; then
      cat "$bridge_log"
    fi
    rm -f "$bridge_log"
  else
    cat "$bridge_log" >&2
    rm -f "$bridge_log"
    exit 1
  fi
}

sync_cargo_artifacts_for_flutter() {
  local cargo_target_dir_abs
  local repo_target_dir="$repo_root/target"
  local repo_target_dir_abs

  mkdir -p "$CARGO_TARGET_DIR" "$repo_target_dir"
  cargo_target_dir_abs="$(cd "$CARGO_TARGET_DIR" && pwd -P)"
  repo_target_dir_abs="$(cd "$repo_target_dir" && pwd -P)"
  if [[ "$cargo_target_dir_abs" == "$repo_target_dir_abs" ]]; then
    return
  fi

  local source_dir="$cargo_target_dir_abs/release"
  local dest_dir="$repo_target_dir_abs/release"
  local lib_name="liblibrustdesk.so"
  if [[ ! -f "$source_dir/$lib_name" ]]; then
    echo "Rust library was not found at $source_dir/$lib_name" >&2
    exit 1
  fi
  mkdir -p "$dest_dir"
  cp -f "$source_dir/$lib_name" "$dest_dir/$lib_name"
}

package_release_zip() {
  local bundle_dir="$flutter_dir/build/linux/x64/release/bundle"
  local dist_dir="${RUSTADMIN_LINUX_DIST_DIR:-$repo_root/dist/linux}"
  local archive_path="$dist_dir/$archive_name"
  local zip_source_dir="$bundle_dir"
  local zip_stage=""

  if [[ ! -d "$bundle_dir" ]]; then
    echo "Linux bundle was not found at $bundle_dir" >&2
    exit 1
  fi

  mkdir -p "$dist_dir"
  rm -f "$archive_path"
  if [[ -f "$bundle_dir/rustdesk" && ! -f "$bundle_dir/rustadmin" ]]; then
    zip_stage="$(mktemp -d "${TMPDIR:-/tmp}/rustadmin-zip-stage.XXXXXX")"
    cp -a "$bundle_dir/." "$zip_stage/"
    mv "$zip_stage/rustdesk" "$zip_stage/rustadmin"
    zip_source_dir="$zip_stage"
  fi
  (cd "$zip_source_dir" && zip -qr "$archive_path" .)
  if [[ -n "$zip_stage" ]]; then
    rm -rf "$zip_stage"
  fi

  echo "Linux archive:"
  echo "$archive_path"
}

package_release_deb() {
  local bundle_dir="$flutter_dir/build/linux/x64/release/bundle"
  local dist_dir="${RUSTADMIN_LINUX_DIST_DIR:-$repo_root/dist/linux}"
  local deb_version="${version}.${revision}"

  if [[ ! -d "$bundle_dir" ]]; then
    echo "Linux bundle was not found at $bundle_dir" >&2
    exit 1
  fi

  local -a python_cmd
  if command -v uv >/dev/null 2>&1; then
    python_cmd=(uv run python3)
  else
    python_cmd=(python3)
  fi
  if ! command -v "${python_cmd[0]}" >/dev/null 2>&1; then
    echo "Python was not found. Install python3 or uv." >&2
    exit 1
  fi

  "${python_cmd[@]}" "$repo_root/scripts/package_linux.py" deb \
    --repo-root "$repo_root" \
    --bundle "$bundle_dir" \
    --output "$dist_dir" \
    --version "$deb_version"
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

generate_bridge_files

features="flutter linux-pkg-config"
if [[ "$hwcodec" -eq 1 ]]; then
  features="$features hwcodec"
fi

if [[ "$skip_cargo" -eq 0 ]]; then
  generate_version_file
  (cd "$repo_root" && cargo build --features "$features" --lib --release)
  sync_cargo_artifacts_for_flutter
fi

(cd "$flutter_dir" && flutter build linux --release)

echo "Linux bundle:"
bundle_dir="$flutter_dir/build/linux/x64/release/bundle"
echo "$bundle_dir"
case "$package_mode" in
  zip)
    package_release_zip
    ;;
  deb)
    package_release_deb
    ;;
  all)
    package_release_zip
    package_release_deb
    ;;
esac
