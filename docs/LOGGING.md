# RustAdmin logging locations

RustAdmin writes logs through `hbb_common::init_log()`. The base log directory is
chosen from the account that owns the process, then a role subdirectory is added
for command-line roles such as `--cm`, `--tray`, `--service`, and `--server`.

The application name is part of the path. For this fork the default name is
`RustAdmin`; custom branding may change that component.

## Windows

User GUI and viewer processes normally write to:

```text
%APPDATA%\RustAdmin\log
```

Common role subdirectories are:

```text
%APPDATA%\RustAdmin\log\cm
%APPDATA%\RustAdmin\log\tray
%APPDATA%\RustAdmin\log\portable-service
%APPDATA%\RustAdmin\log\check-hwcodec-config
```

Installed service and host-side server processes do not necessarily use the
interactive user's `%APPDATA%`. They use the profile of the service account that
owns the process. On Windows this can be a service profile path such as:

```text
C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustAdmin\log
C:\Windows\System32\config\systemprofile\AppData\Roaming\RustAdmin\log
```

Those directories can require elevated PowerShell or Administrator access. The
most reliable way to find the active host-side log root is to search the user GUI
log for the `server system info` line:

```powershell
Select-String "$env:APPDATA\RustAdmin\log\*.log","$env:APPDATA\RustAdmin\log\*\*.log" `
  -Pattern "server system info|process logging initialized"
```

Example meaning:

```text
server system info: log_path: C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustAdmin\log, ...
```

This means the visible GUI is logging under the user profile, but the installed
host/server endpoint is logging under the Windows service profile.

To inspect host-side codec and connection diagnostics, run elevated PowerShell
against the path reported by `server system info`:

```powershell
$serverLog = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustAdmin\log"

Get-ChildItem $serverLog -Recurse -Filter *.log |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 20 FullName,LastWriteTime,Length

Select-String "$serverLog\*.log","$serverLog\*\*.log" `
  -Pattern "diag conn run loop|supported_decoding|diag host selected encoder|diag first video frame|Connection closed"
```

Portable mode uses the same rule: logs go under the account that owns that
portable/helper process. Do not assume a build-tree path; check
`process logging initialized` or `server system info` in the logs.

## macOS

RustAdmin logs are under the current account's Library logs directory:

```text
~/Library/Logs/RustAdmin
```

Privileged helper or service processes can use a different account context. If a
host process is not using the GUI user's log directory, search for
`server system info` in the visible GUI log first.

## Linux

RustAdmin logs are under:

```text
~/.local/share/logs/RustAdmin
```

Root or system service processes use the home directory visible to that process,
so their logs can be under a different account. As on Windows, the
`server system info` line is the best source of truth for the active host-side
log path.
