# Keyboard Input V2

Keyboard Input V2 separates committed text from physical keyboard input. It is
an additive application protocol and does not replace the legacy `KeyEvent`
message for peers that do not advertise support.

## Negotiation

The controlled peer advertises `Features.keyboard` in `PeerInfo` after login.
The controller sends `KeyboardInput` only after it receives a compatible
capability. Missing or older capabilities keep the existing `KeyEvent` path.

Protocol version 1 currently advertises:

- committed UTF-8 text;
- USB HID physical keys from keyboard usage page `0x07`;
- optional source-layout-aware committed-text fallback;
- a maximum committed-text payload.

`ModifierSync` and clipboard text fallback are reserved in the protocol, but
their capability flags remain disabled until their platform behavior is
validated independently.

## Ordering

`KeyboardInput` uses the existing reliable input channel. `KeyEvent`,
`KeyboardInput`, mouse buttons, and other reliable input therefore preserve
their relative order on QUIC. TCP keeps its existing single-stream ordering.

Each V2 message carries a non-zero input epoch and sequence number. A receiver
accepts a sequence only when it is greater than the last accepted value for the
same epoch. Gaps are allowed; duplicates and stale values are rejected. A new
epoch releases tracked modifiers before input resumes. Old input is never
replayed after reconnect.

## Payloads

`CommittedText` contains UTF-8 text, bounded delete-before/delete-after
grapheme counts, and optional bounded source language/layout metadata. The
receiver validates the complete message before injecting anything. Version 1
limits text to 2048 bytes, each deletion count to 64, and each metadata field
to 64 ASCII bytes. Long controller commits are split only at UTF-8 scalar
boundaries.

Committed text is converted to one existing translate-mode sequence with
`scan_code_text` disabled. This prevents the V2 path from mixing layout-derived
scan codes and Unicode fallback within one commit. Windows continues through
the portable secure-desktop helper when that route is active; macOS uses its
Unicode CGEvent path; Linux uses the existing X11 or Wayland text backend.

When Android's fallback editor cannot expose a physical key, it attaches the
current IME BCP-47 language tag. A Windows receiver advertising
`layout_aware_text` selects a matching already-loaded HKL as a read-only
character-to-position map. It neither activates nor changes the user's current
layout. If no matching layout or key exists, input falls back to committed
Unicode. Peers without the capability ignore the additive metadata and retain
the version 1 text path.

`PhysicalKey` contains a USB HID usage, down/repeat state, modifier state, and
lock state. The controlled peer maps HID to its native scan/key code at the
connection boundary, then reuses the existing platform input and stuck-key
cleanup path.

## Client Modes

- `Auto`: Android uses physical HID for hardware and unknown-origin keys.
  Confirmed printable IME key output is routed as text, even when a HID identity
  is available. Navigation, control characters and explicit toolbar modifier
  chords remain physical. IME output without a key identity retains its committed-text path.
  This does not promise Unicode support in firmware or VM consoles.
- `Text`: IME commits use text, and printable hardware input may use committed
  text when no Control, Alt, or Meta chord is active.
- `Physical`: Android uses the same fallback editor but prioritizes physical
  HID events. Unrepresentable IME output falls back to committed text; it is
  never remapped through the intermediate Windows host layout. Hardware keys
  use physical input on every supported client.

The setting is stored per peer. Existing `mobile-physical-key-input` values are
used only as a one-time compatibility default when no V2 mode has been stored.

## Controller Pipeline

Before the controller pipeline was consolidated, the input sources followed
independent paths:

```text
Flutter KeyEvent -----\
Flutter RawKeyEvent ---+-> InputModel mode/modifier branches -> FFI calls
Android native key ----/                                  |-> UiSession
Mobile toolbar --------> aggregate modifier booleans -----|   |-> KeyboardInput V2
Mobile text -----------> direct text FFI call ------------|   `-> legacy KeyEvent
```

`InputModel` separately normalized and routed raw and non-raw events, the old
controller tracked aggregate pressed-key releases, and the Android Kotlin
router maintained another pressed/modifier ledger. They ultimately used the
same command queue, but routing and ownership were spread across those layers.
`UiSession` selected V2 or legacy fallback after the Flutter/Rust bridge. The
controlled side then received `KeyboardInput` or `KeyEvent` in
`server::connection` and forwarded the validated event to
`server::input_service` and the existing platform injector.

The controller now uses one canonical flow:

```text
platform event
  -> source adapter
  -> KeyboardIntent (USB HID identity or committed text)
  -> KeyboardInputController (single public facade)
  -> KeyboardStateMachine (pressed state and per-key route ledger)
  -> KeyboardDispatcher (one ordered command queue)
  -> Flutter/Rust bridge
  -> UiSession (V2 capability selection or legacy fallback)
  -> server connection
  -> platform input service
```

The adapters normalize only. They do not send messages, select a protocol,
change a keyboard layout, or own pressed-key state. USB HID usage page and
usage are authoritative for physical identity. Logical key IDs are metadata
only and never replace HID identity. They may retain the existing named-key
fallback when a legacy peer cannot consume an otherwise invalid Flutter HID;
they are not used to invent printable text. Text supplied by the framework is
authoritative textual output and is never derived from a fixed QWERTY table.

`KeyboardInputController` is the only controller-side owner exposed to
`InputModel`. It gates new input before state mutation and delegates to one
state machine and one dispatcher. The dispatcher retains the upstream
generation-cancelled command queue. Permission loss, focus loss, background,
mode changes, reconnect, and session close cancel pending commands and may
bypass the permission gate only for key-up recovery actions.

The Android physical adapter reports the mapped HID, repeat flag, and
side-specific modifier snapshot with each hardware event. It also reports
`lock_modes` from that event's native meta state, not Flutter's lock cache while
the native editor owns focus. This bridge field uses Caps/Num/Scroll bits
`2/4/8`; Rust converts them once to V2 wire bits `1/2/4`. Missing metadata in
older native-channel payloads retains the zero-lock default; unknown bits are
rejected. The protocol and legacy peer lock representation are unchanged.
The adapter is stateless; the
shared Dart state machine reconciles explicit and reported modifiers and owns
their lifetimes. The existing fallback editor can still pass bounded text when
Android provides no stable physical identity, but this phase does not add an
`InputConnection` composition model.

Toolbar modifiers enter as synthetic canonical intents. The state machine
queues an explicit HID modifier down before the shortcut key and its matching
up after the key, while coalescing ownership when the same physical side is
already held. The dispatcher pins the selected HID or legacy bridge path until
the final owner releases the modifier.

For each HID/origin owner, the state machine records exactly one route:

- `physical`: dispatch down/repeat/up through the same HID or legacy transport;
- `text`: dispatch the supplied text once and suppress physical release;
- `ignored`: retain enough state to make repeat/up/reset idempotent.

The recorded route is not recalculated on repeat, key-up, or a later mode
change. An explicit repeat remains a repeated key-down, while a duplicate
ordinary down is ignored rather than promoted to a repeat. Unknown and
duplicate key-up events are ignored. Reset releases only keys that were
physically dispatched, in deterministic non-modifier-then-modifier order,
clears synthetic modifier latches, and emits no release for text-routed keys.

Hardware and IME owners of the same HID have independent routes and lifetimes.
Physical owners share one dispatch lease: an additional non-modifier press is
a repeated down, and only the last physical owner sends up. Reported modifier
owners are distinguished from explicit modifier owners within the same route
table. Pressed/dispatched key snapshots are derived from that table. A late
IME release after reset cannot remove a fresh hardware owner. IME modifiers
reported only alongside a text-routed key are not injected physically.

Queued releases retain their state-machine-owned dispatch lease until the queue
drains. Cancellation drops obsolete down/repeat/text commands, but preserves
key-up cleanup in FIFO order. A release is sent only if its matching transport
down was actually started; a down skipped before dispatch cannot release an
unowned key. Coalesced physical and toolbar modifier owners share the same
lease. This is local transport-attempt accounting, not a remote acknowledgement
or a second pressed-key routing model.

Committed-text admission is all-or-nothing per controller operation: at most
64 KiB of valid UTF-8, with no truncation or replacement of unpaired UTF-16
surrogates. The Android bridge passes the whole accepted operation. Rust then
splits V2 text at scalar boundaries into messages of at most 2048 bytes (or the
smaller negotiated peer limit). It validates scalar fit before sending any
delete-before/delete-after messages. A zero advertised limit retains the
compatibility default of 2048 bytes.

The controller reserves at most 64 KiB of pending text, 64 pending text/edit
operations, and 65536 pending deletion graphemes. Each edit must also have
nonnegative deletion counts whose sum is at most 65536. Reservations include
the running operation and are released on completion, failure, or cancellation
when the queue drains. Empty-text edits consume operation and deletion budgets.
Physical releases do not consume text budgets. Refused operations report a
typed, content-free reason through nonfatal UI feedback and do not consume
one-shot modifiers. Once a text transport call starts, its chunks finish in
order; cancellation skips queued operations, not part of an in-flight edit.
This provides local ordering and admission, not remote atomic rollback or
delivery acknowledgement.

Android `ACTION_MULTIPLE` and native editor control clicks normalize into a
controller-local bounded press batch (1-64 presses), not held-key repeats.
The state machine emits complete down/up pairs, or repeats without releasing
an existing physical owner. Ordinary hardware autorepeat remains repeated down
until the actual up. Invalid batch counts are rejected without partial input.
The batch is expanded through the existing dispatcher and adds no wire message.

Each canonical intent also carries controller-local origin (`hardware`, `ime`,
`toolbar`, or `unknown`), separate from its adapter/source enum. In particular,
the compatibility source name `androidHardwareKeyboard` identifies the native
key adapter and is not evidence that a physical keyboard produced the event.
Native key and batch envelopes preserve HID, a bounded scalar text candidate,
lock/modifier metadata and IME language/layout metadata. A candidate is not a
second committed-text event and does not itself select a route.

Android classification first honors soft-keyboard/editor-action flags. A
virtual hard-key area remains unknown. Hardware requires a positive device ID,
a resolved nonvirtual device and keyboard evidence in both event and device
sources. A remaining event delivered through InputConnection is IME-origin;
other ambiguous events remain unknown. Neither `deviceId=-1` nor missing
device data alone proves IME or hardware origin. Older native envelopes default
to unknown, and cannot claim toolbar origin. Flutter events without equivalent
device evidence also remain unknown; toolbar and direct text-editor intents
have known local origins. No adapter owns pressed state or transport selection.
Only the canonical state machine uses origin to select Auto routes.

The classification uses the documented meanings of
[KeyEvent flags](https://developer.android.com/reference/android/view/KeyEvent),
[InputDevice.isVirtual](https://developer.android.com/reference/android/view/InputDevice#isVirtual()),
and the [InputConnection delivery API](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/view/inputmethod/InputConnection.java).

For local WSL/Linux validation with an installed Flutter SDK, run the existing
Flutter and Android JVM suites together:

```sh
python3 scripts/verify_android_keyboard.py --flutter /path/to/flutter/bin/flutter
```

The runner uses the cached dependencies, stops on the first failed command,
and does not replace native Rust tests or physical-device acceptance.

Legacy and Translate modes retain the existing legacy named-key path. Desktop
Map mode, supported mobile physical input, and Android native hardware input
use canonical keyboard-page HID. Synthetic toolbar modifiers also use HID so
they share the same sender-side pressed state with Android hardware input. The
dispatcher owns bridge-path selection and is the only Dart component which
calls keyboard transport methods. `UiSession` remains the sole protocol
encoder and capability gate: a compatible peer receives `KeyboardInput`; an
older peer receives the existing `KeyEvent` fallback.

Left and right Control, Shift, Alt, and Meta remain distinct. Right Alt/AltGr is
keyboard-page usage `0xE6`; the controller does not rewrite it as generic Alt
or synthesize Ctrl+Alt.

### Deferred Work

The remaining keyboard work does not yet:

- implement Android `InputConnection` composition and committed-edit handling;
- implement iOS `UITextInput` or native `UIKey` adapters;
- add a Keyboard V2 snapshot/reset protobuf message or protocol version;
- add speculative deferred-modifier or layout-specific AltGr synthesis;
- change Windows, macOS, X11, or Wayland host injection;
- synchronize, activate, or silently change the remote keyboard layout.

Physical Shift combined with framework-provided text remains a deferred-
modifier case. The current selected-mode behavior is preserved rather than
adding an untested release/re-press heuristic. Remote-layout diagnostics must
also remain metadata-only and must never log typed content.

## Security

V2 input passes the same authentication, view-camera exclusion, pending local
permission prompt, keyboard permission, secure-desktop helper, and idle timer
gates as `KeyEvent`. Malformed or unsupported payloads are rejected without
partial injection. Logs may include protocol version, epoch, sequence, payload
type, and rejection reason, but never committed text or key content.

## Physical Acceptance

Before enabling reserved capabilities, test at least:

- Android IME commits in Latin, Cyrillic, CJK, and an emoji grapheme with host
  and client layouts intentionally mismatched;
- printable text, Backspace, Enter, arrows, Ctrl/Alt/Meta shortcuts, held keys,
  and auto-repeat in all three input modes;
- Windows native controls, browsers, terminals, VMware console input, lock and
  logon screens, and an elevated secure-desktop prompt;
- reconnect while a modifier is held and local keyboard permission toggling;
- new controller to old host, old controller to new host, TCP, and QUIC.
