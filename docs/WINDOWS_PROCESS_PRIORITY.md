# Windows Process Priority

Windows Settings > General exposes `Process priority` with these values:

- `Normal` (default)
- `Above normal`
- `High`

`Realtime` is intentionally not offered. It can starve input, audio, networking,
and operating-system services and is not appropriate for a remote-access host.

The setting is stored as the global `process-priority` option. A change is
applied immediately to the Flutter client process and is sent through the
existing configuration IPC to the running server. The privileged server also
passes the selected value to the interactive WGC/DXGI capture helper through
the existing shared-memory command block. New service, server, and helper
processes apply the configured value during startup.

Changing the priority does not restart the service and does not intentionally
disconnect active sessions. If Windows rejects a priority-class change, the
application keeps running and records a warning containing the process role,
requested value, and operating-system error.
