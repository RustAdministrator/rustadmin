#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/package_macos.sh [options]

Packages the built macOS RustAdmin.app into a DMG, signs the staged app and DMG,
and notarizes it unless SKIP_NOTARY=1 is set.

Environment:
  APP                  App bundle to package.
                       Default: flutter/build/macos/Build/Products/Release/RustAdmin.app
  APP_NAME             App name inside the DMG. Default: RustAdmin
  DIST_DIR             Output directory. Default: dist/macos
  DMG                  Output DMG path. Default: $DIST_DIR/rustadmin-$VERSION-macos-$ARCH.dmg
  VERSION              Version string for the default DMG name.
                       Default: Cargo.toml package version
  VOLUME_NAME          Mounted DMG volume name. Default: "$APP_NAME Installer"
  SIGN_IDENTITY        Developer ID Application identity or SHA-1 hash.
                       Also accepts RUSTADMIN_MACOS_DMG_SIGN_IDENTITY or
                       RUSTADMIN_MACOS_SIGN_IDENTITY.
                       Legacy RUSTDESK_* names are accepted as fallbacks.
                       Use "-" for local ad-hoc signing with SKIP_NOTARY=1.
  APP_ENTITLEMENTS     Entitlements used when signing the app bundle.
                       Default: flutter/macos/Runner/Release.entitlements,
                       or ReleaseAdhoc.entitlements for SIGN_IDENTITY="-".
  SKIP_NOTARY          Set to 1 to skip notarization. Default: 0
  SKIP_DMG             Set to 1 to stop after creating a signed app bundle in
                       $DIST_DIR/$APP_NAME.app. Default: 0
  NOTARY_PROFILE       Existing xcrun notarytool keychain profile. Optional.
                       Also accepts RUSTADMIN_NOTARY_PROFILE.
  NOTARY_APPLE_ID      Apple ID for notarytool portable auth. Optional.
                       Also accepts RUSTADMIN_NOTARY_APPLE_ID.
  NOTARY_TEAM_ID       Developer Team ID for notarytool portable auth. Optional.
                       Also accepts RUSTADMIN_NOTARY_TEAM_ID.
  NOTARY_PASSWORD      App-specific password. Optional.
                       Also accepts RUSTADMIN_NOTARY_PASSWORD.
                       If omitted with NOTARY_APPLE_ID and NOTARY_TEAM_ID,
                       notarytool prompts securely.

Options override environment:
  --app PATH
  --dmg PATH
  --volume-name NAME
  --sign-identity ID
  --notarize
  --skip-notary
  --notary-profile NAME
  --apple-id EMAIL
  --team-id TEAM_ID
  --notary-password PASSWORD
  --no-staple
  --skip-sign
  --skip-app-verify
  --skip-dmg
  -h, --help

Examples:
  SKIP_NOTARY=1 \
  SIGN_IDENTITY="Developer ID Application: Vladlen Erium (9UU755KL6F)" \
  scripts/package_macos.sh

  SIGN_IDENTITY="Developer ID Application: Vladlen Erium (9UU755KL6F)" \
  NOTARY_PROFILE="rustadmin-notary" \
  scripts/package_macos.sh

  SIGN_IDENTITY="Developer ID Application: Vladlen Erium (9UU755KL6F)" \
  NOTARY_APPLE_ID="developer@example.com" \
  NOTARY_TEAM_ID="TEAMID" \
  scripts/package_macos.sh

The script does not store notarization credentials. NOTARY_PROFILE uses an
existing keychain profile if you created one separately. The Apple ID mode can
prompt for the app-specific password without storing it.
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

read_version() {
  sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$repo_root/Cargo.toml" | head -n 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch="$(uname -m)"

APP_NAME="${APP_NAME:-RustAdmin}"
APP="${APP:-$repo_root/flutter/build/macos/Build/Products/Release/$APP_NAME.app}"
DIST_DIR="${DIST_DIR:-$repo_root/dist/macos}"
VERSION="${VERSION:-$(read_version)}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME Installer}"
SIGN_IDENTITY="${SIGN_IDENTITY:-${RUSTADMIN_MACOS_DMG_SIGN_IDENTITY:-${RUSTADMIN_MACOS_SIGN_IDENTITY:-${RUSTDESK_MACOS_DMG_SIGN_IDENTITY:-${RUSTDESK_MACOS_SIGN_IDENTITY:-}}}}}"
APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-}"
SKIP_NOTARY="${SKIP_NOTARY:-0}"
SKIP_DMG="${SKIP_DMG:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-${RUSTADMIN_NOTARY_PROFILE:-${RUSTDESK_NOTARY_PROFILE:-}}}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-${RUSTADMIN_NOTARY_APPLE_ID:-${RUSTDESK_NOTARY_APPLE_ID:-}}}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-${RUSTADMIN_NOTARY_TEAM_ID:-${RUSTDESK_NOTARY_TEAM_ID:-}}}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-${RUSTADMIN_NOTARY_PASSWORD:-${RUSTDESK_NOTARY_PASSWORD:-}}}"
DMG="${DMG:-}"
skip_sign=0
skip_app_verify=0
staple=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "--app requires a path" >&2; exit 2; }
      APP="$2"
      shift
      ;;
    --dmg)
      [[ $# -ge 2 ]] || { echo "--dmg requires a path" >&2; exit 2; }
      DMG="$2"
      shift
      ;;
    --volume-name)
      [[ $# -ge 2 ]] || { echo "--volume-name requires a value" >&2; exit 2; }
      VOLUME_NAME="$2"
      shift
      ;;
    --sign-identity)
      [[ $# -ge 2 ]] || { echo "--sign-identity requires a value" >&2; exit 2; }
      SIGN_IDENTITY="$2"
      shift
      ;;
    --notarize)
      SKIP_NOTARY=0
      ;;
    --skip-notary)
      SKIP_NOTARY=1
      ;;
    --notary-profile)
      [[ $# -ge 2 ]] || { echo "--notary-profile requires a value" >&2; exit 2; }
      NOTARY_PROFILE="$2"
      shift
      ;;
    --apple-id)
      [[ $# -ge 2 ]] || { echo "--apple-id requires a value" >&2; exit 2; }
      NOTARY_APPLE_ID="$2"
      shift
      ;;
    --team-id)
      [[ $# -ge 2 ]] || { echo "--team-id requires a value" >&2; exit 2; }
      NOTARY_TEAM_ID="$2"
      shift
      ;;
    --notary-password)
      [[ $# -ge 2 ]] || { echo "--notary-password requires a value" >&2; exit 2; }
      NOTARY_PASSWORD="$2"
      shift
      ;;
    --no-staple)
      staple=0
      ;;
    --skip-sign)
      skip_sign=1
      ;;
    --skip-app-verify)
      skip_app_verify=1
      ;;
    --skip-dmg)
      SKIP_DMG=1
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

if [[ "$SKIP_DMG" == "1" ]]; then
  SKIP_NOTARY=1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS packaging must run on macOS." >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "Could not read RustAdmin package version from Cargo.toml." >&2
  exit 1
fi

if [[ -z "$DMG" ]]; then
  DMG="$DIST_DIR/rustadmin-$VERSION-macos-$arch.dmg"
fi

require_cmd codesign
require_cmd ditto
require_cmd file
require_cmd install_name_tool
require_cmd otool
if [[ "${SKIP_DMG:-0}" != "1" ]]; then
  require_cmd hdiutil
fi
if [[ "${SKIP_DMG:-0}" != "1" && "$SKIP_NOTARY" != "1" ]]; then
  require_cmd xcrun
  require_cmd spctl
fi

if [[ ! -d "$APP" ]]; then
  echo "App bundle does not exist: $APP" >&2
  echo "Build it first with scripts/build_macos.sh." >&2
  exit 1
fi

if [[ "$skip_sign" -eq 0 && -z "$SIGN_IDENTITY" ]]; then
  echo "SIGN_IDENTITY is required." >&2
  echo "Example: SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" $0" >&2
  exit 1
fi

if [[ "$skip_sign" -eq 0 && "$SIGN_IDENTITY" == "-" && "$SKIP_NOTARY" != "1" ]]; then
  echo "Ad-hoc signing cannot be notarized. Set SKIP_NOTARY=1 or use a Developer ID identity." >&2
  exit 1
fi

if [[ "$SKIP_NOTARY" != "1" && -z "$NOTARY_PROFILE" &&
      ( -z "$NOTARY_APPLE_ID" || -z "$NOTARY_TEAM_ID" ) ]]; then
  cat >&2 <<'EOF'
NOTARY_PROFILE is required unless SKIP_NOTARY=1.

Portable alternative without storing credentials:
  NOTARY_APPLE_ID=developer@example.com NOTARY_TEAM_ID=TEAMID scripts/package_macos.sh

If NOTARY_PASSWORD is omitted, xcrun notarytool prompts for the app-specific
password without storing it.
EOF
  exit 1
fi

APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
if [[ "$skip_sign" -eq 0 && -z "$APP_ENTITLEMENTS" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    APP_ENTITLEMENTS="$repo_root/flutter/macos/Runner/ReleaseAdhoc.entitlements"
  else
    APP_ENTITLEMENTS="$repo_root/flutter/macos/Runner/Release.entitlements"
  fi
fi
if [[ "$skip_sign" -eq 0 && ! -f "$APP_ENTITLEMENTS" ]]; then
  echo "App entitlements file does not exist: $APP_ENTITLEMENTS" >&2
  exit 1
fi
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
DMG_DIR="$(dirname "$DMG")"
mkdir -p "$DMG_DIR"
DMG="$(cd "$DMG_DIR" && pwd)/$(basename "$DMG")"

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustadmin-dmg-stage.XXXXXX")"
cleanup() {
  rm -rf "$stage_dir"
}
trap cleanup EXIT

codesign_code() {
  local path="$1"
  local -a codesign_args=(
    --force
    --sign "$SIGN_IDENTITY"
    --options runtime
  )

  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign_args+=(--timestamp)
  fi

  echo "Signing: $path"
  codesign "${codesign_args[@]}" "$path"
}

codesign_app_bundle() {
  local -a codesign_args=(
    --force
    --sign "$SIGN_IDENTITY"
    --options runtime
  )

  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign_args+=(--timestamp)
  fi

  codesign_args+=(--entitlements "$APP_ENTITLEMENTS")

  echo "Signing app bundle: $APP"
  codesign "${codesign_args[@]}" "$APP"
}

sign_app_contents() {
  local main_executable_name
  local main_executable
  local path

  main_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
  main_executable="$APP/Contents/MacOS/$main_executable_name"

  while IFS= read -r -d '' path; do
    codesign_code "$path"
  done < <(find "$APP/Contents" -type f \
    \( -name "*.dylib" -o -name "*.so" \) -print0)

  if [[ -d "$APP/Contents/MacOS" ]]; then
    while IFS= read -r -d '' path; do
      if [[ -n "$main_executable_name" && "$path" == "$main_executable" ]]; then
        continue
      fi
      if [[ -x "$path" ]]; then
        codesign_code "$path"
      fi
    done < <(find "$APP/Contents/MacOS" -maxdepth 1 -type f -print0)
  fi

  while IFS= read -r -d '' path; do
    codesign_code "$path"
  done < <(find "$APP/Contents" -depth -type d \
    \( -name "*.app" -o -name "*.appex" -o -name "*.bundle" -o \
       -name "*.framework" -o -name "*.systemextension" -o -name "*.xpc" \) \
    -print0)

  codesign_app_bundle
}

collect_macho_files() {
  local root="$1"
  local candidate

  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" 2>/dev/null | grep -q 'Mach-O'; then
      printf '%s\n' "$candidate"
    fi
  done < <(find "$root" -type f -print0)
}

otool_dependencies() {
  otool -L "$1" 2>/dev/null | sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p'
}

is_system_library() {
  case "$1" in
    /System/Library/*|/usr/lib/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_external_absolute_library() {
  local dep="$1"
  [[ "$dep" == /* ]] || return 1
  is_system_library "$dep" && return 1
  case "$dep" in
    "$APP"/*) return 1 ;;
  esac
  return 0
}

bundle_external_library() {
  local dep="$1"
  local base
  local dest

  if [[ "$dep" == *".framework/"* ]]; then
    echo "External framework dependency is not supported for automatic bundling: $dep" >&2
    exit 1
  fi
  if [[ ! -f "$dep" ]]; then
    echo "Missing mandatory external library: $dep" >&2
    exit 1
  fi

  base="$(basename "$dep")"
  dest="$APP/Contents/Frameworks/$base"
  bundled_library_dest="$dest"

  if [[ ! -f "$dest" ]]; then
    echo "Bundling external dylib: $dep -> $dest"
    mkdir -p "$APP/Contents/Frameworks"
    ditto --noextattr --noacl "$dep" "$dest"
    chmod u+w "$dest" 2>/dev/null || true
    copied_external_lib=1
  fi

  install_name_tool -id "@executable_path/../Frameworks/$base" "$dest" 2>/dev/null || true
}

rewrite_external_dependencies() {
  local binary="$1"
  local dep
  local base

  while IFS= read -r dep; do
    if is_external_absolute_library "$dep"; then
      bundle_external_library "$dep"
      base="$(basename "$bundled_library_dest")"
      echo "Rewriting dependency in $binary: $dep -> @executable_path/../Frameworks/$base"
      install_name_tool -change "$dep" "@executable_path/../Frameworks/$base" "$binary"
    fi
  done < <(otool_dependencies "$binary")
}

dependency_resolves_in_app() {
  local binary="$1"
  local dep="$2"
  local rel
  local candidate
  local loader_dir

  case "$dep" in
    @executable_path/*)
      rel="${dep#@executable_path/}"
      [[ -e "$APP/Contents/MacOS/$rel" ]]
      ;;
    @loader_path/*)
      rel="${dep#@loader_path/}"
      loader_dir="$(cd "$(dirname "$binary")" && pwd)"
      [[ -e "$loader_dir/$rel" ]]
      ;;
    @rpath/*)
      rel="${dep#@rpath/}"
      for candidate in \
        "$APP/Contents/Frameworks/$rel" \
        "$APP/Contents/MacOS/$rel" \
        "$APP/Contents/Resources/$rel"; do
        [[ -e "$candidate" ]] && return 0
      done
      return 1
      ;;
    @*)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

verify_mandatory_libraries() {
  local binary
  local dep
  local missing=0

  while IFS= read -r binary; do
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      if is_system_library "$dep"; then
        continue
      fi
      if is_external_absolute_library "$dep"; then
        echo "Unbundled external dependency in $binary: $dep" >&2
        missing=1
        continue
      fi
      if [[ "$dep" == "$APP"/* ]]; then
        [[ -e "$dep" ]] || {
          echo "Missing app-local dependency in $binary: $dep" >&2
          missing=1
        }
        continue
      fi
      if [[ "$dep" == @* ]]; then
        dependency_resolves_in_app "$binary" "$dep" || {
          echo "Unresolved bundled dependency in $binary: $dep" >&2
          missing=1
        }
        continue
      fi
      echo "Unsupported relative dependency in $binary: $dep" >&2
      missing=1
    done < <(otool_dependencies "$binary")
  done < <(collect_macho_files "$APP/Contents")

  if [[ "$missing" -ne 0 ]]; then
    echo "Mandatory library verification failed." >&2
    exit 1
  fi
}

bundle_mandatory_libraries() {
  local binary
  local pass=0
  local bundled_library_dest=""
  local copied_external_lib=1

  while [[ "$copied_external_lib" -eq 1 ]]; do
    copied_external_lib=0
    pass=$((pass + 1))
    if [[ "$pass" -gt 20 ]]; then
      echo "Too many dependency bundling passes; refusing to continue." >&2
      exit 1
    fi

    while IFS= read -r binary; do
      rewrite_external_dependencies "$binary"
    done < <(collect_macho_files "$APP/Contents")
  done

  verify_mandatory_libraries
}

source_app="$APP"
APP="$stage_dir/$APP_NAME.app"

echo "Staging app bundle: $source_app -> $APP"
ditto --noextattr --noacl "$source_app" "$APP"

bundle_mandatory_libraries

if [[ "$skip_sign" -eq 0 ]]; then
  sign_app_contents
elif [[ "$skip_app_verify" -eq 0 ]]; then
  echo "WARNING: --skip-sign leaves any install_name_tool changes unsigned." >&2
fi

if [[ "$skip_app_verify" -eq 0 ]]; then
  echo "Verifying staged app bundle: $APP"
  codesign --verify --deep --strict --verbose=4 "$APP"
  codesign -dv --verbose=4 "$APP"
  verify_mandatory_libraries
fi

if [[ "$SKIP_DMG" == "1" ]]; then
  output_app="$DIST_DIR/$APP_NAME.app"
  echo "Writing signed app bundle: $output_app"
  rm -rf "$output_app"
  ditto --noextattr --noacl "$APP" "$output_app"
  if [[ "$skip_app_verify" -eq 0 ]]; then
    codesign --verify --deep --strict --verbose=4 "$output_app"
  fi
  echo "Created: $output_app"
  exit 0
fi

ln -s /Applications "$stage_dir/Applications"

echo "Creating DMG: $DMG"
echo "Volume name: $VOLUME_NAME"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$stage_dir" \
  -ov \
  -format UDZO \
  "$DMG"

if [[ "$skip_sign" -eq 0 ]]; then
  dmg_codesign_args=(--force --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    dmg_codesign_args+=(--timestamp)
  fi

  echo "Signing DMG with identity: $SIGN_IDENTITY"
  codesign "${dmg_codesign_args[@]}" "$DMG"
  codesign --verify --verbose=4 "$DMG"
fi

if [[ "$SKIP_NOTARY" != "1" ]]; then
  notary_args=(notarytool submit "$DMG" --wait)
  if [[ -n "$NOTARY_PROFILE" ]]; then
    notary_args+=(--keychain-profile "$NOTARY_PROFILE")
  else
    notary_args+=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID")
    if [[ -n "$NOTARY_PASSWORD" ]]; then
      notary_args+=(--password "$NOTARY_PASSWORD")
    fi
  fi

  echo "Submitting DMG for notarization..."
  xcrun "${notary_args[@]}"

  if [[ "$staple" -eq 1 ]]; then
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -vvv -t open --context context:primary-signature "$DMG"
  fi
else
  echo "Skipping notarization because SKIP_NOTARY=1."
fi

echo "Created: $DMG"
