# RustAdmin Plans

## Advanced Connection Diagnostics and Tuning

Future GUI work should expose advanced, non-default connection tuning for difficult
links such as VPN over LTE:

- Startup-safe video profile: enable/disable and adjust startup duration.
- Startup video limits: initial FPS cap and bitrate/quality cap.
- No-video watchdog: timeout before closing a session that authenticated but never
  received a video packet.
- Host video backpressure: stale-frame drop threshold and diagnostics.
- Optional retry policy: retry direct/relay paths when the video stream never
  starts, when rendezvous/relay infrastructure is configured.

Keep these under an advanced or diagnostics section. Defaults should remain safe
for normal users and should not weaken secure connection or pairing behavior.
