#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/package_macos.sh [options]

Packages the built macOS RustDesk.app into a DMG, signs the DMG, and notarizes
it unless SKIP_NOTARY=1 is set.

Environment:
  APP                  App bundle to package.
                       Default: flutter/build/macos/Build/Products/Release/RustDesk.app
  APP_NAME             App name inside the DMG. Default: RustDesk
  DIST_DIR             Output directory. Default: dist/macos
  DMG                  Output DMG path. Default: $DIST_DIR/rustdesk-$VERSION-macos-$ARCH.dmg
  VERSION              Version string for the default DMG name.
                       Default: Cargo.toml package version
  VOLUME_NAME          Mounted DMG volume name. Default: "$APP_NAME Installer"
  SIGN_IDENTITY        Developer ID Application identity or SHA-1 hash.
                       Also accepts RUSTDESK_MACOS_DMG_SIGN_IDENTITY or
                       RUSTDESK_MACOS_SIGN_IDENTITY.
  SKIP_NOTARY          Set to 1 to skip notarization. Default: 0
  NOTARY_PROFILE       Existing xcrun notarytool keychain profile. Optional.
                       Also accepts RUSTDESK_NOTARY_PROFILE.
  NOTARY_APPLE_ID      Apple ID for notarytool portable auth. Optional.
                       Also accepts RUSTDESK_NOTARY_APPLE_ID.
  NOTARY_TEAM_ID       Developer Team ID for notarytool portable auth. Optional.
                       Also accepts RUSTDESK_NOTARY_TEAM_ID.
  NOTARY_PASSWORD      App-specific password. Optional.
                       Also accepts RUSTDESK_NOTARY_PASSWORD.
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
  -h, --help

Examples:
  SKIP_NOTARY=1 \
  SIGN_IDENTITY="Developer ID Application: Vladlen Erium (9UU755KL6F)" \
  scripts/package_macos.sh

  SIGN_IDENTITY="Developer ID Application: Vladlen Erium (9UU755KL6F)" \
  NOTARY_PROFILE="rustdesk-notary" \
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

APP_NAME="${APP_NAME:-RustDesk}"
APP="${APP:-$repo_root/flutter/build/macos/Build/Products/Release/$APP_NAME.app}"
DIST_DIR="${DIST_DIR:-$repo_root/dist/macos}"
VERSION="${VERSION:-$(read_version)}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME Installer}"
SIGN_IDENTITY="${SIGN_IDENTITY:-${RUSTDESK_MACOS_DMG_SIGN_IDENTITY:-${RUSTDESK_MACOS_SIGN_IDENTITY:-}}}"
SKIP_NOTARY="${SKIP_NOTARY:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-${RUSTDESK_NOTARY_PROFILE:-}}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-${RUSTDESK_NOTARY_APPLE_ID:-}}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-${RUSTDESK_NOTARY_TEAM_ID:-}}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-${RUSTDESK_NOTARY_PASSWORD:-}}"
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS packaging must run on macOS." >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "Could not read RustDesk package version from Cargo.toml." >&2
  exit 1
fi

if [[ -z "$DMG" ]]; then
  DMG="$DIST_DIR/rustdesk-$VERSION-macos-$arch.dmg"
fi

require_cmd codesign
require_cmd ditto
require_cmd hdiutil
if [[ "$SKIP_NOTARY" != "1" ]]; then
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
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
DMG_DIR="$(dirname "$DMG")"
mkdir -p "$DMG_DIR"
DMG="$(cd "$DMG_DIR" && pwd)/$(basename "$DMG")"

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustdesk-dmg-stage.XXXXXX")"
cleanup() {
  rm -rf "$stage_dir"
}
trap cleanup EXIT

if [[ "$skip_app_verify" -eq 0 ]]; then
  echo "Verifying app bundle: $APP"
  codesign --verify --deep --strict --verbose=4 "$APP"
  codesign -dv --verbose=4 "$APP"
fi

echo "Staging app bundle..."
ditto --noextattr --noacl "$APP" "$stage_dir/$APP_NAME.app"
ln -s /Applications "$stage_dir/Applications"

if [[ "$skip_app_verify" -eq 0 ]]; then
  echo "Verifying staged app bundle..."
  codesign --verify --deep --strict --verbose=4 "$stage_dir/$APP_NAME.app"
fi

echo "Creating DMG: $DMG"
echo "Volume name: $VOLUME_NAME"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$stage_dir" \
  -ov \
  -format UDZO \
  "$DMG"

if [[ "$skip_sign" -eq 0 ]]; then
  echo "Signing DMG with identity: $SIGN_IDENTITY"
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --timestamp \
    "$DMG"
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
