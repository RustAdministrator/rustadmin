#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build_macos.sh [--clean] [--hwcodec] [--screencapturekit] [--skip-cargo] [--sign-only]

Environment overrides:
  RUSTADMIN_FLUTTER_ROOT       Flutter SDK root. Default: first flutter in PATH
  RUSTADMIN_SKIP_BRIDGE_GEN    Set to 1 to skip flutter_rust_bridge codegen. Default: 0
  RUSTADMIN_FORCE_BRIDGE_GEN   Set to 1 to regenerate bridge files even if current. Default: 0
  RUSTADMIN_VERBOSE_BRIDGE_GEN Set to 1 to print bridge generator output on success. Default: 0
  RUSTADMIN_BRIDGE_LLVM_COMPILER_OPTS
                              Extra clang opts for bridge codegen.
                              Default: -Wno-nullability-completeness
  RUSTADMIN_MACOS_CODEC_ROOT   Native dependency prefix. Optional
  RUSTADMIN_MACOS_SIGN_IDENTITY  Signing identity to use for the app bundle. Optional
  RUSTADMIN_MACOS_XCODE_SIGN_IDENTITY Signing identity passed to Xcode. Optional
  RUSTADMIN_MACOS_DEVELOPMENT_TEAM Development team to pass to Xcode. Optional
  RUSTADMIN_MACOS_ADHOC_SIGN   Set to 1 to force ad-hoc signing fallback. Default: 0
  PUB_CACHE                    Dart package cache. Default: $HOME/.pub-cache-rustadmin-macos
  CARGO_TARGET_DIR             Cargo output dir. Default: ../rustadmin-target-macos
                              Synced to target/release for Xcode embedding.
Legacy RUSTDESK_* environment variable names are still accepted as fallbacks.
USAGE
}

clean=0
hwcodec=0
screencapturekit=0
skip_cargo=0
sign_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) clean=1 ;;
    --hwcodec) hwcodec=1 ;;
    --screencapturekit) screencapturekit=1 ;;
    --skip-cargo) skip_cargo=1 ;;
    --sign-only) sign_only=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_dir="$repo_root/flutter"
default_codec_root="$repo_root/.local/macos-codecs"
home_codec_root="$HOME/MO/Release"
app_bundle="$flutter_dir/build/macos/Build/Products/Release/RustAdmin.app"
adhoc_sign="${RUSTADMIN_MACOS_ADHOC_SIGN:-${RUSTDESK_MACOS_ADHOC_SIGN:-0}}"
skip_bridge_gen="${RUSTADMIN_SKIP_BRIDGE_GEN:-${RUSTDESK_SKIP_BRIDGE_GEN:-0}}"
force_bridge_gen="${RUSTADMIN_FORCE_BRIDGE_GEN:-${RUSTDESK_FORCE_BRIDGE_GEN:-0}}"
verbose_bridge_gen="${RUSTADMIN_VERBOSE_BRIDGE_GEN:-${RUSTDESK_VERBOSE_BRIDGE_GEN:-0}}"
bridge_class_name="Rustadmin"
bridge_llvm_compiler_opts="${RUSTADMIN_BRIDGE_LLVM_COMPILER_OPTS:-${RUSTDESK_BRIDGE_LLVM_COMPILER_OPTS:--Wno-nullability-completeness}}"
flutter_root="${RUSTADMIN_FLUTTER_ROOT:-${RUSTDESK_FLUTTER_ROOT:-}}"
macos_sign_identity="${RUSTADMIN_MACOS_SIGN_IDENTITY:-${RUSTDESK_MACOS_SIGN_IDENTITY:-}}"
macos_xcode_sign_identity="${RUSTADMIN_MACOS_XCODE_SIGN_IDENTITY:-${RUSTDESK_MACOS_XCODE_SIGN_IDENTITY:-}}"
macos_development_team="${RUSTADMIN_MACOS_DEVELOPMENT_TEAM:-${RUSTDESK_MACOS_DEVELOPMENT_TEAM:-}}"
macos_codec_root="${RUSTADMIN_MACOS_CODEC_ROOT:-${RUSTDESK_MACOS_CODEC_ROOT:-}}"

if [[ -n "$flutter_root" ]]; then
  export PATH="$flutter_root/bin:$PATH"
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter was not found. Set RUSTADMIN_FLUTTER_ROOT or put flutter in PATH." >&2
  exit 1
fi

export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache-rustadmin-macos}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(cd "$repo_root/.." && pwd)/rustadmin-target-macos}"
cargo_release_dir="$CARGO_TARGET_DIR/release"
xcode_rust_release_dir="$repo_root/target/release"
xcode_librustdesk="$xcode_rust_release_dir/liblibrustdesk.dylib"
xcode_service="$xcode_rust_release_dir/service"

if [[ -z "$macos_codec_root" ]]; then
  if [[ -d "$default_codec_root" ]]; then
    macos_codec_root="$default_codec_root"
  elif [[ -d "$home_codec_root/include" && -d "$home_codec_root/lib" ]]; then
    macos_codec_root="$home_codec_root"
  elif [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
    macos_codec_root="${CMAKE_PREFIX_PATH%%:*}"
  fi
fi

if [[ -n "$macos_codec_root" ]]; then
  echo "Using macOS codec root: $macos_codec_root"
  export RUSTADMIN_MACOS_CODEC_ROOT="$macos_codec_root"
  export RUSTDESK_MACOS_CODEC_ROOT="$macos_codec_root"
  export CMAKE_PREFIX_PATH="$macos_codec_root:${CMAKE_PREFIX_PATH:-}"
  export PKG_CONFIG_PATH="$macos_codec_root/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

mkdir -p "$PUB_CACHE" "$CARGO_TARGET_DIR"

sync_macos_rust_artifacts() {
  local cargo_librustdesk="$cargo_release_dir/liblibrustdesk.dylib"
  local cargo_service="$cargo_release_dir/service"

  if [[ ! -f "$cargo_librustdesk" ]]; then
    echo "Missing Rust library: $cargo_librustdesk" >&2
    echo "Run without --skip-cargo or set CARGO_TARGET_DIR to a directory containing a release build." >&2
    exit 1
  fi

  mkdir -p "$xcode_rust_release_dir"
  local cargo_release_real
  local xcode_release_real
  cargo_release_real="$(cd "$cargo_release_dir" && pwd -P)"
  xcode_release_real="$(cd "$xcode_rust_release_dir" && pwd -P)"
  if [[ "$cargo_release_real" != "$xcode_release_real" ]]; then
    echo "Syncing Rust library for Xcode: $cargo_librustdesk -> $xcode_librustdesk"
    cp -f "$cargo_librustdesk" "$xcode_librustdesk"
    if [[ -f "$cargo_service" ]]; then
      cp -f "$cargo_service" "$xcode_service"
    fi
  fi
}

clean_flutter_build_state() {
  local hooks_dir="$flutter_dir/.dart_tool/hooks_runner"
  local flutter_build_dir="$flutter_dir/.dart_tool/flutter_build"
  if [[ -d "$hooks_dir" ]]; then
    rm -rf "$hooks_dir"
  fi
  if [[ -d "$flutter_build_dir" ]]; then
    rm -rf "$flutter_build_dir"
  fi
}

codesign_code() {
  local path="$1"
  local -a codesign_args=(
    --force
    --sign "$sign_identity"
    --options runtime
  )

  if [[ "$sign_identity" != "-" ]]; then
    codesign_args+=(--timestamp)
  fi

  echo "Signing: $path"
  codesign "${codesign_args[@]}" "$path"
}

codesign_app_bundle() {
  local -a codesign_args=(
    --force
    --sign "$sign_identity"
    --options runtime
  )

  if [[ "$sign_identity" != "-" ]]; then
    codesign_args+=(--timestamp)
  fi

  codesign_args+=(--entitlements "$release_entitlements")

  echo "Signing app bundle: $app_bundle"
  codesign "${codesign_args[@]}" "$app_bundle"
}

sign_macos_app_contents() {
  local main_executable_name
  local main_executable
  local path

  main_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$app_bundle/Contents/Info.plist" 2>/dev/null || true)"
  main_executable="$app_bundle/Contents/MacOS/$main_executable_name"

  while IFS= read -r -d '' path; do
    codesign_code "$path"
  done < <(find "$app_bundle/Contents" -type f \
    \( -name "*.dylib" -o -name "*.so" \) -print0)

  if [[ -d "$app_bundle/Contents/MacOS" ]]; then
    while IFS= read -r -d '' path; do
      if [[ -n "$main_executable_name" && "$path" == "$main_executable" ]]; then
        continue
      fi
      if [[ -x "$path" ]]; then
        codesign_code "$path"
      fi
    done < <(find "$app_bundle/Contents/MacOS" -maxdepth 1 -type f -print0)
  fi

  while IFS= read -r -d '' path; do
    codesign_code "$path"
  done < <(find "$app_bundle/Contents" -depth -type d \
    \( -name "*.app" -o -name "*.appex" -o -name "*.bundle" -o \
       -name "*.framework" -o -name "*.systemextension" -o -name "*.xpc" \) \
    -print0)

  codesign_app_bundle
}

release_entitlements="$flutter_dir/macos/Runner/Release.entitlements"
if [[ "$adhoc_sign" == "1" ]]; then
  release_entitlements="$flutter_dir/macos/Runner/ReleaseAdhoc.entitlements"
fi

generate_version_file() {
  local version
  local revision
  local revision_file="$repo_root/rustadmin_revision.txt"
  local version_file="$repo_root/src/version.rs"

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
    "$flutter_dir/macos/Runner/bridge_generated.h"
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
  if [[ -z "$bridge_codegen" && -x "$HOME/.cargo/bin/flutter_rust_bridge_codegen" ]]; then
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
  bridge_log="$(mktemp "${TMPDIR:-/tmp}/rustdesk-bridge-gen.log.XXXXXX")"
  bridge_codegen_args=(
    --rust-input "$bridge_input" \
    --dart-output "$flutter_dir/lib/generated_bridge.dart" \
    --c-output "$flutter_dir/macos/Runner/bridge_generated.h" \
    --class-name "$bridge_class_name"
  )
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

if [[ "$sign_only" -eq 0 ]]; then
  package_config="$flutter_dir/.dart_tool/package_config.json"
  if [[ "$clean" -eq 1 ]] ||
     [[ ! -f "$package_config" ]] ||
     grep -Eq 'file:///([A-Z]:|[A-Za-z]%3A)|flutter-win|\\|file:///Users/|/Users/|file:///mnt/|file:///home/' "$package_config" 2>/dev/null; then
    echo "Refreshing macOS Flutter metadata..."
    rm -rf "$flutter_dir/.dart_tool" "$flutter_dir/.flutter-plugins-dependencies" "$flutter_dir/build/macos"
  fi

  (cd "$flutter_dir" && flutter pub get)

  generate_bridge_files

  features="flutter"
  if [[ "$hwcodec" -eq 1 ]]; then
    features="$features hwcodec"
  fi
  if [[ "$screencapturekit" -eq 1 ]]; then
    features="$features screencapturekit"
  fi

  if [[ "$skip_cargo" -eq 0 ]]; then
    generate_version_file
    (cd "$repo_root" && MACOSX_DEPLOYMENT_TARGET=10.15 cargo build --features "$features" --release -vv)
  fi

  sync_macos_rust_artifacts

  xcode_sign_identity="$macos_xcode_sign_identity"
  if [[ -z "$xcode_sign_identity" && -n "$macos_sign_identity" ]]; then
    case "$macos_sign_identity" in
      "Apple Development:"*) xcode_sign_identity="Apple Development" ;;
      "Developer ID Application:"*) xcode_sign_identity="Developer ID Application" ;;
      "Mac Developer:"*) xcode_sign_identity="Mac Developer" ;;
      *) xcode_sign_identity="$macos_sign_identity" ;;
    esac
  fi

  host_arch="$(uname -m)"
  clean_flutter_build_state
  if [[ "$host_arch" == "arm64" || "$host_arch" == "x86_64" ]]; then
    (
      cd "$flutter_dir"
      flutter build macos --release --config-only
      clean_flutter_build_state
      xcodebuild_args=(
        -workspace macos/Runner.xcworkspace
        -scheme Runner
        -configuration Release
        -derivedDataPath build/macos
        -destination "platform=macOS,arch=$host_arch"
        -jobs 1
        ARCHS="$host_arch"
        ONLY_ACTIVE_ARCH=YES
      )
      if [[ -n "$macos_development_team" ]]; then
        xcodebuild_args+=("DEVELOPMENT_TEAM=$macos_development_team")
      fi
      if [[ "$adhoc_sign" != "1" && -n "$macos_sign_identity" ]]; then
        xcodebuild_args+=("CODE_SIGNING_ALLOWED=NO")
      elif [[ -n "$xcode_sign_identity" ]]; then
        xcodebuild_args+=("CODE_SIGN_IDENTITY=$xcode_sign_identity")
      fi
      xcodebuild "${xcodebuild_args[@]}" build
    )
  else
    (cd "$flutter_dir" && flutter build macos --release)
  fi

  if [[ -f "$xcode_service" ]]; then
    cp -f "$xcode_service" \
      "$app_bundle/Contents/MacOS/"
  fi
fi

if [[ "$adhoc_sign" == "1" ]]; then
  sign_identity="-"
else
  sign_identity="$macos_sign_identity"
  if [[ -z "$sign_identity" ]]; then
    sign_identity="$(codesign -dv "$app_bundle" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  fi
  if [[ -z "$sign_identity" ]]; then
    cat >&2 <<EOF
Unable to determine a valid signing identity for $app_bundle.
Set RUSTADMIN_MACOS_SIGN_IDENTITY and optionally RUSTADMIN_MACOS_DEVELOPMENT_TEAM,
or set RUSTADMIN_MACOS_ADHOC_SIGN=1 to use the local ad-hoc signing fallback.
EOF
    exit 1
  fi
fi

if [[ ! -d "$app_bundle" ]]; then
  echo "App bundle does not exist: $app_bundle" >&2
  exit 1
fi

sign_macos_app_contents
codesign --verify --deep --strict --verbose=4 "$app_bundle"

echo "macOS bundle:"
echo "$flutter_dir/build/macos/Build/Products/Release"
