# Updating RustAdmin on macOS

Open the downloaded DMG and double-click **RustAdminUpdate** (the light icon).
It finds RustAdmin beside it and compares that copy with the app in Applications.
Click **Update** and approve the macOS administrator prompt. RustAdmin closes,
the application is replaced, and the installed copy reopens.

An installed service keeps its previous state: running services restart, stopped
services stay stopped, and an app without a service does not acquire one. Remote
sessions disconnect while the app and running service are replaced.

If the updater has been copied away from its download, select the newer
RustAdmin.app when asked. Keep the DMG mounted until the update completes.
For a first installation, drag RustAdmin.app to Applications.

## Build and packaging

`scripts/build_macos.sh` builds the native helper inside RustAdmin.app. The main
app uses that embedded helper for its existing upgrade flow.
`scripts/package_macos.sh` also places a copy beside RustAdmin.app in the DMG,
signs both applications and the disk image, and uses the existing notarization
configuration. It rejects old bundles that lack standalone-updater support.
`SKIP_DMG=1` exports both signed apps to the output directory.

For local ad-hoc packaging, use `SIGN_IDENTITY=- SKIP_NOTARY=1` with the packaging
script. Validate the result with:

```sh
bash scripts/verify_macos_updater_dmg.sh dist/macos/<package>.dmg
```

This checks the mounted payload and signatures without launching the update or
changing the installed app. Ad-hoc checks do not replace Developer ID signing,
notarization, or testing an approved update on a real installation.
