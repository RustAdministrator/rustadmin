import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

private let maxLogLines = 220
private let maxLogBytes = 48 * 1024
private let maxLogLineCharacters = 1_200

private enum ProbeEventWindow {
    case none
    case probe
    case foreign
}

private func admitsProbeEvent(
    eventWindow: ProbeEventWindow,
    appIsActive: Bool,
    probeIsKeyWindow: Bool,
    currentKeyWindowIsProbe: Bool
) -> Bool {
    guard appIsActive, probeIsKeyWindow, currentKeyWindowIsProbe else { return false }
    return eventWindow != .foreign
}

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

private struct ModifierTransition {
    let action: String?
    let source: String
    let groupActive: Bool?
    let lockState: String?
}

private let deviceLeftControlMask = UInt(NX_DEVICELCTLKEYMASK)
private let deviceLeftShiftMask = UInt(NX_DEVICELSHIFTKEYMASK)
private let deviceRightShiftMask = UInt(NX_DEVICERSHIFTKEYMASK)
private let deviceLeftCommandMask = UInt(NX_DEVICELCMDKEYMASK)
private let deviceRightCommandMask = UInt(NX_DEVICERCMDKEYMASK)
private let deviceLeftOptionMask = UInt(NX_DEVICELALTKEYMASK)
private let deviceRightOptionMask = UInt(NX_DEVICERALTKEYMASK)
private let deviceRightControlMask = UInt(NX_DEVICERCTLKEYMASK)

private func deviceModifierMask(for keyCode: UInt16) -> UInt? {
    switch Int(keyCode) {
    case kVK_Control:
        return deviceLeftControlMask
    case kVK_Shift:
        return deviceLeftShiftMask
    case kVK_RightShift:
        return deviceRightShiftMask
    case kVK_Command:
        return deviceLeftCommandMask
    case kVK_RightCommand:
        return deviceRightCommandMask
    case kVK_Option:
        return deviceLeftOptionMask
    case kVK_RightOption:
        return deviceRightOptionMask
    case kVK_RightControl:
        return deviceRightControlMask
    default:
        return nil
    }
}

private func aggregateModifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
    switch Int(keyCode) {
    case kVK_Control, kVK_RightControl:
        return .control
    case kVK_Shift, kVK_RightShift:
        return .shift
    case kVK_Command, kVK_RightCommand:
        return .command
    case kVK_Option, kVK_RightOption:
        return .option
    default:
        return nil
    }
}

private func deviceModifierFamilyMask(for flag: NSEvent.ModifierFlags) -> UInt {
    switch flag {
    case .control: return deviceLeftControlMask | deviceRightControlMask
    case .shift: return deviceLeftShiftMask | deviceRightShiftMask
    case .command: return deviceLeftCommandMask | deviceRightCommandMask
    case .option: return deviceLeftOptionMask | deviceRightOptionMask
    default: return 0
    }
}

private func modifierTransition(
    for keyCode: UInt16,
    flags: NSEvent.ModifierFlags
) -> ModifierTransition {
    if keyCode == UInt16(kVK_CapsLock) {
        let active = flags.contains(.capsLock)
        return ModifierTransition(
            action: nil,
            source: "caps_lock_state",
            groupActive: active,
            lockState: active ? "on" : "off"
        )
    }

    if keyCode == UInt16(kVK_Function) {
        let active = flags.contains(.function)
        return ModifierTransition(
            action: active ? "down" : "up",
            source: "aggregate_function_flag",
            groupActive: active,
            lockState: nil
        )
    }

    if let deviceMask = deviceModifierMask(for: keyCode),
       let aggregateFlag = aggregateModifierFlag(for: keyCode) {
        let deviceActive = flags.rawValue & deviceMask != 0
        let groupActive = flags.contains(aggregateFlag)
        if deviceActive {
            return ModifierTransition(
                action: "down",
                source: "device_specific_modifier_bit",
                groupActive: groupActive,
                lockState: nil
            )
        }
        if flags.rawValue & deviceModifierFamilyMask(for: aggregateFlag) != 0 {
            return ModifierTransition(
                action: "up",
                source: "device_specific_modifier_bit",
                groupActive: groupActive,
                lockState: nil
            )
        }
        if groupActive {
            return ModifierTransition(
                action: "changed",
                source: "aggregate_group_active_side_unknown",
                groupActive: true,
                lockState: nil
            )
        }
        return ModifierTransition(
            action: "up",
            source: "aggregate_group_inactive",
            groupActive: false,
            lockState: nil
        )
    }

    return ModifierTransition(
        action: "changed",
        source: "unknown_modifier_transition",
        groupActive: nil,
        lockState: nil
    )
}

private func physicalLabel(for keyCode: UInt16) -> String? {
    switch Int(keyCode) {
    case kVK_Command:
        return "leftCommand"
    case kVK_RightCommand:
        return "rightCommand"
    case kVK_Shift:
        return "leftShift"
    case kVK_RightShift:
        return "rightShift"
    case kVK_Control:
        return "leftControl"
    case kVK_RightControl:
        return "rightControl"
    case kVK_Option:
        return "leftOption"
    case kVK_RightOption:
        return "rightOption"
    case kVK_Function:
        return "fn"
    case kVK_CapsLock:
        return "capsLock"
    case kVK_F1:
        return "F1"
    case kVK_F2:
        return "F2"
    case kVK_F3:
        return "F3"
    case kVK_F4:
        return "F4"
    case kVK_F5:
        return "F5"
    case kVK_F6:
        return "F6"
    case kVK_F7:
        return "F7"
    case kVK_F8:
        return "F8"
    case kVK_F9:
        return "F9"
    case kVK_F10:
        return "F10"
    case kVK_F11:
        return "F11"
    case kVK_F12:
        return "F12"
    case kVK_F13:
        return "F13"
    case kVK_F14:
        return "F14"
    case kVK_F15:
        return "F15"
    case kVK_F16:
        return "F16"
    case kVK_F17:
        return "F17"
    case kVK_F18:
        return "F18"
    case kVK_F19:
        return "F19"
    case kVK_F20:
        return "F20"
    case kVK_LeftArrow:
        return "leftArrow"
    case kVK_RightArrow:
        return "rightArrow"
    case kVK_UpArrow:
        return "upArrow"
    case kVK_DownArrow:
        return "downArrow"
    case kVK_Home:
        return "home"
    case kVK_End:
        return "end"
    case kVK_PageUp:
        return "pageUp"
    case kVK_PageDown:
        return "pageDown"
    case kVK_Escape:
        return "escape"
    case kVK_Return:
        return "return"
    case kVK_Tab:
        return "tab"
    case kVK_Delete:
        return "delete"
    case kVK_ForwardDelete:
        return "forwardDelete"
    case kVK_ANSI_KeypadEnter:
        return "keypadEnter"
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

private struct MediaKeyDescription {
    let label: String
    let type: String
}

private func mediaKeyDescription(for keyCode: Int) -> MediaKeyDescription? {
    switch keyCode {
    case Int(NX_KEYTYPE_SOUND_UP):
        return MediaKeyDescription(label: "volumeUp", type: "audio")
    case Int(NX_KEYTYPE_SOUND_DOWN):
        return MediaKeyDescription(label: "volumeDown", type: "audio")
    case Int(NX_KEYTYPE_BRIGHTNESS_UP):
        return MediaKeyDescription(label: "brightnessUp", type: "display")
    case Int(NX_KEYTYPE_BRIGHTNESS_DOWN):
        return MediaKeyDescription(label: "brightnessDown", type: "display")
    case Int(NX_KEYTYPE_CAPS_LOCK):
        return MediaKeyDescription(label: "capsLock", type: "modifier")
    case Int(NX_KEYTYPE_HELP):
        return MediaKeyDescription(label: "help", type: "system")
    case Int(NX_POWER_KEY):
        return MediaKeyDescription(label: "power", type: "system")
    case Int(NX_KEYTYPE_MUTE):
        return MediaKeyDescription(label: "mute", type: "audio")
    case Int(NX_UP_ARROW_KEY):
        return MediaKeyDescription(label: "upArrow", type: "navigation")
    case Int(NX_DOWN_ARROW_KEY):
        return MediaKeyDescription(label: "downArrow", type: "navigation")
    case Int(NX_KEYTYPE_NUM_LOCK):
        return MediaKeyDescription(label: "numLock", type: "modifier")
    case Int(NX_KEYTYPE_CONTRAST_UP):
        return MediaKeyDescription(label: "contrastUp", type: "display")
    case Int(NX_KEYTYPE_CONTRAST_DOWN):
        return MediaKeyDescription(label: "contrastDown", type: "display")
    case Int(NX_KEYTYPE_LAUNCH_PANEL):
        return MediaKeyDescription(label: "launchPanel", type: "system")
    case Int(NX_KEYTYPE_EJECT):
        return MediaKeyDescription(label: "eject", type: "system")
    case Int(NX_KEYTYPE_VIDMIRROR):
        return MediaKeyDescription(label: "videoMirror", type: "display")
    case Int(NX_KEYTYPE_PLAY):
        return MediaKeyDescription(label: "play", type: "transport")
    case Int(NX_KEYTYPE_NEXT):
        return MediaKeyDescription(label: "next", type: "transport")
    case Int(NX_KEYTYPE_PREVIOUS):
        return MediaKeyDescription(label: "previous", type: "transport")
    case Int(NX_KEYTYPE_FAST):
        return MediaKeyDescription(label: "fastForward", type: "transport")
    case Int(NX_KEYTYPE_REWIND):
        return MediaKeyDescription(label: "rewind", type: "transport")
    case Int(NX_KEYTYPE_ILLUMINATION_UP):
        return MediaKeyDescription(label: "keyboardIlluminationUp", type: "keyboard")
    case Int(NX_KEYTYPE_ILLUMINATION_DOWN):
        return MediaKeyDescription(label: "keyboardIlluminationDown", type: "keyboard")
    case Int(NX_KEYTYPE_ILLUMINATION_TOGGLE):
        return MediaKeyDescription(label: "keyboardIlluminationToggle", type: "keyboard")
    case Int(NX_KEYTYPE_MENU):
        return MediaKeyDescription(label: "menu", type: "system")
    default:
        return nil
    }
}

private struct SystemKeyData {
    let keyCode: Int
    let stateCode: Int
    let isRepeat: Bool
    let state: String?
}

private func systemKeyData(from data1: Int) -> SystemKeyData {
    let rawData1 = UInt32(truncatingIfNeeded: data1)
    let keyCode = Int((rawData1 >> 16) & 0xFFFF)
    let stateCode = Int((rawData1 >> 8) & 0xFF)
    let isRepeat = rawData1 & 0x1 != 0
    let state: String?
    switch stateCode {
    case Int(NX_KEYDOWN):
        state = isRepeat ? "repeat" : "down"
    case Int(NX_KEYUP):
        state = "up"
    default:
        state = nil
    }
    return SystemKeyData(
        keyCode: keyCode,
        stateCode: stateCode,
        isRepeat: isRepeat,
        state: state
    )
}

private func systemKeyEventRecord(_ event: NSEvent) -> KeyboardEventRecord? {
    guard event.type == .systemDefined else { return nil }

    let subtype = Int(event.subtype.rawValue)
    guard subtype == Int(NX_SUBTYPE_AUX_CONTROL_BUTTONS) else { return nil }
    let decodedData = systemKeyData(from: event.data1)
    let mediaDescription: MediaKeyDescription?
    if decodedData.state != nil {
        mediaDescription = mediaKeyDescription(for: decodedData.keyCode)
    } else {
        mediaDescription = nil
    }

    let object: [String: Any] = [
        "type": "system_key_event",
        "phase": "systemDefined",
        "event_timestamp_seconds": event.timestamp,
        "subtype": subtype,
        "rawData1": event.data1,
        "rawData2": event.data2,
        "media_key_code": decodedData.keyCode,
        "media_key_label": mediaDescription?.label ?? NSNull(),
        "media_key_type": mediaDescription?.type ?? NSNull(),
        "state_code": decodedData.stateCode,
        "state": decodedData.state ?? NSNull(),
        "is_repeat": decodedData.state == nil ? NSNull() : decodedData.isRepeat,
        "modifier_flags_raw": Int(event.modifierFlags.rawValue),
        "modifier_flags_names": modifierNames(event.modifierFlags)
    ]

    let mediaLabel = mediaDescription?.label ?? "unknown"
    let state = decodedData.state ?? "unknown"
    let logLine =
        "systemDefined subtype=\(subtype) rawData1=\(event.data1) rawData2=\(event.data2) " +
        "mediaKey=\(mediaLabel) state=\(state)"
    return KeyboardEventRecord(object: object, logLine: logLine)
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

    let keyAction: String?
    let keyActionSource: String
    let modifierGroupActive: Bool?
    let modifierLockState: String?
    switch event.type {
    case .keyDown:
        keyAction = "down"
        keyActionSource = "event_type"
        modifierGroupActive = nil
        modifierLockState = nil
    case .keyUp:
        keyAction = "up"
        keyActionSource = "event_type"
        modifierGroupActive = nil
        modifierLockState = nil
    case .flagsChanged:
        let transition = modifierTransition(for: event.keyCode, flags: event.modifierFlags)
        keyAction = transition.action
        keyActionSource = transition.source
        modifierGroupActive = transition.groupActive
        modifierLockState = transition.lockState
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
        "key_action": keyAction ?? NSNull(),
        "key_action_source": keyActionSource,
        "modifier_group_active": modifierGroupActive.map { $0 as Any } ?? NSNull(),
        "modifier_lock_state": modifierLockState ?? NSNull(),
        "modifier_flags_raw": Int(event.modifierFlags.rawValue),
        "modifier_flags_names": modifierNames(event.modifierFlags),
        "is_repeat": isRepeat ?? NSNull(),
        "characters": characters ?? NSNull(),
        "characters_status": characters.map { $0.isEmpty ? "empty" : "text" } ?? "not_available",
        "characters_unicode_scalars": scalarNames(characters),
        "characters_ignoring_modifiers": charactersIgnoringModifiers ?? NSNull(),
        "characters_ignoring_modifiers_status": charactersIgnoringModifiers.map { $0.isEmpty ? "empty" : "text" } ?? "not_available",
        "characters_ignoring_modifiers_unicode_scalars": scalarNames(charactersIgnoringModifiers),
        "input_source": inputSource,
        "lm_kbd_type": lmKbdType,
        "lm_kbd_layout_type": keyboardLayoutName(for: lmKbdType),
        "event_cg_keyboard_type": eventKeyboardType,
        "event_cg_keyboard_layout_type": eventKeyboardLayoutType
    ]

    let label = physicalLabel(for: event.keyCode).map { " (\($0))" } ?? ""
    let repeatDescription = isRepeat.map { String($0) } ?? "unavailable"
    let lockDescription = modifierLockState.map { " lockState=\($0)" } ?? ""
    let logLine =
        "\(phase) keyCode=\(keyCode)/\(String(format: "0x%02X", event.keyCode))\(label) " +
        "flags=\(modifierNames(event.modifierFlags).joined(separator: ","))/\(event.modifierFlags.rawValue) " +
        "action=\(keyAction ?? "unavailable") repeat=\(repeatDescription)\(lockDescription) " +
        "raw=\(describedText(characters)) " +
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
            labelWithString: "Press keys or combinations in the box. The log shows key codes and modifiers even when no text appears. Stdout is JSONL."
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
            matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]
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
        let isActive = NSApp.isActive &&
            window?.isKeyWindow == true &&
            (window != nil && NSApp.keyWindow === window)
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
        guard captureIsActive, let probeWindow = window else {
            return
        }

        let eventWindow: ProbeEventWindow
        if let window = event.window {
            eventWindow = window === probeWindow ? .probe : .foreign
        } else {
            eventWindow = .none
        }
        guard admitsProbeEvent(
            eventWindow: eventWindow,
            appIsActive: NSApp.isActive,
            probeIsKeyWindow: probeWindow.isKeyWindow,
            currentKeyWindowIsProbe: NSApp.keyWindow === probeWindow
        ) else {
            return
        }

        let record: KeyboardEventRecord?
        switch event.type {
        case .systemDefined:
            record = systemKeyEventRecord(event)
        case .keyDown, .keyUp, .flagsChanged:
            record = keyboardEventRecord(event)
        default:
            record = nil
        }
        guard let record else { return }
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

private func packedSystemKeyData(keyCode: Int, stateCode: Int, isRepeat: Bool = false) -> Int {
    let rawData1 = (UInt32(keyCode) << 16) |
        (UInt32(stateCode) << 8) |
        (isRepeat ? 1 : 0)
    return Int(rawData1)
}

private func syntheticSystemEvent(subtype: Int16, data1: Int, data2: Int = 0) -> NSEvent? {
    NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: [],
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        subtype: subtype,
        data1: data1,
        data2: data2
    )
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

    let focusCases: [(ProbeEventWindow, Bool, Bool, Bool, Bool)] = [
        (.none, true, true, true, true),
        (.probe, true, true, true, true),
        (.foreign, true, true, true, false),
        (.none, false, true, true, false),
        (.none, true, false, true, false),
        (.none, true, true, false, false)
    ]
    for (eventWindow, appIsActive, probeIsKeyWindow, currentKeyWindowIsProbe, expected) in focusCases {
        guard admitsProbeEvent(
            eventWindow: eventWindow,
            appIsActive: appIsActive,
            probeIsKeyWindow: probeIsKeyWindow,
            currentKeyWindowIsProbe: currentKeyWindowIsProbe
        ) == expected else {
            fputs("self-test failed: foreground focus predicate\n", stderr)
            return 1
        }
    }

    let aggregateCommand = CGEventFlags.maskCommand.rawValue
    let aggregateShift = CGEventFlags.maskShift.rawValue
    let commandEventFlags = CGEventFlags(
        rawValue: aggregateCommand | UInt64(deviceLeftCommandMask)
    )
    let commandAndShiftEventFlags = CGEventFlags(
        rawValue: aggregateCommand |
            aggregateShift |
            UInt64(deviceLeftCommandMask) |
            UInt64(deviceLeftShiftMask)
    )
    guard let commandCGEvent = CGEvent(
        keyboardEventSource: nil,
        virtualKey: UInt16(kVK_Command),
        keyDown: true
    ), let commandEvent = NSEvent(cgEvent: commandCGEvent),
          let commandRecord = keyboardEventRecord(commandEvent),
          commandEvent.window == nil,
          commandRecord.object["hardware_position_label"] as? String == "leftCommand",
          commandRecord.object["key_action"] as? String == "down" else {
        fputs("self-test failed: windowless Command event\n", stderr)
        return 1
    }
    commandCGEvent.type = .flagsChanged
    commandCGEvent.flags = commandEventFlags
    guard let commandFlagsEvent = NSEvent(cgEvent: commandCGEvent),
          commandFlagsEvent.window == nil,
          let commandFlagsRecord = keyboardEventRecord(commandFlagsEvent),
          commandFlagsRecord.object["hardware_position_label"] as? String == "leftCommand",
          admitsProbeEvent(
              eventWindow: .none,
              appIsActive: true,
              probeIsKeyWindow: true,
              currentKeyWindowIsProbe: true
          ) else {
        fputs("self-test failed: windowless Command+Shift routing\n", stderr)
        return 1
    }
    guard let shiftCGEvent = CGEvent(
        keyboardEventSource: nil,
        virtualKey: UInt16(kVK_Shift),
        keyDown: true
    ), let shiftEvent = NSEvent(cgEvent: shiftCGEvent) else {
        fputs("self-test failed: could not construct windowless Shift event\n", stderr)
        return 1
    }
    shiftCGEvent.type = .flagsChanged
    shiftCGEvent.flags = commandAndShiftEventFlags
    guard let shiftFlagsEvent = NSEvent(cgEvent: shiftCGEvent),
          shiftEvent.window == nil,
          shiftFlagsEvent.window == nil,
          let shiftFlagsRecord = keyboardEventRecord(shiftFlagsEvent),
          shiftFlagsRecord.object["hardware_position_label"] as? String == "leftShift" else {
        fputs("self-test failed: windowless Shift event\n", stderr)
        return 1
    }

    let fnDown = modifierTransition(for: UInt16(kVK_Function), flags: [.function])
    guard fnDown.action == "down", fnDown.source == "aggregate_function_flag" else {
        fputs("self-test failed: Fn transition\n", stderr)
        return 1
    }
    guard physicalLabel(for: UInt16(kVK_F1)) == "F1",
          physicalLabel(for: UInt16(kVK_RightCommand)) == "rightCommand",
          physicalLabel(for: UInt16(kVK_RightShift)) == "rightShift",
          physicalLabel(for: UInt16(kVK_RightControl)) == "rightControl",
          physicalLabel(for: UInt16(kVK_RightOption)) == "rightOption",
          physicalLabel(for: UInt16(kVK_LeftArrow)) == "leftArrow",
          physicalLabel(for: UInt16(kVK_Home)) == "home",
          physicalLabel(for: UInt16(kVK_PageDown)) == "pageDown",
          physicalLabel(for: UInt16(kVK_ANSI_KeypadEnter)) == "keypadEnter" else {
        fputs("self-test failed: native non-printing key labels\n", stderr)
        return 1
    }

    let capsState = modifierTransition(for: UInt16(kVK_CapsLock), flags: [.capsLock])
    guard capsState.action == nil, capsState.lockState == "on" else {
        fputs("self-test failed: Caps Lock state\n", stderr)
        return 1
    }
    let bothShiftFlags = NSEvent.ModifierFlags(rawValue:
        NSEvent.ModifierFlags.shift.rawValue |
            deviceLeftShiftMask |
            deviceRightShiftMask
    )
    let leftShiftReleaseFlags = NSEvent.ModifierFlags(rawValue:
        NSEvent.ModifierFlags.shift.rawValue | deviceRightShiftMask
    )
    let rightShiftReleaseFlags = NSEvent.ModifierFlags(rawValue:
        NSEvent.ModifierFlags.shift.rawValue | deviceLeftShiftMask
    )
    guard modifierTransition(for: UInt16(kVK_Shift), flags: bothShiftFlags).action == "down",
          modifierTransition(for: UInt16(kVK_RightShift), flags: bothShiftFlags).action == "down",
          modifierTransition(for: UInt16(kVK_Shift), flags: leftShiftReleaseFlags).action == "up",
          modifierTransition(for: UInt16(kVK_RightShift), flags: rightShiftReleaseFlags).action == "up",
          modifierTransition(for: UInt16(kVK_RightShift), flags: []).action == "up" else {
        fputs("self-test failed: two-sided Shift release\n", stderr)
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
          decodedFlags["key_action"] as? String == "changed",
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
          keyRecord.object["key_action"] as? String == "down",
          !(keyRecord.object["is_repeat"] is NSNull) else {
        fputs("self-test failed: keyDown serialization\n", stderr)
        return 1
    }

    guard let keyUpCGEvent = CGEvent(keyboardEventSource: nil, virtualKey: 24, keyDown: false),
          let keyUpEvent = NSEvent(cgEvent: keyUpCGEvent),
          let keyUpRecord = keyboardEventRecord(keyUpEvent),
          keyUpRecord.object["phase"] as? String == "keyUp",
          keyUpRecord.object["key_action"] as? String == "up" else {
        fputs("self-test failed: keyUp serialization\n", stderr)
        return 1
    }

    let mediaDownData = packedSystemKeyData(
        keyCode: Int(NX_KEYTYPE_SOUND_UP),
        stateCode: Int(NX_KEYDOWN)
    )
    let mediaUpData = packedSystemKeyData(
        keyCode: Int(NX_KEYTYPE_SOUND_UP),
        stateCode: Int(NX_KEYUP)
    )
    let mediaRepeatData = packedSystemKeyData(
        keyCode: Int(NX_KEYTYPE_SOUND_UP),
        stateCode: Int(NX_KEYDOWN),
        isRepeat: true
    )
    guard let mediaDownEvent = syntheticSystemEvent(
        subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
        data1: mediaDownData,
        data2: 17
    ), let mediaDownRecord = systemKeyEventRecord(mediaDownEvent),
          mediaDownRecord.object["type"] as? String == "system_key_event",
          mediaDownRecord.object["subtype"] as? Int == Int(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
          mediaDownRecord.object["rawData1"] as? Int == mediaDownData,
          mediaDownRecord.object["rawData2"] as? Int == 17,
          mediaDownRecord.object["media_key_label"] as? String == "volumeUp",
          mediaDownRecord.object["media_key_type"] as? String == "audio",
          mediaDownRecord.object["state"] as? String == "down",
          mediaDownRecord.object["is_repeat"] as? Bool == false else {
        fputs("self-test failed: media key down decoding\n", stderr)
        return 1
    }
    guard let mediaUpEvent = syntheticSystemEvent(
        subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
        data1: mediaUpData
    ), let mediaUpRecord = systemKeyEventRecord(mediaUpEvent),
          mediaUpRecord.object["media_key_label"] as? String == "volumeUp",
          mediaUpRecord.object["state"] as? String == "up" else {
        fputs("self-test failed: media key up decoding\n", stderr)
        return 1
    }
    guard let mediaRepeatEvent = syntheticSystemEvent(
        subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
        data1: mediaRepeatData
    ), let mediaRepeatRecord = systemKeyEventRecord(mediaRepeatEvent),
          mediaRepeatRecord.object["media_key_label"] as? String == "volumeUp",
          mediaRepeatRecord.object["state"] as? String == "repeat",
          mediaRepeatRecord.object["is_repeat"] as? Bool == true else {
        fputs("self-test failed: media key repeat decoding\n", stderr)
        return 1
    }
    guard let unrelatedSystemEvent = syntheticSystemEvent(
        subtype: Int16(NX_SUBTYPE_POWER_KEY),
        data1: mediaDownData
    ), systemKeyEventRecord(unrelatedSystemEvent) == nil else {
        fputs("self-test failed: unrelated system-defined event\n", stderr)
        return 1
    }
    guard let unknownStateEvent = syntheticSystemEvent(
        subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
        data1: packedSystemKeyData(
            keyCode: Int(NX_KEYTYPE_SOUND_UP),
            stateCode: 0x7F
        )
    ), let unknownStateRecord = systemKeyEventRecord(unknownStateEvent),
          unknownStateRecord.object["media_key_label"] is NSNull,
          unknownStateRecord.object["state"] is NSNull else {
        fputs("self-test failed: unknown system-defined state\n", stderr)
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
