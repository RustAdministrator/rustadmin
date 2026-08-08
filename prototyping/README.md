# Prototyping

Temporary experiments live here when they should stay outside the production
app flow.

## Toolbar Lab

The current toolbar refactor prototype is a standalone Flutter desktop target:

- Dart target: `flutter/lib/prototyping/main_toolbar_lab.dart`
- Main page: `flutter/lib/prototyping/toolbar_lab_page.dart`

It does not initialize RustDesk session state or global FFI. The goal is fast
UI iteration with hot reload.

### One-time native build

Flutter desktop still expects the Rust native library to exist once for the
desktop runner.

Linux:

```bash
cd /mnt/f/gh/rustdesk/rustdesk-client
cargo build --features flutter --lib
```

Windows PowerShell:

```powershell
cd F:\GH\rustdesk\rustdesk-client
cargo build --features flutter --lib
```

### Run the lab

Linux:

```bash
cd /mnt/f/gh/rustdesk/rustdesk-client
scripts/run_toolbar_lab_linux.sh
```

Windows PowerShell:

```powershell
cd F:\GH\rustdesk\rustdesk-client
.\scripts\run_toolbar_lab_windows.ps1
```

macOS:

```bash
cd /path/to/rustdesk-client
scripts/run_toolbar_lab_macos.sh
```

Use hot reload for visual tweaks. Only rebuild Cargo if you touch Rust or FFI.

## Mobile Remote Lab

The mobile remote lab runs the mobile remote-control shell in a desktop window
without opening a network session. It loads static monitor screenshots from a
local directory and supports individual-monitor and combined-desktop views,
portrait and landscape phone viewports, zoom and pan, toolbar states, a mock
keyboard, chat, disconnect, and gesture-help states.

The lab does not bundle local screenshots into RustAdmin. By default it looks
for a sibling `rustadmin-tests/screens` directory. Use **Choose folder** in the
lab when the screenshots are stored elsewhere, or pass their directory at
compile time:

```text
--dart-define=RUSTADMIN_LAB_SCREENS=/path/to/screens
```

Linux or macOS:

```bash
scripts/run_mobile_remote_lab.sh
```

Windows PowerShell:

```powershell
.\scripts\run_mobile_remote_lab_windows.ps1
```

The platform runner options accepted by the toolbar lab are also accepted by
the mobile remote lab, including `--skip-cargo`, `--clean`, and codec options.
The Windows wrapper accepts the corresponding PowerShell parameters.

This is a UI prototyping tool. Use an Android emulator or physical device for
platform keyboard, touch, permission, MediaProjection, and lifecycle testing.
