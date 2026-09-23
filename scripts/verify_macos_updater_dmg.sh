#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/verify_macos_updater_dmg.sh PATH.dmg" >&2
  exit 2
fi

dmg="$1"
[[ -f "$dmg" ]] || { echo "DMG does not exist: $dmg" >&2; exit 1; }
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustadmin-updater-verify.XXXXXX")"
mounted=0
cleanup() {
  if [[ "$mounted" -eq 1 ]]; then
    hdiutil detach "$mount_dir" >/dev/null
  fi
  rmdir "$mount_dir"
}
trap cleanup EXIT

codesign --verify --verbose=2 "$dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$dmg" >/dev/null
mounted=1

for bundle in "$mount_dir/RustAdmin.app" "$mount_dir/RustAdminUpdate.app" \
  "$mount_dir/RustAdmin.app/Contents/Resources/RustAdminUpdate.app"; do
  [[ -d "$bundle" ]] || { echo "Missing bundle: $bundle" >&2; exit 1; }
  codesign --verify --deep --strict --verbose=2 "$bundle"
done
[[ -L "$mount_dir/Applications" && "$(readlink "$mount_dir/Applications")" == /Applications ]]
[[ -s "$mount_dir/RustAdminUpdate.app/Contents/Resources/AppIcon.icns" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :RustAdminStandaloneUpdate' \
  "$mount_dir/RustAdminUpdate.app/Contents/Info.plist")" == true ]]
# Separate Developer ID signatures can have different timestamps. Compare their
# signed code identities instead of comparing the signature bytes.
standalone_hash="$(codesign -d --verbose=4 "$mount_dir/RustAdminUpdate.app" 2>&1 | sed -n 's/^CDHash=//p')"
embedded_hash="$(codesign -d --verbose=4 \
  "$mount_dir/RustAdmin.app/Contents/Resources/RustAdminUpdate.app" 2>&1 | sed -n 's/^CDHash=//p')"
[[ -n "$standalone_hash" && "$standalone_hash" == "$embedded_hash" ]]
echo "Verified: signed DMG with RustAdmin.app, RustAdminUpdate.app and Applications shortcut."
