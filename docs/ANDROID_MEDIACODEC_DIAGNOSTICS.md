# Android MediaCodec and Diagnostics

## Decoder behavior

Android H.264 and H.265 sessions prefer the NDK MediaCodec decoder when the
device reports a hardware decoder with a byte-buffer YUV420 output format. The
decoder is asynchronous: queuing an encoded access unit does not guarantee that
an output image is immediately available.

The Rust decoder reports three states:

- `FrameReady`: a decoded image and its originating RustAdmin frame ID are
  available.
- `OutputPending`: input was accepted and MediaCodec has not produced an image
  yet.
- `InputBackpressure`: MediaCodec temporarily has no input buffer available.

`OutputPending` and `InputBackpressure` are normal flow-control states. They do
not increment the decoder failure counter and do not mark H.264 or H.265 as
unsupported. Encoded input, pending byte count, and frame-ID mappings are all
bounded. A malformed buffer, unsupported output layout, or MediaCodec API error
still switches to the FFmpeg software fallback and requests normal video
recovery through the existing session path.

The extended Quality Monitor reports the active decoder backend and renderer.
`Hardware Android MediaCodec` identifies hardware decode. `rgba` identifies the
current CPU YUV-to-RGBA presentation path; hardware decode and texture rendering
are separate capabilities.

## Diagnostic logging

Android Settings > About contains a `Diagnostic logging` switch. Logging is
enabled by default for compatibility with existing diagnostic reports. Turning
it off stops both Rust Logcat output and private Rust/Flutter diagnostic file
writes without requiring an app restart.

Private diagnostic files are stored below the application-private diagnostics
directory. They do not require shared-storage permission. The existing
`Export diagnostic report` action packages the available bounded logs. Disable
logging before using `Delete diagnostic logs` so no writer is active while the
files are removed.

Do not log clipboard contents, keyboard data, authentication material, or file
contents. The transport and codec diagnostics record state, sizes, counters,
timings, and error categories only.

## Build gate

Android hardware-codec builds must enable `flutter,hwcodec,mediacodec`. The
ARM64 build script validates the dedicated MediaCodec implementation in the
release library using a stable implementation diagnostic marker rather than a
UI label that release LTO may remove.
