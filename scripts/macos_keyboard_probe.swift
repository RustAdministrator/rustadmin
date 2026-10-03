import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

private let maxLogLines = 220
private let maxLogBytes = 48 * 1024
private let maxLogLineCharacters = 1_200

private func scalarNames(_ text: String?) -> Any {
    guard let text else { return NSNull() }
    return text.unicodeScalars.map { String(format: "U+%04X", $0.value) }
}

private func textValue(_ value: Any) -> String {
    if let string = value as? String { return string }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return String(describing: value)
}

private func describedText(_ text: String?) -> String {
    guard let text else { return "nil" }
    let scalars = (scalarNames(text) as? [String])?.joined(separator: ",") ?? ""
    return "\(String(reflecting: text)) [\(scalars)]"
}

private func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
    let known: [(NSEvent.ModifierFlags, String)] = [
        (.capsLock, "capsLock"),
        (.shift, "shift"),
        (.control, "control"),
        (.option, "option"),
        (.command, "command"),
        (.numericPad, "numericPad"),
        (.help, "help"),
        (.function, "function")
    ]
    var names = known.compactMap { flags.contains($0.0) ? $0.1 : nil }
    if names.isEmpty { names.append("none") }
    return names
}

private func physicalLabel(for keyCode: UInt16) -> String? {
    switch Int(keyCode) {
    case kVK_JIS_Yen:
        return "kVK_JIS_Yen"
    case kVK_JIS_Underscore:
        return "kVK_JIS_Underscore"
    case kVK_JIS_Eisu:
        return "kVK_JIS_Eisu"
    case kVK_JIS_Kana:
        return "kVK_JIS_Kana"
    default:
        return nil
    }
}

private func systemKeyboardType() -> Int {
    Int(LMGetKbdType())
}

private func keyboardLayoutName(for keyboardType: Int) -> String {
    let layoutType = KBGetLayoutType(Int16(truncatingIfNeeded: keyboardType))
    switch layoutType {
    case PhysicalKeyboardLayoutType(kKeyboardANSI):
        return "ANSI"
    case PhysicalKeyboardLayoutType(kKeyboardISO):
        return "ISO"
    case PhysicalKeyboardLayoutType(kKeyboardJIS):
        return "JIS"
    case PhysicalKeyboardLayoutType(kKeyboardUnknown):
        return "unknown"
    default:
        return String(format: "unknown(0x%08X)", layoutType)
    }
}

private func rangeObject(_ range: NSRange) -> [String: Any] {
    ["location": range.location, "length": range.length]
}

private struct TISSourceMetadata {
    let id: String?
    let displayName: String?
    let type: String?
}

private struct InputSourceInfo {
    let inputSource: TISSourceMetadata
    let layout: TISSourceMetadata

    var jsonObject: [String: Any] {
        [
            "input_source_id": inputSource.id ?? NSNull(),
            "input_source_display_name": inputSource.displayName ?? NSNull(),
            "input_source_type": inputSource.type ?? NSNull(),
            "layout_id": layout.id ?? NSNull(),
            "layout_display_name": layout.displayName ?? NSNull(),
            "layout_type": layout.type ?? NSNull()
        ]
    }
}

private func stringProperty(_ source: TISInputSource, _ property: CFString) -> String? {
    guard let value = TISGetInputSourceProperty(source, property) else { return nil }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

private func sourceMetadata(_ source: TISInputSource?) -> TISSourceMetadata {
    guard let source else {
        return TISSourceMetadata(id: nil, displayName: nil, type: nil)
    }
    return TISSourceMetadata(
        id: stringProperty(source, kTISPropertyInputSourceID),
        displayName: stringProperty(source, kTISPropertyLocalizedName),
        type: stringProperty(source, kTISPropertyInputSourceType)
    )
}

private func currentInputSource() -> InputSourceInfo {
    let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
    return InputSourceInfo(
        inputSource: sourceMetadata(inputSource),
        layout: sourceMetadata(layout)
    )
}

private func encodedJSON(_ object: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private final class JSONReporter {
    func emit(_ object: [String: Any]) {
        guard let data = encodedJSON(object) else {
            fputs("macos_keyboard_probe: could not encode JSON event\n", stderr)
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        fflush(stdout)
    }
}

private func committedTextObject(_ text: String, replacementRange: NSRange) -> [String: Any] {
    [
        "type": "committed_text",
        "source": "NSTextView.insertText",
        "text": text,
        "unicode_scalars": scalarNames(text),
        "replacement_range": rangeObject(replacementRange),
        "input_source": currentInputSource().jsonObject
    ]
}

private func markedTextObject(
    _ text: String,
    selectedRange: NSRange,
    replacementRange: NSRange
) -> [String: Any] {
    [
        "type": "marked_text",
        "source": "NSTextView.setMarkedText",
        "text": text,
        "unicode_scalars": scalarNames(text),
        "selected_range": rangeObject(selectedRange),
        "replacement_range": rangeObject(replacementRange),
        "input_source": currentInputSource().jsonObject
    ]
}

private struct KeyboardEventRecord {
    let object: [String: Any]
    let logLine: String
}

private func keyboardEventRecord(_ event: NSEvent) -> KeyboardEventRecord? {
    let phase: String
    switch event.type {
    case .keyDown:
        phase = "keyDown"
    case .keyUp:
        phase = "keyUp"
    case .flagsChanged:
        phase = "flagsChanged"
    default:
        return nil
    }

    let characters: String?
    let charactersIgnoringModifiers: String?
    let isRepeat: Bool?
    switch event.type {
    case .keyDown, .keyUp:
        characters = event.characters
        charactersIgnoringModifiers = event.charactersIgnoringModifiers
        isRepeat = event.isARepeat
    case .flagsChanged:
        characters = nil
        charactersIgnoringModifiers = nil
        isRepeat = nil
    default:
        return nil
    }

    let keyCode = Int(event.keyCode)
    let lmKbdType = systemKeyboardType()
    let inputSource = currentInputSource().jsonObject
    var eventKeyboardType: Any = NSNull()
    var eventKeyboardLayoutType: Any = NSNull()
    if let cgEvent = event.cgEvent {
        let cgKeyboardType = Int(cgEvent.getIntegerValueField(.keyboardEventKeyboardType))
        eventKeyboardType = cgKeyboardType
        eventKeyboardLayoutType = keyboardLayoutName(for: cgKeyboardType)
    }

    let object: [String: Any] = [
        "type": "keyboard_event",
        "phase": phase,
        "event_timestamp_seconds": event.timestamp,
        "hardware_key_code": keyCode,
        "hardware_key_code_hex": String(format: "0x%02X", event.keyCode),
        "hardware_position_label": physicalLabel(for: event.keyCode) ?? NSNull(),
        "modifier_flags_raw": Int(event.modifierFlags.rawValue),
        "modifier_flags_names": modifierNames(event.modifierFlags),
        "is_repeat": isRepeat ?? NSNull(),
        "characters": characters ?? NSNull(),
        "characters_unicode_scalars": scalarNames(characters),
        "characters_ignoring_modifiers": charactersIgnoringModifiers ?? NSNull(),
        "characters_ignoring_modifiers_unicode_scalars": scalarNames(charactersIgnoringModifiers),
        "input_source": inputSource,
        "lm_kbd_type": lmKbdType,
        "lm_kbd_layout_type": keyboardLayoutName(for: lmKbdType),
        "event_cg_keyboard_type": eventKeyboardType,
        "event_cg_keyboard_layout_type": eventKeyboardLayoutType
    ]

    let label = physicalLabel(for: event.keyCode).map { " (\($0))" } ?? ""
    let repeatDescription = isRepeat.map { String($0) } ?? "unavailable"
    let logLine =
        "\(phase) keyCode=\(keyCode)/\(String(format: "0x%02X", event.keyCode))\(label) " +
        "flags=\(modifierNames(event.modifierFlags).joined(separator: ","))/\(event.modifierFlags.rawValue) " +
        "repeat=\(repeatDescription) raw=\(describedText(characters)) " +
        "ignoringModifiers=\(describedText(charactersIgnoringModifiers))"
    return KeyboardEventRecord(object: object, logLine: logLine)
}

private final class ProbeTextView: NSTextView {
    var onCommittedText: ((String, NSRange) -> Void)?
    var onMarkedText: ((String, NSRange, NSRange) -> Void)?

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        onCommittedText?(textValue(insertString), replacementRange)
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func setMarkedText(
        _ markedText: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        onMarkedText?(textValue(markedText), selectedRange, replacementRange)
        super.setMarkedText(markedText, selectedRange: selectedRange, replacementRange: replacementRange)
    }
}

private final class ProbeWindowController: NSWindowController, NSWindowDelegate {
    private let reporter: JSONReporter
    private let inputView = ProbeTextView(frame: .zero)
    private let logView = NSTextView(frame: .zero)
    private var eventMonitor: Any?
    private var captureIsActive = false
    private var logLines: [String] = []
    private var sequence = 0

    init(reporter: JSONReporter) {
        self.reporter = reporter
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RustAdmin macOS Keyboard Probe"
        window.contentMinSize = NSSize(width: 620, height: 500)
        super.init(window: window)
        window.delegate = self
        configureWindow()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func start() {
        installLocalMonitor()
        let lmKbdType = systemKeyboardType()
        let source = currentInputSource()
        emit([
            "type": "session_started",
            "tool": "rustadmin_macos_keyboard_probe",
            "input_source": source.jsonObject,
            "lm_kbd_type": lmKbdType,
            "lm_kbd_layout_type": keyboardLayoutName(for: lmKbdType),
            "capture_scope": "focused_probe_window_only",
            "notes": [
                "hardware_position_is_separate_from_produced_symbol",
                "key_event_text_is_separate_from_committed_text"
            ]
        ])
        appendLog("Input source: \(source.inputSource.id ?? "unknown"); layout: \(source.layout.id ?? "unknown"); keyboard: \(keyboardLayoutName(for: lmKbdType)) (\(lmKbdType)).")
        appendLog("Session started. Focus the typing box; capture pauses when this window loses focus.")
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(inputView)
        updateCaptureState()
    }

    func applicationActivationChanged() {
        updateCaptureState()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateCaptureState()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateCaptureState()
    }

    func windowWillClose(_ notification: Notification) {
        removeLocalMonitor()
    }

    deinit {
        removeLocalMonitor()
    }

    private func configureWindow() {
        guard let contentView = window?.contentView else { return }

        let instructions = NSTextField(
            labelWithString: "Type in the box. The event log is bounded; stdout is JSONL. Hardware key identity and produced text are reported separately."
        )
        instructions.lineBreakMode = .byWordWrapping
        instructions.maximumNumberOfLines = 2

        inputView.isEditable = true
        inputView.isSelectable = true
        inputView.isRichText = false
        inputView.allowsUndo = true
        inputView.isAutomaticQuoteSubstitutionEnabled = false
        inputView.isAutomaticDashSubstitutionEnabled = false
        inputView.isAutomaticTextReplacementEnabled = false
        inputView.isAutomaticSpellingCorrectionEnabled = false
        inputView.isAutomaticTextCompletionEnabled = false
        inputView.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        inputView.textContainerInset = NSSize(width: 8, height: 8)
        inputView.isVerticallyResizable = true
        inputView.isHorizontallyResizable = false
        inputView.autoresizingMask = [.width]
        inputView.textContainer?.widthTracksTextView = true
        inputView.onCommittedText = { [weak self] text, range in
            self?.recordCommittedText(text, replacementRange: range)
        }
        inputView.onMarkedText = { [weak self] text, selectedRange, replacementRange in
            self?.recordMarkedText(
                text,
                selectedRange: selectedRange,
                replacementRange: replacementRange
            )
        }

        let inputScroll = NSScrollView(frame: .zero)
        inputScroll.borderType = .bezelBorder
        inputScroll.hasVerticalScroller = true
        inputScroll.hasHorizontalScroller = false
        inputScroll.autohidesScrollers = true
        inputScroll.documentView = inputView

        let logTitle = NSTextField(labelWithString: "Human-readable event log")
        logTitle.font = NSFont.boldSystemFont(ofSize: 12)

        logView.isEditable = false
        logView.isSelectable = true
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true

        let logScroll = NSScrollView(frame: .zero)
        logScroll.borderType = .bezelBorder
        logScroll.hasVerticalScroller = true
        logScroll.hasHorizontalScroller = false
        logScroll.autohidesScrollers = true
        logScroll.documentView = logView

        let stack = NSStackView(views: [instructions, inputScroll, logTitle, logScroll])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)
        ])
    }

    private func installLocalMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    private func removeLocalMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func updateCaptureState() {
        let isActive = NSApp.isActive && window?.isKeyWindow == true
        guard isActive != captureIsActive else { return }
        captureIsActive = isActive
        let state = isActive ? "capture_resumed" : "capture_paused"
        appendLog(isActive ? "Capture resumed: probe window is focused." : "Capture paused: probe window lost focus.")
        emit([
            "type": state,
            "reason": "probe_window_focus",
            "input_source": currentInputSource().jsonObject
        ])
    }

    private func record(_ event: NSEvent) {
        guard captureIsActive,
              NSApp.isActive,
              let probeWindow = window,
              probeWindow.isKeyWindow,
              event.window === probeWindow else {
            return
        }

        guard let record = keyboardEventRecord(event) else { return }
        emit(record.object)
        appendLog(record.logLine)
    }

    private func recordCommittedText(_ text: String, replacementRange: NSRange) {
        guard captureIsActive else { return }
        emit(committedTextObject(text, replacementRange: replacementRange))
        appendLog("committed text=\(describedText(text)) replacementRange=\(replacementRange.location),\(replacementRange.length)")
    }

    private func recordMarkedText(
        _ text: String,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        guard captureIsActive else { return }
        emit(markedTextObject(text, selectedRange: selectedRange, replacementRange: replacementRange))
        appendLog(
            "marked text=\(describedText(text)) selectedRange=\(selectedRange.location),\(selectedRange.length) " +
                "replacementRange=\(replacementRange.location),\(replacementRange.length)"
        )
    }

    private func emit(_ object: [String: Any]) {
        sequence += 1
        var event = object
        event["sequence"] = sequence
        reporter.emit(event)
    }

    private func appendLog(_ line: String) {
        let clipped = line.count > maxLogLineCharacters
            ? String(line.prefix(maxLogLineCharacters)) + "…"
            : line
        logLines.append(clipped)
        while logLines.count > maxLogLines {
            logLines.removeFirst()
        }

        var text = logLines.joined(separator: "\n")
        while text.utf8.count > maxLogBytes && logLines.count > 1 {
            logLines.removeFirst()
            text = logLines.joined(separator: "\n")
        }
        logView.string = text
        logView.scrollToEndOfDocument(nil)
    }
}

private final class ProbeApplicationDelegate: NSObject, NSApplicationDelegate {
    private let reporter = JSONReporter()
    private var controller: ProbeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let controller = ProbeWindowController(reporter: reporter)
        self.controller = controller
        controller.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.applicationActivationChanged()
    }

    func applicationDidResignActive(_ notification: Notification) {
        controller?.applicationActivationChanged()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Keyboard Probe",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

private func usage() {
    print("""
    Usage: scripts/macos_keyboard_probe.sh [--help | --self-test]

    Launches a foreground AppKit window for focused macOS keyboard diagnostics.
    JSONL events are written to stdout while the probe window is focused.
    """)
}

private func runSelfTest() -> Int {
    let sample = "A~～¥\\^[]@"
    let expectedScalars = [
        "U+0041", "U+007E", "U+FF5E", "U+00A5", "U+005C",
        "U+005E", "U+005B", "U+005D", "U+0040"
    ]
    guard scalarNames(sample) as? [String] == expectedScalars else {
        fputs("self-test failed: scalar formatting\n", stderr)
        return 1
    }
    guard modifierNames([.shift, .command]) == ["shift", "command"] else {
        fputs("self-test failed: modifier formatting\n", stderr)
        return 1
    }
    guard physicalLabel(for: UInt16(kVK_JIS_Yen)) == "kVK_JIS_Yen" else {
        fputs("self-test failed: JIS key label\n", stderr)
        return 1
    }

    // Construct events for serialization checks, but never post or inject them.
    guard let flagsCGEvent = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true) else {
        fputs("self-test failed: could not construct flagsChanged CGEvent\n", stderr)
        return 1
    }
    flagsCGEvent.type = .flagsChanged
    flagsCGEvent.flags = [.maskShift]
    guard let flagsEvent = NSEvent(cgEvent: flagsCGEvent),
          let flagsRecord = keyboardEventRecord(flagsEvent),
          let flagsData = encodedJSON(flagsRecord.object),
          let decodedFlagsValue = try? JSONSerialization.jsonObject(with: flagsData),
          let decodedFlags = decodedFlagsValue as? [String: Any],
          decodedFlags["type"] as? String == "keyboard_event",
          decodedFlags["phase"] as? String == "flagsChanged",
          decodedFlags["is_repeat"] is NSNull,
          decodedFlags["characters"] is NSNull,
          decodedFlags["characters_ignoring_modifiers"] is NSNull else {
        fputs("self-test failed: flagsChanged serialization\n", stderr)
        return 1
    }

    guard let keyCGEvent = CGEvent(keyboardEventSource: nil, virtualKey: 24, keyDown: true),
          let keyEvent = NSEvent(cgEvent: keyCGEvent),
          let keyRecord = keyboardEventRecord(keyEvent),
          keyRecord.object["type"] as? String == "keyboard_event",
          keyRecord.object["phase"] as? String == "keyDown",
          !(keyRecord.object["is_repeat"] is NSNull) else {
        fputs("self-test failed: keyDown serialization\n", stderr)
        return 1
    }

    let committedSample = "line\n\u{001B}😀"
    let committed = committedTextObject(
        committedSample,
        replacementRange: NSRange(location: 3, length: 0)
    )
    let marked = markedTextObject(
        "に",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 0, length: 0)
    )
    guard committed["type"] as? String == "committed_text",
          committed["source"] as? String == "NSTextView.insertText",
          committed["text"] as? String == committedSample,
          marked["type"] as? String == "marked_text",
          marked["source"] as? String == "NSTextView.setMarkedText",
          scalarNames(committedSample) as? [String] == [
              "U+006C", "U+0069", "U+006E", "U+0065", "U+000A", "U+001B", "U+1F600"
          ],
          committed["type"] as? String != keyRecord.object["type"] as? String else {
        fputs("self-test failed: raw versus committed text records\n", stderr)
        return 1
    }
    guard let committedData = encodedJSON(committed),
          let committedLine = String(data: committedData, encoding: .utf8),
          committedLine.contains("\\n"),
          committedLine.contains("\\u001b") || committedLine.contains("\\u001B"),
          !committedLine.contains("\n"),
          let decodedCommittedValue = try? JSONSerialization.jsonObject(with: committedData),
          let decodedCommitted = decodedCommittedValue as? [String: Any],
          decodedCommitted["text"] as? String == committedSample else {
        fputs("self-test failed: JSON escaping\n", stderr)
        return 1
    }

    print("macos_keyboard_probe self-test: ok")
    return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments {
case [], ["--help"], ["-h"]:
    if arguments.isEmpty {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = ProbeApplicationDelegate()
        application.delegate = delegate
        application.run()
    } else {
        usage()
    }
case ["--self-test"]:
    exit(Int32(runSelfTest()))
default:
    fputs("Unknown argument.\n", stderr)
    usage()
    exit(2)
}
