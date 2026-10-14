# macOS keyboard analyzer

`macos_keyboard_probe.sh` builds a small native AppKit diagnostic into a private
temporary directory, launches its foreground window, and removes the temporary
binary when it exits. It captures only its own focused window and runs
independently of RustAdmin. Requires macOS 12 or later and Apple's Command Line
Tools or Xcode (`xcrun swiftc`); no Python packages are needed.

Run it from the main `rustadmin` repository:

```sh
scripts/macos_keyboard_probe.sh
```

The window has a visual keyboard, an unknown/extra-key list, a typing box, and a
bounded event log. Focus the typing box before testing. Key capture is paused
whenever the probe window loses focus or the application is inactive. The local
monitor admits a windowless AppKit key event only while the probe application
is active and its window is the
current key window; an event explicitly attached to another window is rejected.
Close the window or choose **Quit Keyboard Probe** from the menu to finish.

## Visual keyboard and test progress

The keyboard drawing distinguishes keys that have not been observed, keys held
down now, and keys with an observed press. A checkmark records a press in this
test; it does not prove that the key produces the expected character or that a
remote computer received it. Repeated key-down events have a separate repeat
count. Losing focus clears held-key highlights while keeping test progress.

The automatic family selection uses the native ANSI/ISO/JIS metadata. Select a
family manually if the suggested drawing is wrong. Choose the MacBook, compact,
or full-size shape to match the physical keyboard. Physical shape and the
selected language/input method are independent: Japanese input can be used on
an ANSI keyboard. The drawings are generic templates, not automatic detection
of the exact keyboard model.

Click a drawn key to inspect its native identity, observed characters, Unicode,
modifiers, and counts. The text in the typing box is the actual native text,
including input-method composition. Neither a key's printed legend nor a custom
name is used to infer the character produced by an event.

## Unknown keys and keyboard profiles

An event that has no position in the selected drawing appears in the unknown /
extra-key list. Recognized controls such as volume keys are extra keys; an
unrecognized native code keeps an automatic numeric name. Ordinary keyboard
codes and media codes have separate identities, even when their numbers match.

Use **Rename selected** to add a personal label. To place an unknown entry on the
drawing, select the entry, choose **Assign selected: click key**, then click its
position on the keyboard. These are display annotations. They preserve the
original codes and text in diagnostics and do not change RustAdmin input routing.

Use **Save profile** to keep the chosen template, labels, and assignments;
choose **Load profile** to reuse them in another session. Invalid or unsupported
profiles show an error and leave the current profile intact. Profiles are saved explicitly;
the analyzer does not install a system keyboard layout.

## Reports and reset

Use **Save report** to export session metadata, the current keyboard profile,
key observations, and retained native event records as JSON. The retained
history retains at most 4,096 records or 4 MiB of encoded events; the report
identifies records omitted by that limit.
Stdout continues to contain the complete sequence of JSON Lines as events
arrive, so redirect stdout when a complete long-session trace is needed.

Use **Reset test** to clear progress, held states, the typing box, and retained
test events while keeping the keyboard profile. Focus returns to the typing
box. Custom names and assignments are included in the report separately from
the original native event records.

## Native event records

The probe writes one JSON object per line to stdout and flushes after each line.
Redirect stdout when a machine-readable record is useful:

```sh
scripts/macos_keyboard_probe.sh > /tmp/rustadmin-keyboard.jsonl
```

There is no automatic file output. `--help` prints usage without compiling the
probe, and `--self-test` compiles it and runs deterministic event-serializer and
JSON checks without creating an AppKit window:

```sh
scripts/macos_keyboard_probe.sh --help
scripts/macos_keyboard_probe.sh --self-test
```

Each `keyboard_event` record identifies the physical event with
`hardware_key_code` and `hardware_key_code_hex`. `hardware_position_label` names
known native controls independently of produced text, including left/right
Command, Shift, Control, and Option, Fn, Caps Lock, F1-F20, arrows, navigation
keys, Escape, Return, Tab, Delete, and keypad Enter. It is also present for
Apple JIS constants such as `kVK_JIS_Yen`; the label describes the hardware
position, not the character produced by the current input source.

`key_action` is `down` or `up` for ordinary keyDown/keyUp events. For
modifier-only `flagsChanged` events it uses documented device-specific modifier
bits when they identify the side, including a release while the opposite side
remains held. If an aggregate modifier is active but neither side bit is present,
the action is `changed` with the group marked active. Fn uses its aggregate flag. Caps Lock
reports `modifier_lock_state` (`on` or `off`) instead of claiming a physical
press or release. `modifier_flags_raw` and `modifier_flags_names` preserve the
native aggregate flags in every keyboard record.

The record also includes the native event timestamp (seconds since system
startup), the repeat flag, the system `LMGetKbdType()` value, and the Core
Graphics keyboard type when the event exposes it. `characters` and
`characters_ignoring_modifiers` preserve AppKit's raw values: an empty string
is reported as `empty`, while an unavailable field is `null` with status
`not_available`. Modifier-only `flagsChanged` events have unavailable character
and repeat fields because AppKit does not expose those fields for that event
type.

App-local `systemDefined` events with `NX_SUBTYPE_AUX_CONTROL_BUTTONS` subtype 8
are reported separately as `system_key_event` records. The
record preserves `subtype`, `rawData1`, and `rawData2`, and decodes known media
key labels and types plus `state` (`down`, `up`, or `repeat`) from `data1`.
Other subtypes are ignored. Unknown media codes retain their numeric value
without a key label; unknown states remain raw without a down/up interpretation.
These events are observed and returned to AppKit; the
probe does not consume or inject them.

`characters` and `characters_ignoring_modifiers`, with their Unicode scalar
arrays, describe what the native key event produced. They do not prove that
text was committed. Separate `committed_text` records come from
`NSTextView.insertText(_:replacementRange:)`. Separate `marked_text` records
come from `NSTextView.setMarkedText(_:selectedRange:replacementRange:)`, which
shows IME/dead-key composition updates. The session and event records include
the current TIS input-source and keyboard-layout metadata in the nested
`input_source` object. Its explicit fields are `input_source_id`,
`input_source_display_name`, `input_source_type`, `layout_id`,
`layout_display_name`, and `layout_type`. The input-source fields come from
`TISCopyCurrentKeyboardInputSource()`; the layout fields independently come
from `TISCopyCurrentKeyboardLayoutInputSource()`, so an IME source is not
relabeled as the active keyboard layout.

The typing box disables AppKit automatic quote substitution, dash substitution,
text replacement, spelling correction, and text completion. This keeps the
visible text and the `insertText` callback useful for punctuation diagnostics.

The keyboard metadata includes raw `lm_kbd_type` from `LMGetKbdType()`, the
human-readable `lm_kbd_layout_type` from
`KBGetLayoutType(lm_kbd_type)` (`ANSI`, `ISO`, `JIS`, or `unknown`), and the
Core Graphics event keyboard type when available. The event also reports the
corresponding `event_cg_keyboard_layout_type`. These are physical keyboard
layout facts and do not assert which input source is selected.

For a JIS comparison, test the same physical keys with and without Shift and
record the following cases where the active layout provides them:

- tilde `~` U+007E and any fullwidth tilde `～` U+FF5E;
- caret `^`, yen `¥`, and backslash `\`;
- `@`, brackets, and their Shift variants;
- a dead key or Japanese IME composition, watching `marked_text` before the
  final `committed_text`.

Compare the input-source metadata between runs. A layout can produce different
symbols for the same hardware keycode, and Unicode lookalikes are distinct
scalars. The probe establishes what the local Mac generated and committed; it
does not reveal which key or text the remote RustAdmin peer ultimately received.

Some Fn/Globe behavior and system shortcuts are intercepted by macOS or the
hardware before an app-local AppKit event exists. This foreground probe cannot
promise to observe every physical key or action. It keeps key identity,
characters, committed text, and IME marked text as separate observations.

For RustAdmin routing investigations, treat Map mode as a conditional
downstream example: it passes code 24 to `Equal` and then to Windows scan
`0x0D` unconditionally. On a Windows US host, a local JIS `Shift+^` that
produces `~` can therefore be observed downstream as `+`; this depends on the
host layout and is not a claim about the local Mac's default input source.
Compare Translate mode when using native Input source 1; Input source 2
restricts the menu to Map/Legacy, so it cannot be used as a visible Translate
comparison.

Capture a short sample locally, then type the same keys in a plain text editor
on the remote host using Map and Translate. Record the host keyboard layout and
which mode produced each result. The local probe captures only its own window;
switching to RustAdmin pauses it. Keep the resulting JSONL with those observations
to identify whether the mismatch is in local translation or remote routing.
