# Temporary clipboard diagnostics

This tool checks real clipboard synchronization using known text fixtures. It is
available in Flutter builds for Windows, macOS, Linux, iOS, and Android. It does
not change transfer permissions, direction settings, or the production clipboard
implementation. Web builds do not expose it.

## Run a paired test

1. Connect the two devices normally. Keep RustAdmin open on both. On mobile,
   keep it in the foreground and grant clipboard access if the OS requests it.
2. On the receiving device, open **Settings → Debug → Clipboard listener** and
   enable the listener. Note its temporary listener code.
3. On the viewer, open the connection toolbar's **Debug → Clipboard tests**
   menu. Enter the other device's listener code, then select **Run both
   directions**. On mobile the Debug button opens the equivalent popup menu.
4. Avoid copying other content until the test finishes. Tests replace the
   clipboard on **both devices**; previous contents are not restored.
5. Copy reports from both devices after testing. Stop the listener when done;
   it also expires automatically after ten minutes and does not survive restart.

The listener belongs to the app window/Flutter engine where it was enabled.
Use the code shown in that window, and keep that window open. A listener in a
different window has a different code. Test one pair at a time; clipboard changes
can still propagate to other sessions according to normal clipboard settings.
The code identifies the intended responder, not a network route or access grant.
Tests reject another window on the same device, using a per-run hash of the
native device identifier. The raw device identifier is never copied or reported.

## What a result proves

The viewer writes a uniquely identified fixture to its system clipboard. Normal
RustAdmin synchronization must deliver it. The addressed listener reads and
checks the complete fixture, records forward receipt, and writes a different
return fixture. Normal synchronization must return that fixture to the viewer's
system clipboard, where the runner checks it.

- A successful round trip proves that both clipboard directions worked for that
  fixture and the selected listener code.
- A receiver's report can prove forward receipt and that it wrote a reply. It
  cannot prove that the reply arrived at the viewer.
- A timeout at the viewer leaves both directions unverified. Compare the
  receiver's report to locate the failed leg. A missing reply is not evidence
  that the forward direction failed.
- A stopped, cancelled, or background-interrupted run is not a pass.

Stopping prevents new operations. An OS clipboard write that was already issued
cannot be cancelled and may still finish. Its late completion is not reported as
a successful transfer. If an OS read remains stuck, stop and restart the listener
to begin a fresh observation generation.

The initial suite covers plain text, URLs represented as text, and Unicode text
with Japanese, Russian, emoji, tabs, and newlines. Native URL pasteboard types,
HTML/RTF, images, files, background clipboard access, and pasting inside Safari,
Terminal, or another destination application are **not tested** by this suite.
In particular, passing the URL-as-text case does not establish that Safari's
native URL representation can be transferred.

## Observe an application-specific failure

Enable the listener, copy from the failing application, and inspect its log. The
tool records text availability/size and known test events, not personal
clipboard contents. **Record native clipboard diagnostics** enables the existing
native format and transfer-policy logging where supported. Export the normal app
diagnostic bundle as well as this tool's report when investigating a native
format failure. No personal clipboard payload should be included in reports.

## Validation and removal

Automated tests use injected clipboard backends; they must never access the
developer's system clipboard. Run the focused controller and panel tests, plus
the existing mobile toolbar and desktop toolbar focus tests after UI changes.
Actual device acceptance is separate: exercise both clipboard directions for
every supported connection pair, including Linux X11 and Wayland separately.

`kClipboardDiagnosticsEnabled` in
`flutter/lib/common/widgets/clipboard_diagnostics_panel.dart` gates the temporary
settings and toolbar entry points. The runner and listener live in
`flutter/lib/common/clipboard_diagnostics.dart`; no wire-protocol change is
required for this paired clipboard test.
