#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build_macos_updater.sh --app-bundle PATH --version VERSION --revision REVISION [--arch ARCH]

Builds the native RustAdminUpdate.app helper into the main macOS app bundle.
USAGE
}

app_bundle=""
version=""
revision=""
arch="${RUSTADMIN_MACOS_ARCH:-$(uname -m)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle)
      [[ $# -ge 2 ]] || { echo "--app-bundle requires a path" >&2; exit 2; }
      app_bundle="$2"
      shift
      ;;
    --version)
      [[ $# -ge 2 ]] || { echo "--version requires a value" >&2; exit 2; }
      version="$2"
      shift
      ;;
    --revision)
      [[ $# -ge 2 ]] || { echo "--revision requires a value" >&2; exit 2; }
      revision="$2"
      shift
      ;;
    --arch)
      [[ $# -ge 2 ]] || { echo "--arch requires a value" >&2; exit 2; }
      arch="$2"
      shift
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
source_file="$repo_root/macos/RustAdminUpdate/RustAdminUpdate.swift"
icon_file="$repo_root/res/rustadmin-update-icon.icns"
updater_bundle="$app_bundle/Contents/Resources/RustAdminUpdate.app"

[[ -n "$app_bundle" ]] || { echo "--app-bundle is required" >&2; exit 2; }
[[ -n "$version" ]] || { echo "--version is required" >&2; exit 2; }
[[ -n "$revision" ]] || { echo "--revision is required" >&2; exit 2; }
[[ -d "$app_bundle" ]] || { echo "Main app bundle does not exist: $app_bundle" >&2; exit 1; }
[[ -f "$source_file" ]] || { echo "Updater source does not exist: $source_file" >&2; exit 1; }
[[ -f "$icon_file" ]] || { echo "Updater icon does not exist: $icon_file" >&2; exit 1; }

command -v xcrun >/dev/null 2>&1 || { echo "xcrun is required" >&2; exit 1; }

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
case "$arch" in
  arm64|x86_64) ;;
  *) echo "Unsupported macOS updater architecture: $arch" >&2; exit 1 ;;
esac

mkdir -p "$updater_bundle/Contents/MacOS" "$updater_bundle/Contents/Resources"
rm -f "$updater_bundle/Contents/MacOS/RustAdminUpdate"
rm -f "$updater_bundle/Contents/Resources/AppIcon.icns"
cp -f "$icon_file" "$updater_bundle/Contents/Resources/AppIcon.icns"

xcrun swiftc \
  -swift-version 5 \
  -target "$arch-apple-macos12.0" \
  -sdk "$sdk_path" \
  -framework AppKit \
  -framework Foundation \
  "$source_file" \
  -o "$updater_bundle/Contents/MacOS/RustAdminUpdate"

cat > "$updater_bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>RustAdmin Update</string>
  <key>CFBundleExecutable</key>
  <string>RustAdminUpdate</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.rustadministrator.rustadmin.update</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>RustAdminUpdate</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$revision</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

chmod 755 "$updater_bundle/Contents/MacOS/RustAdminUpdate"
echo "Built macOS updater: $updater_bundle"
