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

- `Auto`: Android first requests fallback-editor key events and sends keys with
  stable positions as physical HID. IME output which has no physical key
  identity falls back to committed text. Other mobile clients keep the same
  text/physical split.
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
side-specific modifier snapshot with each hardware event. It is stateless; the
shared Dart state machine reconciles explicit and reported modifiers and owns
their lifetimes. The existing fallback editor can still pass bounded text when
Android provides no stable physical identity, but this phase does not add an
`InputConnection` composition model.

Toolbar modifiers enter as synthetic canonical intents. The state machine
queues an explicit HID modifier down before the shortcut key and its matching
up after the key, while coalescing ownership when the same physical side is
already held. The dispatcher pins the selected HID or legacy bridge path until
the final owner releases the modifier.

For each physical down, the state machine records exactly one route:

- `physical`: dispatch down/repeat/up through the same HID or legacy transport;
- `text`: dispatch the supplied text once and suppress physical release;
- `ignored`: retain enough state to make repeat/up/reset idempotent.

The recorded route is not recalculated on repeat, key-up, or a later mode
change. An explicit repeat remains a repeated key-down, while a duplicate
ordinary down is ignored rather than promoted to a repeat. Unknown and
duplicate key-up events are ignored. Reset releases only keys that were
physically dispatched, in deterministic non-modifier-then-modifier order,
clears synthetic modifier latches, and emits no release for text-routed keys.

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
