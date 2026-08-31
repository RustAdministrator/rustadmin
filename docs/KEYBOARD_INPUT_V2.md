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
  stable positions as physical HID. IME composition which has no physical key
  identity falls back to committed text. Other mobile clients keep the same
  text/physical split.
- `Text`: IME commits use text, and printable hardware input may use committed
  text when no Control, Alt, or Meta chord is active.
- `Physical`: Android uses the same fallback editor but prioritizes physical
  HID events. Unrepresentable IME composition falls back to committed text;
  it is never remapped through the intermediate Windows host layout. Hardware
  keys use physical input on every supported client.

The setting is stored per peer. Existing `mobile-physical-key-input` values are
used only as a one-time compatibility default when no V2 mode has been stored.

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
