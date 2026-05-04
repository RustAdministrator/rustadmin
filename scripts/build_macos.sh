#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build_macos.sh [--clean] [--hwcodec] [--screencapturekit] [--skip-cargo]

Environment overrides:
  RUSTDESK_FLUTTER_ROOT       Flutter SDK root. Default: first flutter in PATH
  RUSTDESK_MACOS_CODEC_ROOT   Native dependency prefix. Optional
  RUSTDESK_MACOS_SIGN_IDENTITY  Signing identity to use for the app bundle. Optional
  RUSTDESK_MACOS_XCODE_SIGN_IDENTITY Signing identity passed to Xcode. Optional
  RUSTDESK_MACOS_DEVELOPMENT_TEAM Development team to pass to Xcode. Optional
  RUSTDESK_MACOS_ADHOC_SIGN   Set to 1 to force ad-hoc signing fallback. Default: 0
  PUB_CACHE                   Dart package cache. Default: $HOME/.pub-cache-rustdesk-macos
  CARGO_TARGET_DIR            Cargo output dir. Default: ../rustdesk-target-macos
USAGE
}

clean=0
hwcodec=0
screencapturekit=0
skip_cargo=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) clean=1 ;;
    --hwcodec) hwcodec=1 ;;
    --screencapturekit) screencapturekit=1 ;;
    --skip-cargo) skip_cargo=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_dir="$repo_root/flutter"
default_codec_root="$repo_root/.local/macos-codecs"
app_bundle="$flutter_dir/build/macos/Build/Products/Release/RustDesk.app"
adhoc_sign="${RUSTDESK_MACOS_ADHOC_SIGN:-0}"

if [[ -n "${RUSTDESK_FLUTTER_ROOT:-}" ]]; then
  export PATH="$RUSTDESK_FLUTTER_ROOT/bin:$PATH"
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter was not found. Set RUSTDESK_FLUTTER_ROOT or put flutter in PATH." >&2
  exit 1
fi

export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache-rustdesk-macos}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(cd "$repo_root/.." && pwd)/rustdesk-target-macos}"

if [[ -z "${RUSTDESK_MACOS_CODEC_ROOT:-}" ]]; then
  if [[ -d "$default_codec_root" ]]; then
    export RUSTDESK_MACOS_CODEC_ROOT="$default_codec_root"
  elif [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
    export RUSTDESK_MACOS_CODEC_ROOT="${CMAKE_PREFIX_PATH%%:*}"
  fi
fi

if [[ -n "${RUSTDESK_MACOS_CODEC_ROOT:-}" ]]; then
  echo "Using macOS codec root: $RUSTDESK_MACOS_CODEC_ROOT"
  export CMAKE_PREFIX_PATH="$RUSTDESK_MACOS_CODEC_ROOT:${CMAKE_PREFIX_PATH:-}"
  export PKG_CONFIG_PATH="$RUSTDESK_MACOS_CODEC_ROOT/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

mkdir -p "$PUB_CACHE" "$CARGO_TARGET_DIR"

package_config="$flutter_dir/.dart_tool/package_config.json"
if [[ "$clean" -eq 1 ]] ||
   [[ ! -f "$package_config" ]] ||
   grep -Eq 'file:///mnt/|file:///home/|flutter-win|\\' "$package_config" 2>/dev/null; then
  echo "Refreshing macOS Flutter metadata..."
  rm -rf "$flutter_dir/.dart_tool" "$flutter_dir/.flutter-plugins-dependencies" "$flutter_dir/build/macos"
fi

(cd "$flutter_dir" && flutter pub get)

features="flutter"
if [[ "$hwcodec" -eq 1 ]]; then
  features="$features hwcodec"
fi
if [[ "$screencapturekit" -eq 1 ]]; then
  features="$features screencapturekit"
fi

if [[ "$skip_cargo" -eq 0 ]]; then
  (cd "$repo_root" && MACOSX_DEPLOYMENT_TARGET=10.15 cargo build --features "$features" --lib --release)
fi

release_entitlements="$flutter_dir/macos/Runner/Release.entitlements"
if [[ "$adhoc_sign" == "1" ]]; then
  release_entitlements="$flutter_dir/macos/Runner/ReleaseAdhoc.entitlements"
fi

xcode_sign_identity="${RUSTDESK_MACOS_XCODE_SIGN_IDENTITY:-}"
if [[ -z "$xcode_sign_identity" && -n "${RUSTDESK_MACOS_SIGN_IDENTITY:-}" ]]; then
  case "$RUSTDESK_MACOS_SIGN_IDENTITY" in
    "Apple Development:"*) xcode_sign_identity="Apple Development" ;;
    "Developer ID Application:"*) xcode_sign_identity="Developer ID Application" ;;
    "Mac Developer:"*) xcode_sign_identity="Mac Developer" ;;
    *) xcode_sign_identity="$RUSTDESK_MACOS_SIGN_IDENTITY" ;;
  esac
fi

host_arch="$(uname -m)"
if [[ "$host_arch" == "arm64" || "$host_arch" == "x86_64" ]]; then
  (
    cd "$flutter_dir"
    flutter build macos --release --config-only
    xcodebuild_args=(
      -workspace macos/Runner.xcworkspace
      -scheme Runner
      -configuration Release
      -derivedDataPath build/macos
      -destination "platform=macOS,arch=$host_arch"
    )
    if [[ -n "${RUSTDESK_MACOS_DEVELOPMENT_TEAM:-}" ]]; then
      xcodebuild_args+=("DEVELOPMENT_TEAM=$RUSTDESK_MACOS_DEVELOPMENT_TEAM")
    fi
    if [[ "$adhoc_sign" != "1" && -n "${RUSTDESK_MACOS_SIGN_IDENTITY:-}" ]]; then
      xcodebuild_args+=("CODE_SIGNING_ALLOWED=NO")
    elif [[ -n "$xcode_sign_identity" ]]; then
      xcodebuild_args+=("CODE_SIGN_IDENTITY=$xcode_sign_identity")
    fi
    xcodebuild "${xcodebuild_args[@]}" build
  )
else
  (cd "$flutter_dir" && flutter build macos --release)
fi

if [[ -f "$repo_root/target/release/service" ]]; then
  cp -f "$repo_root/target/release/service" \
    "$app_bundle/Contents/MacOS/"
fi

if [[ "$adhoc_sign" == "1" ]]; then
  sign_identity="-"
else
  sign_identity="${RUSTDESK_MACOS_SIGN_IDENTITY:-}"
  if [[ -z "$sign_identity" ]]; then
    sign_identity="$(codesign -dv "$app_bundle" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  fi
  if [[ -z "$sign_identity" ]]; then
    cat >&2 <<EOF
Unable to determine a valid signing identity for $app_bundle.
Set RUSTDESK_MACOS_SIGN_IDENTITY and optionally RUSTDESK_MACOS_DEVELOPMENT_TEAM,
or set RUSTDESK_MACOS_ADHOC_SIGN=1 to use the local ad-hoc signing fallback.
EOF
    exit 1
  fi
fi

codesign --force --deep --sign "$sign_identity" --options runtime \
  --entitlements "$release_entitlements" \
  "$app_bundle"

echo "macOS bundle:"
echo "$flutter_dir/build/macos/Build/Products/Release"
