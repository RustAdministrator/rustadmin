# Windows development notes

This note records the Windows API constraints that matter for RustAdmin capture,
portable elevation, installed services, lock screen behavior, and backend
selection.

## Desktop and session model

Windows screen capture and input injection run inside a window station and a
desktop. The normal interactive desktop is usually `WinSta0\Default`. Secure
surfaces such as the logon screen, lock screen password UI, and UAC secure
desktop use a different input desktop such as `WinSta0\Winlogon`.

A process can capture or inject input only when its token, session, and current
thread desktop have the required access. Running as Administrator is not the
same as running as `LocalSystem`, and an elevated portable GUI process must not
be treated as equivalent to the installed service.

Useful Microsoft references:

- Desktops: <https://learn.microsoft.com/en-us/windows/win32/winstation/desktops>
- `OpenInputDesktop`: <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openinputdesktop>
- `SetThreadDesktop`: <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddesktop>

## Capture APIs by desktop state

### Normal unlocked user desktop

On `WinSta0\Default`, the usable capture APIs are:

- Windows Graphics Capture (WGC): preferred modern capture API for normal user
  desktops. In installed-service mode it should usually be reached through a
  user-session helper, not directly from the service.
- Magnification API / WinMag: useful fallback for the normal interactive
  desktop. Treat it as a capture fallback, not as a secure-desktop solution.
- DXGI Desktop Duplication: GPU-oriented per-output capture. Its capture
  backend/pipeline must be recreated when the desktop, display mode, adapter, or
  output duplication state changes.
- GDI: legacy CPU fallback. It is slower and less capable, but it is still a
  useful last-resort path.

RustAdmin's preferred normal-desktop priority is:

```text
WGC -> WinMag -> DXGI -> GDI
```

Do not assume this priority applies unchanged on the secure desktop. Some APIs
that work on the unlocked desktop are expected to fail or return stale/blank
frames after lock, logon, UAC, display-mode changes, or user switching.

### Lock screen, logon, and UAC secure desktop

The secure desktop is deliberately isolated from ordinary user processes. For
RustAdmin development this means:

- WGC is not a lock/logon capture solution.
- WinMag is not a reliable lock/logon capture solution.
- DXGI may lose access and its capture backend/pipeline must be fully recreated
  after a desktop transition; it is not a guaranteed secure-desktop solution.
- GDI is the practical fallback to try from an installed service or helper that
  has access to the current input desktop.
- Portable elevated-as-user mode may still be unable to see or control the
  password UI. Do not describe portable elevation as equivalent to daemon/service
  mode.

If capture crosses a desktop transition, tear down the active backend and build a
new backend for the current input desktop. Reusing WGC, WinMag, or DXGI objects
across the transition can produce stale frames, black frames, or a connection
that shows video but loses input.

## Capture helpers

A helper is a RustAdmin-owned companion process used to run capture or input code
in a different Windows context than the main GUI or service.

Common helper roles:

- User-session capture helper: launched in the interactive user's session so the
  installed service can use APIs such as WGC on the unlocked user desktop.
- Portable helper / portable service: a temporary local companion process used
  by portable mode to separate elevated work, capture, or input from the main GUI
  session.
- Installed service process: not usually called a helper in UI text, but it can
  act as the privileged host-side process that starts or coordinates helpers.

Do not use helper as a synonym for Administrator. A helper's useful permissions
come from its token, session, desktop, and how it was launched.

DXGI-specific references:

- Desktop Duplication API: <https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api>
- `IDXGIOutputDuplication::AcquireNextFrame`: <https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutputduplication-acquirenextframe>

WGC reference:

- Screen capture: <https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture>

## Runtime mode expectations

### Portable normal user

Portable normal-user mode can capture and control the unlocked user desktop when
permissions allow it. It should not be expected to control the secure desktop.

### Portable elevated user

Portable elevation can improve normal-desktop permissions and can make some
fallbacks more stable, but it is still the user's token. It is not a daemon and
is not a replacement for service mode. In particular, do not assume it can
capture or inject into `WinSta0\Winlogon`.

### Installed service

Installed service mode is the correct base for unattended access and lock/logon
support. Even then, the service should use the right path for the active desktop:

- For the unlocked user desktop, prefer a user-session capture helper for WGC.
- For lock/logon, expect secure-desktop restrictions and use only backends that
  can be created from the current input desktop with the service/helper token.
- Input injection must follow the same desktop switch rules as capture.

### Lock-screen input regression check

Service-mode input depends on the thread switching to the current input desktop
with enough desktop access rights for both cursor APIs and `SendInput`.
`OpenInputDesktop` must keep the service-grade access mask:

```text
DESKTOP_CREATEMENU
DESKTOP_CREATEWINDOW
DESKTOP_ENUMERATE
DESKTOP_HOOKCONTROL
DESKTOP_WRITEOBJECTS
DESKTOP_READOBJECTS
DESKTOP_SWITCHDESKTOP
GENERIC_WRITE
```

Do not narrow this mask without a successful Windows service-mode lock/unlock
test. The expected manual regression sequence is:

1. Install and start RustAdmin as a service.
2. Connect from another machine and verify mouse and keyboard on the unlocked
   desktop.
3. Lock Windows on the host.
4. Click the lock screen and type a test password sequence from the viewer.
5. Log in locally if needed and verify the same remote connection regains mouse
   and keyboard input on the unlocked desktop.

The service/server logs should show `Desktop switched:
input_access_mask=...` and should not show repeated `Access is denied` from
mouse or keyboard input after the desktop switch.

## Development rules

- Keep backend selection fail-closed. Do not report a backend as usable until it
  has produced a valid frame for the current desktop.
- Re-probe and recreate the capture backend/pipeline after lock, unlock, UAC,
  display changes, session switch, and desktop switch signals.
- Log the selected capture API, capture mode, first frame, desktop state, and
  fallback reason. Client Quality Monitor `Capture API` is remote-host
  information, not the local viewer render path.
- Keep GUI, portable helper, and service logs separate. See `docs/LOGGING.md`
  for the Windows log locations and how to find the active service log path.
- Do not treat Administrator, elevated portable mode, installed service, and
  `LocalSystem` as interchangeable. They have different desktop access rules.
- Mirror drivers are obsolete for modern Windows remote capture. Do not add new
  work around mirror-driver capture.
