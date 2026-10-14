import AppKit
import Foundation
import UniformTypeIdentifiers

private enum KVVisualizerError: Error, CustomStringConvertible, LocalizedError {
    case invalidLayout(String)
    case invalidProfile(String)
    case file(String)
    case selfTest(String)

    var description: String {
        switch self {
        case .invalidLayout(let message): return "Invalid keyboard geometry: \(message)"
        case .invalidProfile(let message): return "Invalid keyboard profile: \(message)"
        case .file(let message): return message
        case .selfTest(let message): return "Keyboard visualizer self-test failed: \(message)"
        }
    }

    var errorDescription: String? { description }
}

private enum KVLayoutFamily: String, CaseIterable {
    case auto = "Auto"
    case ansi = "ANSI"
    case iso = "ISO"
    case jis = "JIS"
}

private enum KVKeyboardShape: String, CaseIterable {
    case macBook = "MacBook"
    case compact = "Compact"
    case full = "Full size"
}

private struct KVRawRect: Decodable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

private struct KVRawKey: Decodable {
    let id: String
    let label: String
    let legend: String
    let code: Int
    let rects: [KVRawRect]
}

private struct KVRawTransform: Decodable {
    let xScale: CGFloat
    let yScale: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat

    enum CodingKeys: String, CodingKey {
        case xScale = "x_scale"
        case yScale = "y_scale"
        case xOffset = "x_offset"
        case yOffset = "y_offset"
    }
}

private struct KVRawLayout: Decodable {
    let id: String
    let family: String
    let shape: String
    let baseLayout: String?
    let transform: KVRawTransform?
    let keys: [KVRawKey]?
    let replaceKeys: [KVRawKey]?
    let extraKeys: [KVRawKey]?

    enum CodingKeys: String, CodingKey {
        case id
        case family
        case shape
        case baseLayout = "base_layout"
        case transform
        case keys
        case replaceKeys = "replace_keys"
        case extraKeys = "extra_keys"
    }
}

private struct KVRawGeometry: Decodable {
    let schemaVersion: Int
    let geometryVersion: Int
    let layouts: [KVRawLayout]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case geometryVersion = "geometry_version"
        case layouts
    }
}

private struct KVKeyGeometry {
    let id: String
    let label: String
    let legend: String
    let code: Int
    let rects: [CGRect]

    var bounds: CGRect {
        rects.reduce(CGRect.null) { $0.union($1) }
    }
}

private struct KVLayoutDefinition {
    let id: String
    let family: KVLayoutFamily
    let shape: KVKeyboardShape
    let keys: [KVKeyGeometry]
    let keyByID: [String: KVKeyGeometry]
    let keyByCode: [Int: KVKeyGeometry]
    let bounds: CGRect

    init(id: String, family: KVLayoutFamily, shape: KVKeyboardShape, keys: [KVKeyGeometry]) {
        self.id = id
        self.family = family
        self.shape = shape
        self.keys = keys
        // Expanded layouts are validated before construction. Reuse their
        // indexes for every event rather than allocating maps per observation.
        keyByID = Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) })
        keyByCode = Dictionary(uniqueKeysWithValues: keys.map { ($0.code, $0) })
        bounds = keys.reduce(CGRect.null) { $0.union($1.bounds) }
    }
}

private struct KVLayoutStore {
    let schemaVersion: Int
    let geometryVersion: Int
    let layouts: [KVLayoutDefinition]
    private let byID: [String: KVLayoutDefinition]
    private let byFamilyAndShape: [String: KVLayoutDefinition]

    init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw KVVisualizerError.file("Could not read keyboard geometry: \(error.localizedDescription)")
        }

        let raw: KVRawGeometry
        do {
            raw = try JSONDecoder().decode(KVRawGeometry.self, from: data)
        } catch {
            throw KVVisualizerError.invalidLayout("JSON decoding failed: \(error.localizedDescription)")
        }
        guard raw.schemaVersion == 1 else {
            throw KVVisualizerError.invalidLayout("unsupported schema_version \(raw.schemaVersion)")
        }
        guard raw.geometryVersion == 1 else {
            throw KVVisualizerError.invalidLayout("unsupported geometry_version \(raw.geometryVersion)")
        }
        guard !raw.layouts.isEmpty, raw.layouts.count <= 32 else {
            throw KVVisualizerError.invalidLayout("layout count is outside the supported limit")
        }

        var rawByID: [String: KVRawLayout] = [:]
        for layout in raw.layouts {
            try KVLayoutStore.validateLayoutHeader(layout)
            guard rawByID[layout.id] == nil else {
                throw KVVisualizerError.invalidLayout("duplicate layout id \(layout.id)")
            }
            rawByID[layout.id] = layout
        }

        var expanded: [String: KVLayoutDefinition] = [:]
        var visiting = Set<String>()
        for layout in raw.layouts {
            _ = try KVLayoutStore.expand(
                layout.id,
                rawByID: rawByID,
                expanded: &expanded,
                visiting: &visiting
            )
        }

        let ordered = raw.layouts.compactMap { expanded[$0.id] }
        guard ordered.count == raw.layouts.count else {
            throw KVVisualizerError.invalidLayout("could not expand every layout")
        }
        let idsByFamilyShape = Dictionary(grouping: ordered) {
            "\($0.family.rawValue)-\($0.shape.rawValue)"
        }
        for family in [KVLayoutFamily.ansi, .iso, .jis] {
            for shape in KVKeyboardShape.allCases {
                let key = "\(family.rawValue)-\(shape.rawValue)"
                guard idsByFamilyShape[key]?.count == 1 else {
                    throw KVVisualizerError.invalidLayout("missing or duplicate layout for \(key)")
                }
            }
        }

        schemaVersion = raw.schemaVersion
        geometryVersion = raw.geometryVersion
        layouts = ordered
        byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        byFamilyAndShape = Dictionary(uniqueKeysWithValues: ordered.map {
            ("\($0.family.rawValue)|\($0.shape.rawValue)", $0)
        })
    }

    func layout(family: KVLayoutFamily, shape: KVKeyboardShape) -> KVLayoutDefinition {
        let requestedFamily: KVLayoutFamily = family == .auto ? .ansi : family
        let key = "\(requestedFamily.rawValue)|\(shape.rawValue)"
        guard let layout = byFamilyAndShape[key] else {
            // The initializer validates one layout for every family/shape pair.
            // This branch protects future callers if that invariant changes.
            fatalError("validated keyboard geometry is missing \(key)")
        }
        return layout
    }

    func layout(id: String) -> KVLayoutDefinition? {
        byID[id]
    }

    private static func validateLayoutHeader(_ layout: KVRawLayout) throws {
        try KVLayoutStore.validateLabel(layout.id, field: "layout id", maxLength: 80)
        guard KVLayoutFamily(rawValue: layout.family).map({ $0 != .auto }) == true else {
            throw KVVisualizerError.invalidLayout("layout \(layout.id) has invalid family \(layout.family)")
        }
        guard KVKeyboardShape(rawValue: layout.shape) != nil else {
            throw KVVisualizerError.invalidLayout("layout \(layout.id) has invalid shape \(layout.shape)")
        }
        if layout.baseLayout == nil && (layout.keys ?? []).isEmpty {
            throw KVVisualizerError.invalidLayout("base layout \(layout.id) has no keys")
        }
        if layout.baseLayout != nil && layout.keys != nil {
            throw KVVisualizerError.invalidLayout("derived layout \(layout.id) cannot contain keys; use replace_keys or extra_keys")
        }
        if let transform = layout.transform {
            guard transform.xScale.isFinite, transform.yScale.isFinite,
                  transform.xOffset.isFinite, transform.yOffset.isFinite,
                  transform.xScale > 0, transform.yScale > 0,
                  transform.xScale <= 8, transform.yScale <= 8,
                  abs(transform.xOffset) <= 100, abs(transform.yOffset) <= 100 else {
                throw KVVisualizerError.invalidLayout("layout \(layout.id) has an invalid transform")
            }
        }
    }

    private static func expand(
        _ id: String,
        rawByID: [String: KVRawLayout],
        expanded: inout [String: KVLayoutDefinition],
        visiting: inout Set<String>
    ) throws -> KVLayoutDefinition {
        if let existing = expanded[id] { return existing }
        guard let raw = rawByID[id] else {
            throw KVVisualizerError.invalidLayout("base layout \(id) does not exist")
        }
        guard visiting.insert(id).inserted else {
            throw KVVisualizerError.invalidLayout("layout inheritance cycle includes \(id)")
        }
        defer { visiting.remove(id) }

        let family = KVLayoutFamily(rawValue: raw.family)!
        let shape = KVKeyboardShape(rawValue: raw.shape)!
        var keys: [KVKeyGeometry]
        if let baseID = raw.baseLayout {
            let base = try expand(baseID, rawByID: rawByID, expanded: &expanded, visiting: &visiting)
            keys = base.keys.map { key in
                KVKeyGeometry(
                    id: key.id,
                    label: key.label,
                    legend: key.legend,
                    code: key.code,
                    rects: key.rects.map { rect in
                        let transform = raw.transform
                        return CGRect(
                            x: rect.origin.x * (transform?.xScale ?? 1) + (transform?.xOffset ?? 0),
                            y: rect.origin.y * (transform?.yScale ?? 1) + (transform?.yOffset ?? 0),
                            width: rect.width * (transform?.xScale ?? 1),
                            height: rect.height * (transform?.yScale ?? 1)
                        )
                    }
                )
            }
            if let replacements = raw.replaceKeys {
                for replacement in replacements {
                    try validateKey(replacement, layoutID: raw.id)
                    guard let index = keys.firstIndex(where: { $0.id == replacement.id }) else {
                        throw KVVisualizerError.invalidLayout("layout \(raw.id) replaces missing key \(replacement.id)")
                    }
                    keys[index] = makeGeometry(replacement)
                }
            }
            if let extras = raw.extraKeys {
                for extra in extras {
                    try validateKey(extra, layoutID: raw.id)
                    guard !keys.contains(where: { $0.id == extra.id }) else {
                        throw KVVisualizerError.invalidLayout("layout \(raw.id) duplicates key id \(extra.id)")
                    }
                    keys.append(makeGeometry(extra))
                }
            }
        } else {
            keys = try (raw.keys ?? []).map {
                try validateKey($0, layoutID: raw.id)
                return makeGeometry($0)
            }
        }

        try validateExpandedKeys(keys, layoutID: raw.id)
        let result = KVLayoutDefinition(id: raw.id, family: family, shape: shape, keys: keys)
        expanded[id] = result
        return result
    }

    @discardableResult
    private static func validateKey(_ key: KVRawKey, layoutID: String) throws -> Bool {
        try validateLabel(key.id, field: "key id in \(layoutID)", maxLength: 80)
        try validateLabel(key.label, field: "key label \(key.id)", maxLength: 120)
        try validateLabel(key.legend, field: "key legend \(key.id)", maxLength: 80)
        guard key.code >= 0, key.code <= 65535 else {
            throw KVVisualizerError.invalidLayout("key \(key.id) has unsafe keycode \(key.code)")
        }
        guard !key.rects.isEmpty, key.rects.count <= 8 else {
            throw KVVisualizerError.invalidLayout("key \(key.id) has an invalid rect count")
        }
        for rect in key.rects {
            guard rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite,
                  rect.x >= -100, rect.y >= -100,
                  rect.width > 0, rect.height > 0,
                  rect.width <= 20, rect.height <= 20,
                  rect.x + rect.width <= 200, rect.y + rect.height <= 200 else {
                throw KVVisualizerError.invalidLayout("key \(key.id) has invalid geometry")
            }
        }
        return true
    }

    private static func makeGeometry(_ key: KVRawKey) -> KVKeyGeometry {
        KVKeyGeometry(
            id: key.id,
            label: key.label,
            legend: key.legend,
            code: key.code,
            rects: key.rects.map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
        )
    }

    private static func validateExpandedKeys(_ keys: [KVKeyGeometry], layoutID: String) throws {
        guard !keys.isEmpty, keys.count <= 160 else {
            throw KVVisualizerError.invalidLayout("layout \(layoutID) has an invalid key count")
        }
        var ids = Set<String>()
        var codes = Set<Int>()
        for key in keys {
            guard ids.insert(key.id).inserted else {
                throw KVVisualizerError.invalidLayout("layout \(layoutID) duplicates key id \(key.id)")
            }
            guard codes.insert(key.code).inserted else {
                throw KVVisualizerError.invalidLayout("layout \(layoutID) duplicates native keycode \(key.code)")
            }
            let bounds = key.bounds
            guard bounds.isNull == false,
                  bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                  bounds.size.width.isFinite, bounds.size.height.isFinite else {
                throw KVVisualizerError.invalidLayout("layout \(layoutID) has non-finite bounds")
            }
        }
        for (index, key) in keys.enumerated() {
            for other in keys.dropFirst(index + 1) {
                for rect in key.rects {
                    for otherRect in other.rects {
                        let overlap = rect.intersection(otherRect)
                        guard overlap.isNull || overlap.width * overlap.height < 0.0001 else {
                            throw KVVisualizerError.invalidLayout(
                                "layout \(layoutID) overlaps positions \(key.id) and \(other.id)"
                            )
                        }
                    }
                }
            }
        }
    }

    fileprivate static func validateLabel(_ value: String, field: String, maxLength: Int) throws {
        guard !value.isEmpty, value.count <= maxLength else {
            throw KVVisualizerError.invalidLayout("\(field) must be non-empty and at most \(maxLength) characters")
        }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw KVVisualizerError.invalidLayout("\(field) contains a control character")
        }
    }
}

private enum KVNativeKeyNames {
    // Apple virtual key identities are physical positions. Produced characters are
    // intentionally absent from this table.
    static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "ISO Section", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "Equal", 25: "9", 26: "7", 27: "Minus",
        28: "8", 29: "0", 30: "Right Bracket", 31: "O", 32: "U", 33: "Left Bracket",
        34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "Quote", 40: "K",
        41: "Semicolon", 42: "Backslash", 43: "Comma", 44: "Slash", 45: "N",
        46: "M", 47: "Period", 48: "Tab", 49: "Space", 50: "Grave", 51: "Delete",
        52: "Keypad Enter", 53: "Escape", 54: "Right Command", 55: "Left Command",
        56: "Left Shift", 57: "Caps Lock", 58: "Left Option", 59: "Left Control",
        60: "Right Shift", 61: "Right Option", 62: "Right Control", 63: "Fn",
        64: "F17", 65: "Keypad Decimal", 67: "Keypad Multiply", 69: "Keypad Plus", 78: "Keypad Minus",
        71: "Keypad Clear", 72: "Volume Up", 73: "Volume Down", 74: "Mute",
        75: "Keypad Divide", 76: "Keypad Enter", 79: "F18", 80: "F19",
        81: "Keypad Equals", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2",
        85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
        89: "Keypad 7", 90: "F20", 91: "Keypad 8", 92: "Keypad 9",
        93: "JIS Yen", 94: "JIS Ro", 95: "JIS Keypad Comma", 96: "F5",
        97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 102: "JIS Eisu",
        103: "F11", 104: "JIS Kana", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home",
        116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2",
        121: "Page Down", 122: "F1", 123: "Left Arrow", 124: "Right Arrow",
        125: "Down Arrow", 126: "Up Arrow"
    ]

    static func name(for code: Int, eventLabel: String? = nil) -> String {
        if let name = names[code] { return name }
        if let eventLabel, !eventLabel.isEmpty { return eventLabel }
        return String(format: "Virtual key 0x%02X", code)
    }
}

private enum KVNativeMediaNames {
    static let names: [Int: String] = [
        0: "Volume Up", 1: "Volume Down", 2: "Brightness Up", 3: "Brightness Down",
        4: "Caps Lock", 5: "Help", 6: "Power", 7: "Mute", 8: "Up Arrow",
        9: "Down Arrow", 10: "Num Lock", 11: "Contrast Up", 12: "Contrast Down",
        13: "Launch Panel", 14: "Eject", 15: "Video Mirror", 16: "Play",
        17: "Next", 18: "Previous", 19: "Fast Forward", 20: "Rewind",
        21: "Keyboard Illumination Up", 22: "Keyboard Illumination Down",
        23: "Keyboard Illumination Toggle", 24: "Menu"
    ]
}

private struct KVKeyObservation {
    var identity: String
    var code: Int
    var automaticName: String
    var observedCount = 0
    var pressCount = 0
    var releaseCount = 0
    var repeatCount = 0
    var held = false
    var lastAction: String?
    var lastCharacters: String?
    var lastScalars: [String] = []
    var lastModifiers: [String] = []
    var lastSequence: Int?
}

private struct KVAnnotation {
    let namespace: String
    let code: Int
    let identity: String
    var label: String
    var assignedKeyID: String?
}

private struct KVTableRow {
    let identity: String
    let namespace: String
    let name: String
    let code: Int
    let count: Int
    let repeatCount: Int
}

private func kvIdentity(namespace: String, code: Int) -> String {
    "\(namespace):\(code)"
}

private func kvValueString(_ object: Any?, defaultValue: String? = nil) -> String? {
    if let string = object as? String { return string }
    return defaultValue
}

private func kvValueInt(_ object: Any?) -> Int? {
    if let value = object as? Int { return value }
    if let value = object as? NSNumber { return value.intValue }
    return nil
}

private func kvStrictJSONInt(_ object: Any?) -> Int? {
    // JSONSerialization bridges both booleans and integers to NSNumber on
    // macOS. Its `c` objCType identifies the boolean representation here;
    // checking `object is Bool` would also reject valid q/i integer values.
    guard let number = object as? NSNumber else { return nil }
    let type = String(cString: number.objCType)
    guard ["i", "s", "l", "q", "I", "S", "L", "Q"].contains(type) else {
        return nil
    }
    let value = number.int64Value
    guard Int64(Int(value)) == value else { return nil }
    return Int(value)
}

private func kvValueBool(_ object: Any?) -> Bool? {
    if let value = object as? Bool { return value }
    if let value = object as? NSNumber { return value.boolValue }
    return nil
}

private func kvValueStrings(_ object: Any?) -> [String] {
    (object as? [Any])?.compactMap { $0 as? String } ?? (object as? [String]) ?? []
}

private func kvJSONData(_ object: Any, pretty: Bool = false) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
        throw KVVisualizerError.file("Could not encode keyboard visualizer JSON")
    }
    var options: JSONSerialization.WritingOptions = [.sortedKeys]
    if pretty { options.insert(.prettyPrinted) }
    do {
        return try JSONSerialization.data(withJSONObject: object, options: options)
    } catch {
        throw KVVisualizerError.file("Could not encode keyboard visualizer JSON: \(error.localizedDescription)")
    }
}

private func kvWriteJSONAtomically(_ object: Any, to url: URL) throws {
    let data = try kvJSONData(object, pretty: true)
    let fileManager = FileManager.default
    let directory = url.deletingLastPathComponent()
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        throw KVVisualizerError.file("Could not create output directory: \(error.localizedDescription)")
    }

    let temporaryURL = directory.appendingPathComponent(
        ".\(url.lastPathComponent).tmp-\(UUID().uuidString)"
    )
    do {
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    } catch {
        try? fileManager.removeItem(at: temporaryURL)
        throw KVVisualizerError.file("Could not write \(url.lastPathComponent) atomically: \(error.localizedDescription)")
    }
}

private struct KVVisualizerSnapshot {
    let layout: KVLayoutDefinition
    let familySelection: KVLayoutFamily
    let capsLockState: String?
    let selectedKeyID: String?
    let selectedIdentity: String?
    let awaitingAssignment: Bool
    let keyStates: [String: KVKeyObservation]
    let tableRows: [KVTableRow]
    let detailText: String
    let statusText: String
    let errorText: String?
    let isError: Bool
}

final class KeyboardVisualizerController: NSObject {
    let view: NSView

    var onReset: (() -> Void)?
    var onAnnotation: (([String: Any]) -> Void)?

    private let layoutStore: KVLayoutStore
    private let rootView: KVVisualizerRootView
    private var manualFamily: KVLayoutFamily = .auto
    private var autoFamily: KVLayoutFamily = .ansi
    private var shape: KVKeyboardShape = .macBook
    private var selectedKeyID: String?
    private var selectedIdentity: String?
    private var awaitingAssignment = false

    private var keyStates: [String: KVKeyObservation] = [:]
    private var identityStates: [String: KVKeyObservation] = [:]
    private var unknownStates: [String: KVKeyObservation] = [:]
    private var extraStates: [String: KVKeyObservation] = [:]
    private var knownMediaIdentities = Set<String>()
    private var annotations: [String: KVAnnotation] = [:]
    private var heldIdentities = Set<String>()
    private var capsLockState: String?

    private var rawRecords: [[String: Any]] = []
    private var rawRecordBytes = 0
    private var rawRecordsOmitted = 0
    private var observedRecordCount = 0
    private var sessionMetadata: [String: Any] = [:]
    private var lastEventType: String?
    private var errorText: String?
    private var isError = false

    // Keep enough of a normal keyboard + IME session to make the report useful.
    // Both bounds are deliberate so a pathological stream remains bounded by
    // either record count or serialized byte size.
    private static let maxRawRecords = 4096
    private static let maxRawBytes = 4 * 1024 * 1024

    init(layoutURL: URL) throws {
        let store = try KVLayoutStore(url: layoutURL)
        layoutStore = store
        let root = KVVisualizerRootView()
        rootView = root
        view = root
        super.init()
        root.owner = self
        root.installControls()
        root.refresh(snapshot: makeSnapshot())
    }

    func observe(_ record: [String: Any]) {
        appendRawRecord(record)
        observedRecordCount += 1
        let type = kvValueString(record["type"])
        lastEventType = type

        if type == "session_started" {
            sessionMetadata = record
            updateAutoFamily(from: record)
        } else {
            updateAutoFamily(from: record)
        }

        switch type {
        case "keyboard_event":
            observeKeyboardEvent(record)
        case "system_key_event":
            observeSystemKeyEvent(record)
        case "capture_paused":
            clearHeldKeys()
        case "capture_resumed":
            break
        case "committed_text", "marked_text", "session_started", nil:
            break
        default:
            break
        }
        refreshView()
    }

    static func runSelfTests(layoutURL: URL) throws {
        let store = try KVLayoutStore(url: layoutURL)
        guard store.layouts.count == 9 else {
            throw KVVisualizerError.selfTest("expected nine family/shape layouts")
        }
        for layout in store.layouts {
            guard !layout.keys.isEmpty else {
                throw KVVisualizerError.selfTest("layout \(layout.id) is empty")
            }
            _ = try KVProfileValidator.parse(data: kvJSONData([
                "profile_version": 1, "geometry_version": store.geometryVersion,
                "layout_id": layout.id, "layout_family": layout.family.rawValue,
                "shape": layout.shape.rawValue, "annotations": []
            ]), store: store)
        }

        let jis = store.layout(family: .jis, shape: .macBook)
        let compact = store.layout(family: .ansi, shape: .compact)
        let full = store.layout(family: .ansi, shape: .full)
        guard jis.keyByCode[93]?.id == "jisYen",
              jis.keyByCode[94]?.id == "jisRo",
              jis.keyByCode[102]?.id == "jisEisu",
              jis.keyByCode[104]?.id == "jisKana",
              KVNativeKeyNames.name(for: 93) == "JIS Yen",
              full.id == "ANSI-Full",
              compact.keyByID["home"] != nil,
              store.layout(family: .jis, shape: .full).keyByCode[95]?.id == "jisKeypadComma" else {
            throw KVVisualizerError.selfTest("JIS physical identities are incomplete")
        }
        guard KVNativeKeyNames.name(for: 93) != "¥" else {
            throw KVVisualizerError.selfTest("JIS identity was conflated with produced text")
        }

        let controller = try KeyboardVisualizerController(layoutURL: layoutURL)
        var resetCalled = false
        controller.onReset = { resetCalled = true }

        controller.observe([
            "type": "session_started",
            "sequence": 1,
            "lm_kbd_layout_type": "JIS",
            "input_source": ["layout_type": "ANSI"]
        ])
        guard controller.autoFamily == .jis, controller.effectiveLayout.family == .jis else {
            throw KVVisualizerError.selfTest("automatic JIS layout selection failed")
        }

        controller.observe([
            "type": "keyboard_event", "sequence": 2, "phase": "keyDown",
            "hardware_key_code": 0, "key_action": "down", "is_repeat": false,
            "characters": "a", "characters_unicode_scalars": ["U+0061"],
            "modifier_flags_names": ["none"]
        ])
        controller.observe([
            "type": "keyboard_event", "sequence": 3, "phase": "keyDown",
            "hardware_key_code": 0, "key_action": "down", "is_repeat": true,
            "characters": "a", "characters_unicode_scalars": ["U+0061"],
            "modifier_flags_names": ["none"]
        ])
        controller.observe([
            "type": "keyboard_event", "sequence": 4, "phase": "keyUp",
            "hardware_key_code": 0, "key_action": "up", "is_repeat": false,
            "characters": "a", "characters_unicode_scalars": ["U+0061"],
            "modifier_flags_names": ["none"]
        ])
        controller.observe([
            "type": "keyboard_event", "sequence": 5, "phase": "keyUp",
            "hardware_key_code": 1, "key_action": "up", "is_repeat": false,
            "characters": "s", "characters_unicode_scalars": ["U+0073"],
            "modifier_flags_names": ["none"]
        ])
        let aState = controller.identityStates["key:0"]
        guard aState?.pressCount == 1,
              aState?.repeatCount == 1,
              aState?.held == false,
              controller.identityStates["key:1"]?.pressCount == 0 else {
            throw KVVisualizerError.selfTest("repeat/up accounting failed")
        }
        controller.observe([
            "type": "keyboard_event", "sequence": 5,
            "hardware_key_code": 57, "key_action": "changed",
            "modifier_lock_state": "on", "is_repeat": false
        ])
        guard controller.capsLockState == "on",
              controller.identityStates["key:57"]?.pressCount == 0,
              controller.identityStates["key:57"]?.held == false else {
            throw KVVisualizerError.selfTest("ambiguous Caps Lock transition was counted as a press")
        }

        controller.observe([
            "type": "keyboard_event", "sequence": 6, "phase": "keyDown",
            "hardware_key_code": 2, "key_action": "down", "is_repeat": false,
            "characters": "d", "modifier_flags_names": ["none"]
        ])
        guard controller.heldIdentities.contains("key:2") else {
            throw KVVisualizerError.selfTest("key down did not mark held")
        }
        controller.observe(["type": "capture_paused", "sequence": 7])
        guard controller.heldIdentities.isEmpty,
              controller.identityStates["key:2"]?.held == false else {
            throw KVVisualizerError.selfTest("focus loss did not clear held keys")
        }

        controller.observe([
            "type": "system_key_event", "sequence": 8,
            "media_key_code": 999, "state": "down", "is_repeat": false
        ])
        controller.observe([
            "type": "system_key_event", "sequence": 9,
            "media_key_code": 999, "state": "repeat", "is_repeat": true
        ])
        controller.observe([
            "type": "keyboard_event", "sequence": 10, "phase": "keyDown",
            "hardware_key_code": 999, "key_action": "down", "is_repeat": false
        ])
        controller.observe([
            "type": "keyboard_event", "sequence": 10, "phase": "keyDown",
            "hardware_key_code": 114, "key_action": "down", "is_repeat": false
        ])
        controller.observe([
            "type": "system_key_event", "sequence": 11,
            "media_key_code": 0, "media_key_label": "volumeUp",
            "state": "down", "is_repeat": false
        ])
        guard controller.unknownStates.count == 2,
              controller.unknownStates["media:999"]?.repeatCount == 1,
              controller.unknownStates["key:999"]?.pressCount == 1,
              controller.extraStates["key:114"]?.pressCount == 1,
              controller.extraStates["media:0"]?.pressCount == 1 else {
            throw KVVisualizerError.selfTest("unknown/media namespace deduplication failed")
        }

        controller.setFamily(.ansi)
        controller.setShape(.full)
        guard controller.keyStates["help"]?.identity == "key:114",
              controller.extraStates["key:114"] == nil else {
            throw KVVisualizerError.selfTest("family/shape rebuild failed")
        }

        controller.selectedIdentity = "media:999"
        controller.renameSelectedUnknown(to: "Mystery media")
        controller.assignSelectedUnknown(to: "space")
        controller.selectedIdentity = "media:0"
        controller.renameSelectedUnknown(to: "Volume control")
        controller.assignSelectedUnknown(to: "space")
        controller.observe([
            "type": "system_key_event", "sequence": 12,
            "media_key_code": 0, "media_key_label": "volumeUp",
            "state": "up", "is_repeat": false
        ])
        guard controller.keyStates["space"]?.pressCount == 2,
              controller.keyStates["space"]?.held == true else {
            throw KVVisualizerError.selfTest("assigned keys lost combined history or held state")
        }
        let profile = controller.profileObject()
        let profileData = try kvJSONData(profile)
        controller.clearAnnotationsForTest()
        try controller.applyProfileData(profileData)
        guard controller.annotations["media:999"]?.label == "Mystery media",
              controller.annotations["media:999"]?.assignedKeyID == "space",
              controller.annotations["media:0"]?.label == "Volume control",
              controller.keyStates["space"]?.pressCount == 2,
              controller.keyStates["space"]?.identity == "media:0" else {
            throw KVVisualizerError.selfTest("profile round trip failed")
        }

        let malformedProfiles: [[String: Any]] = [
            [:],
            ["profile_version": 1, "geometry_version": 1, "layout_id": "ANSI-MacBook",
             "layout_family": "ANSI", "shape": "MacBook", "annotations": [[
                 "namespace": "key", "raw_code": 1, "identity": "key:1", "label": "bad\nlabel"
             ]]],
            ["profile_version": true, "geometry_version": 1, "layout_id": "ANSI-MacBook",
             "layout_family": "ANSI", "shape": "MacBook", "annotations": []],
            ["profile_version": 1, "geometry_version": 1.5, "layout_id": "ANSI-MacBook",
             "layout_family": "ANSI", "shape": "MacBook", "annotations": []],
            ["profile_version": 1, "geometry_version": 1, "layout_id": "ANSI-MacBook",
             "layout_family": "ANSI", "shape": "MacBook", "annotations": [[
                 "namespace": "key", "raw_code": 1.5, "identity": "key:1", "label": "fraction"
             ]]]
        ]
        for malformed in malformedProfiles {
            do {
                try controller.applyProfileData(try kvJSONData(malformed))
                throw KVVisualizerError.selfTest("malformed profile was accepted")
            } catch let error as KVVisualizerError {
                if case .selfTest = error { throw error }
            }
        }

        for sequence in 0..<(Self.maxRawRecords + 32) {
            controller.observe([
                "type": "committed_text", "sequence": 1000 + sequence,
                "text": "overflow-\(sequence)"
            ])
        }
        let report = controller.reportObject()
        guard controller.rawRecords.count <= Self.maxRawRecords,
              controller.rawRecordsOmitted > 0,
              kvValueInt((report["raw_records_omitted"] as? Int)) == controller.rawRecordsOmitted else {
            throw KVVisualizerError.selfTest("bounded report history failed")
        }

        controller.resetTest()
        let resetReport = controller.reportObject()
        let resetMetadata = resetReport["session_metadata"] as? [String: Any]
        guard resetCalled,
              controller.identityStates.isEmpty,
              controller.rawRecords.isEmpty,
              controller.heldIdentities.isEmpty,
              controller.sessionMetadata["lm_kbd_layout_type"] as? String == "JIS",
              resetMetadata?["lm_kbd_layout_type"] as? String == "JIS" else {
            throw KVVisualizerError.selfTest("reset did not clear visualizer state")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rustadmin-keyboard-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("profile.json")
        try kvWriteJSONAtomically(controller.profileObject(), to: destination)
        try controller.applyProfileData(Data(contentsOf: destination))
        try kvWriteJSONAtomically(resetReport, to: destination)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
        guard kvStrictJSONInt(written?["report_version"]) == 1 else {
            throw KVVisualizerError.selfTest("atomic export/replacement failed")
        }
    }

    private var effectiveFamily: KVLayoutFamily {
        manualFamily == .auto ? autoFamily : manualFamily
    }

    private var effectiveLayout: KVLayoutDefinition {
        layoutStore.layout(family: effectiveFamily, shape: shape)
    }

    private func appendRawRecord(_ record: [String: Any]) {
        let bytes = (try? kvJSONData(record).count) ?? 0
        rawRecords.append(record)
        rawRecordBytes += bytes
        while rawRecords.count > Self.maxRawRecords || rawRecordBytes > Self.maxRawBytes {
            guard !rawRecords.isEmpty else { break }
            let removed = rawRecords.removeFirst()
            rawRecordBytes -= (try? kvJSONData(removed).count) ?? 0
            rawRecordsOmitted += 1
        }
    }

    private func updateAutoFamily(from record: [String: Any]) {
        let candidates: [String?] = [
            kvValueString(record["event_cg_keyboard_layout_type"]),
            kvValueString(record["lm_kbd_layout_type"])
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            let normalized = candidate.uppercased()
            let family: KVLayoutFamily?
            if normalized.contains("JIS") {
                family = .jis
            } else if normalized.contains("ISO") {
                family = .iso
            } else if normalized.contains("ANSI") {
                family = .ansi
            } else {
                family = nil
            }
            if let family {
                if autoFamily != family {
                    autoFamily = family
                    rebuildDisplayState()
                }
                return
            }
        }
    }

    private func observeKeyboardEvent(_ record: [String: Any]) {
        guard let code = kvValueInt(record["hardware_key_code"]), (0...65535).contains(code) else {
            return
        }
        let identity = kvIdentity(namespace: "key", code: code)
        let automaticName = KVNativeKeyNames.name(
            for: code,
            eventLabel: kvValueString(record["hardware_position_label"])
        )
        _ = updateObservation(
            identity: identity,
            code: code,
            automaticName: automaticName,
            record: record,
            isMedia: false
        )
        rebuildDisplayState()
    }

    private func observeSystemKeyEvent(_ record: [String: Any]) {
        guard let code = kvValueInt(record["media_key_code"]), (0...65535).contains(code) else {
            return
        }
        let identity = kvIdentity(namespace: "media", code: code)
        let eventLabel = kvValueString(record["media_key_label"])
        let automaticName = eventLabel ?? KVNativeMediaNames.names[code] ?? "Media key \(code)"
        if eventLabel != nil || KVNativeMediaNames.names[code] != nil {
            knownMediaIdentities.insert(identity)
        }
        _ = updateObservation(
            identity: identity,
            code: code,
            automaticName: automaticName,
            record: record,
            isMedia: true
        )
        rebuildDisplayState()
    }

    private func updateObservation(
        identity: String,
        code: Int,
        automaticName: String,
        record: [String: Any],
        isMedia: Bool
    ) -> KVKeyObservation {
        var state = identityStates[identity] ?? KVKeyObservation(
            identity: identity,
            code: code,
            automaticName: automaticName
        )
        state.automaticName = automaticName
        state.observedCount += 1
        state.lastAction = kvValueString(record["key_action"]) ?? kvValueString(record["state"])
        if state.lastAction == nil, kvValueString(record["phase"]) == "keyDown" {
            state.lastAction = "down"
        }
        if state.lastAction == nil, kvValueString(record["phase"]) == "keyUp" {
            state.lastAction = "up"
        }
        if let characters = record["characters"] as? String {
            state.lastCharacters = characters
        } else if !isMedia {
            state.lastCharacters = nil
        }
        if let scalars = record["characters_unicode_scalars"] as? [String] {
            state.lastScalars = scalars
        } else if !isMedia {
            state.lastScalars = []
        }
        state.lastModifiers = kvValueStrings(record["modifier_flags_names"])
        state.lastSequence = kvValueInt(record["sequence"])

        let action = state.lastAction
        let isRepeat = kvValueBool(record["is_repeat"]) == true || action == "repeat"
        let isCapsLock = !isMedia && (code == 57 ||
            KVNativeKeyNames.name(for: code).lowercased().contains("caps lock"))
        if let lockState = kvValueString(record["modifier_lock_state"]), isCapsLock {
            capsLockState = lockState
        }
        if isCapsLock {
            // Caps Lock state is a lock observation, not a held physical key.
            // Count only explicit key actions; a flagsChanged "changed" event
            // must not become an inferred press.
            if action == "down", !isRepeat {
                state.pressCount += 1
            } else if action == "up" {
                state.releaseCount += 1
            }
            state.held = false
            heldIdentities.remove(identity)
        } else if isRepeat {
            state.repeatCount += 1
        } else if action == "down" {
            if !state.held {
                state.pressCount += 1
            }
            state.held = true
            heldIdentities.insert(identity)
        } else if action == "up" {
            if state.held {
                state.releaseCount += 1
            }
            state.held = false
            heldIdentities.remove(identity)
        }
        identityStates[identity] = state
        return state
    }

    private func clearHeldKeys() {
        for identity in heldIdentities {
            if var state = identityStates[identity] {
                state.held = false
                identityStates[identity] = state
            }
        }
        heldIdentities.removeAll()
        rebuildDisplayState()
    }

    private func rebuildDisplayState() {
        keyStates.removeAll(keepingCapacity: true)
        unknownStates.removeAll(keepingCapacity: true)
        extraStates.removeAll(keepingCapacity: true)

        for state in identityStates.values {
            let identity = state.identity
            let assignedKeyID = annotations[identity]?.assignedKeyID
            if identity.hasPrefix("media:") {
                if knownMediaIdentities.contains(identity) {
                    extraStates[identity] = state
                } else {
                    unknownStates[identity] = state
                }
                if let assignedKeyID {
                    place(state, at: assignedKeyID)
                }
                continue
            }

            if let assignedKeyID {
                // A saved assignment is an explicit placement decision and
                // wins over the currently selected template's native code map.
                place(state, at: assignedKeyID)
                if KVNativeKeyNames.names[state.code] != nil {
                    extraStates[identity] = state
                } else {
                    unknownStates[identity] = state
                }
            } else if let layoutKey = effectiveLayout.keyByCode[state.code] {
                place(state, at: layoutKey.id)
            } else if KVNativeKeyNames.names[state.code] != nil {
                extraStates[identity] = state
            } else {
                unknownStates[identity] = state
            }
        }
    }

    private func place(_ state: KVKeyObservation, at keyID: String) {
        guard effectiveLayout.keyByID[keyID] != nil else { return }
        guard let existing = keyStates[keyID] else {
            keyStates[keyID] = state
            return
        }
        var merged = (state.lastSequence ?? 0) >= (existing.lastSequence ?? 0) ? state : existing
        merged.observedCount = existing.observedCount + state.observedCount
        merged.pressCount = existing.pressCount + state.pressCount
        merged.releaseCount = existing.releaseCount + state.releaseCount
        merged.repeatCount = existing.repeatCount + state.repeatCount
        merged.held = existing.held || state.held
        keyStates[keyID] = merged
    }

    private func refreshView() {
        rootView.refresh(snapshot: makeSnapshot())
    }

    private func makeSnapshot() -> KVVisualizerSnapshot {
        let rows = (unknownStates.values.map {
            KVTableRow(
                identity: $0.identity,
                namespace: "Unknown",
                name: annotations[$0.identity]?.label ?? $0.automaticName,
                code: $0.code,
                count: $0.pressCount,
                repeatCount: $0.repeatCount
            )
        } + extraStates.values.map {
            KVTableRow(
                identity: $0.identity,
                namespace: "Extra",
                name: annotations[$0.identity]?.label ?? $0.automaticName,
                code: $0.code,
                count: $0.pressCount,
                repeatCount: $0.repeatCount
            )
        }).sorted { $0.identity < $1.identity }

        let detail = detailText()
        let mode = manualFamily == .auto ? "Auto→\(effectiveFamily.rawValue)" : "Manual \(effectiveFamily.rawValue)"
        let pressedKeys = keyStates.values.filter { $0.pressCount > 0 }.count
        let status = "\(mode) · \(shape.rawValue) · keys pressed \(pressedKeys)/\(effectiveLayout.keys.count) · unknown \(unknownStates.count) · extra \(extraStates.count)"
        return KVVisualizerSnapshot(
            layout: effectiveLayout,
            familySelection: manualFamily,
            capsLockState: capsLockState,
            selectedKeyID: selectedKeyID,
            selectedIdentity: selectedIdentity,
            awaitingAssignment: awaitingAssignment,
            keyStates: keyStates,
            tableRows: rows,
            detailText: detail,
            statusText: status,
            errorText: errorText,
            isError: isError
        )
    }

    private func detailText() -> String {
        if let identity = selectedIdentity,
           let state = identityStates[identity] {
            return formatDetails(
                title: annotations[identity]?.label ?? state.automaticName,
                state: state,
                assignment: annotations[identity]?.assignedKeyID
            )
        }
        if let keyID = selectedKeyID,
           let key = effectiveLayout.keyByID[keyID] {
            if let state = keyStates[keyID] {
                return formatDetails(title: key.label, state: state, assignment: nil)
            }
            return "\(key.label)\nraw key code: \(key.code)\naction: unobserved\nobserved: 0 · presses: 0 · repeats: 0"
        }
        return "Click a key to inspect it. Additional keys appear in the Unknown / extra keys list."
    }

    private func formatDetails(title: String, state: KVKeyObservation, assignment: String?) -> String {
        let chars: String
        if let value = state.lastCharacters {
            chars = value.isEmpty ? "empty" : String(reflecting: value)
        } else {
            chars = "unavailable"
        }
        let scalars = state.lastScalars.isEmpty ? "none" : state.lastScalars.joined(separator: ", ")
        let modifiers = state.lastModifiers.isEmpty ? "none" : state.lastModifiers.joined(separator: ", ")
        let assigned = assignment.map { "\nassigned position: \($0)" } ?? ""
        return "\(title) · \(state.identity)\nraw numeric code: \(state.code)\naction: \(state.lastAction ?? "observed") · held: \(state.held)\nchars: \(chars)\nUnicode: \(scalars)\nmodifiers: \(modifiers)\nobserved: \(state.observedCount) · presses: \(state.pressCount) · releases: \(state.releaseCount) · repeats: \(state.repeatCount)\(assigned)"
    }

    fileprivate func setFamily(_ family: KVLayoutFamily) {
        manualFamily = family
        selectedKeyID = nil
        selectedIdentity = nil
        awaitingAssignment = false
        rebuildDisplayState()
        refreshView()
    }

    fileprivate func setShape(_ shape: KVKeyboardShape) {
        self.shape = shape
        selectedKeyID = nil
        selectedIdentity = nil
        awaitingAssignment = false
        rebuildDisplayState()
        refreshView()
    }

    fileprivate func selectKey(_ keyID: String) {
        if awaitingAssignment, let identity = selectedIdentity, identityStates[identity] != nil {
            assignSelectedUnknown(to: keyID)
            awaitingAssignment = false
            selectedKeyID = keyID
            refreshView()
            return
        }
        selectedKeyID = keyID
        selectedIdentity = nil
        refreshView()
    }

    fileprivate func selectIdentity(_ identity: String) {
        selectedIdentity = identity
        selectedKeyID = nil
        refreshView()
    }

    fileprivate func beginAssignment() {
        guard let identity = selectedIdentity, identityStates[identity] != nil else {
            showError("Select a key in the Unknown / extra keys list before assigning its position.")
            return
        }
        awaitingAssignment = true
        isError = false
        errorText = "Click a keyboard key to assign \(identity) to that position."
        refreshView()
    }

    fileprivate func renameSelectedUnknown(to label: String? = nil) {
        guard let identity = selectedIdentity, let state = identityStates[identity] else {
            showError("Select a key in the Unknown / extra keys list before naming it.")
            return
        }
        if let label {
            do {
                try KVLayoutStore.validateLabel(label, field: "annotation label", maxLength: 80)
            } catch {
                showError(error.localizedDescription)
                return
            }
            var annotation = annotations[identity] ?? KVAnnotation(
                namespace: identity.hasPrefix("media:") ? "media" : "key",
                code: state.code,
                identity: identity,
                label: state.automaticName,
                assignedKeyID: nil
            )
            annotation.label = label
            annotations[identity] = annotation
            errorText = nil
            emitAnnotation([
                "type": "visualizer_annotation",
                "annotation_action": "rename",
                "namespace": annotation.namespace,
                "raw_code": annotation.code,
                "identity": identity,
                "label": label
            ])
            refreshView()
            return
        }
        rootView.presentRenamePrompt(defaultValue: annotations[identity]?.label ?? state.automaticName) { [weak self] value in
            self?.renameSelectedUnknown(to: value)
        }
    }

    fileprivate func assignSelectedUnknown(to keyID: String) {
        guard let identity = selectedIdentity, let state = identityStates[identity] else {
            showError("Select a key in the Unknown / extra keys list before assigning its position.")
            return
        }
        guard effectiveLayout.keyByID[keyID] != nil else {
            showError("The selected keyboard position is not present in this layout.")
            return
        }
        var annotation = annotations[identity] ?? KVAnnotation(
            namespace: identity.hasPrefix("media:") ? "media" : "key",
            code: state.code,
            identity: identity,
            label: state.automaticName,
            assignedKeyID: nil
        )
        annotation.assignedKeyID = keyID
        annotations[identity] = annotation
        rebuildDisplayState()
        selectedKeyID = keyID
        errorText = nil
        emitAnnotation([
            "type": "visualizer_annotation",
            "annotation_action": "assign",
            "namespace": annotation.namespace,
            "raw_code": annotation.code,
            "identity": identity,
            "assigned_key_id": keyID
        ])
        refreshView()
    }

    private func emitAnnotation(_ object: [String: Any]) {
        onAnnotation?(object)
    }

    fileprivate func resetTest() {
        keyStates.removeAll()
        identityStates.removeAll()
        unknownStates.removeAll()
        extraStates.removeAll()
        heldIdentities.removeAll()
        knownMediaIdentities.removeAll()
        rawRecords.removeAll()
        rawRecordBytes = 0
        rawRecordsOmitted = 0
        observedRecordCount = 0
        lastEventType = nil
        capsLockState = nil
        selectedKeyID = nil
        selectedIdentity = nil
        awaitingAssignment = false
        errorText = nil
        refreshView()
        onReset?()
    }

    private func showError(_ message: String) {
        isError = true
        errorText = message
        refreshView()
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keyboard visualizer"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    private func clearAnnotationsForTest() {
        annotations.removeAll()
        rebuildDisplayState()
    }

    private func profileObject() -> [String: Any] {
        let profileAnnotations = annotations.values.sorted { $0.identity < $1.identity }.map { annotation in
            var object: [String: Any] = [
                "namespace": annotation.namespace,
                "raw_code": annotation.code,
                "identity": annotation.identity,
                "label": annotation.label
            ]
            if let assigned = annotation.assignedKeyID {
                object["assigned_key_id"] = assigned
            }
            return object
        }
        return [
            "profile_version": 1,
            "geometry_version": layoutStore.geometryVersion,
            "layout_id": effectiveLayout.id,
            "layout_family": manualFamily.rawValue,
            "shape": shape.rawValue,
            "annotations": profileAnnotations
        ]
    }

    private func reportObject() -> [String: Any] {
        let retainedRecordCount = rawRecords.count
        let unknownIdentityCount = unknownStates.count
        let extraIdentityCount = extraStates.count
        let summaries = effectiveLayout.keys.map { key -> [String: Any] in
            let state = keyStates[key.id]
            return [
                "key_id": key.id,
                "label": key.label,
                "template_key_code": key.code,
                "last_native_identity": state?.identity ?? NSNull(),
                "last_native_code": state?.code ?? NSNull(),
                "observed": state?.observedCount ?? 0,
                "held": state?.held ?? false,
                "presses": state?.pressCount ?? 0,
                "releases": state?.releaseCount ?? 0,
                "repeats": state?.repeatCount ?? 0,
                "last_action": state?.lastAction ?? NSNull(),
                "last_characters": state?.lastCharacters ?? NSNull(),
                "last_unicode_scalars": state?.lastScalars ?? [],
                "last_modifiers": state?.lastModifiers ?? []
            ]
        }
        let unknown = tableObjects(from: unknownStates)
        let extra = tableObjects(from: extraStates)
        let metadata: [String: Any] = sessionMetadata.isEmpty ? ["available": false] : sessionMetadata
        return [
            "report_version": 1,
            "geometry_version": layoutStore.geometryVersion,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "session_metadata": metadata,
            "layout_id": effectiveLayout.id,
            "layout_family": effectiveFamily.rawValue,
            "layout_family_selection": manualFamily.rawValue,
            "shape": shape.rawValue,
            "caps_lock_state": capsLockState ?? NSNull(),
            "stats": [
                "records_observed": observedRecordCount,
                "raw_records_retained": retainedRecordCount,
                "raw_records_omitted": rawRecordsOmitted,
                "unknown_identities": unknownIdentityCount,
                "extra_identities": extraIdentityCount,
                "last_event_type": lastEventType.map { $0 as Any } ?? NSNull()
            ],
            "key_summaries": summaries,
            "unknown": unknown,
            "extra": extra,
            "annotations": profileObject()["annotations"] as Any,
            "raw_records_limit": Self.maxRawRecords,
            "raw_bytes_limit": Self.maxRawBytes,
            "raw_bytes_retained": rawRecordBytes,
            "raw_records_omitted": rawRecordsOmitted,
            "raw_records": rawRecords
        ]
    }

    private func tableObjects(from states: [String: KVKeyObservation]) -> [[String: Any]] {
        states.values.sorted { $0.identity < $1.identity }.map {
            [
                "identity": $0.identity,
                "namespace": $0.identity.hasPrefix("media:") ? "media" : "key",
                "raw_code": $0.code,
                "automatic_name": $0.automaticName,
                "label": annotations[$0.identity]?.label ?? $0.automaticName,
                "assigned_key_id": annotations[$0.identity]?.assignedKeyID ?? NSNull(),
                "observed": $0.observedCount,
                "held": $0.held,
                "presses": $0.pressCount,
                "releases": $0.releaseCount,
                "repeats": $0.repeatCount
            ]
        }
    }

    private func presentSavePanel(defaultName: String, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.json]
        if let window = view.window {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    private func presentOpenPanel(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let window = view.window {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    fileprivate func saveReport() {
        presentSavePanel(defaultName: "rustadmin-keyboard-report.json") { [weak self] url in
            guard let self, let url else { return }
            do {
                try kvWriteJSONAtomically(self.reportObject(), to: url)
                self.isError = false
                self.errorText = "Saved report: \(url.lastPathComponent)"
                self.refreshView()
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    fileprivate func saveProfile() {
        do {
            let profile = profileObject()
            // Validate the exact object before presenting the destination panel.
            _ = try KVProfileValidator.parse(data: kvJSONData(profile), store: layoutStore)
            presentSavePanel(defaultName: "rustadmin-keyboard-profile.json") { [weak self] url in
                guard let self, let url else { return }
                do {
                    try kvWriteJSONAtomically(profile, to: url)
                    self.isError = false
                    self.errorText = "Saved profile: \(url.lastPathComponent)"
                    self.refreshView()
                } catch {
                    self.showError(error.localizedDescription)
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    fileprivate func loadProfile() {
        presentOpenPanel { [weak self] url in
            guard let self, let url else { return }
            do {
                let data = try Data(contentsOf: url)
                try self.applyProfileData(data)
                self.isError = false
                self.errorText = "Loaded profile: \(url.lastPathComponent)"
                self.refreshView()
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    private func applyProfileData(_ data: Data) throws {
        let parsed = try KVProfileValidator.parse(data: data, store: layoutStore)
        manualFamily = parsed.family
        shape = parsed.shape
        annotations = Dictionary(uniqueKeysWithValues: parsed.annotations.map { ($0.identity, $0) })
        selectedIdentity = nil
        selectedKeyID = nil
        awaitingAssignment = false
        rebuildDisplayState()
    }
}

private struct KVParsedProfile {
    let family: KVLayoutFamily
    let shape: KVKeyboardShape
    let layoutID: String
    let annotations: [KVAnnotation]
}

private enum KVProfileValidator {
    static func parse(data: Data, store: KVLayoutStore) throws -> KVParsedProfile {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw KVVisualizerError.invalidProfile("JSON decoding failed: \(error.localizedDescription)")
        }
        guard let dictionary = object as? [String: Any] else {
            throw KVVisualizerError.invalidProfile("profile root must be an object")
        }
        guard kvStrictJSONInt(dictionary["profile_version"]) == 1 else {
            throw KVVisualizerError.invalidProfile("unsupported or missing profile_version")
        }
        guard kvStrictJSONInt(dictionary["geometry_version"]) == store.geometryVersion else {
            throw KVVisualizerError.invalidProfile("geometry_version does not match the installed geometry")
        }
        guard let layoutID = kvValueString(dictionary["layout_id"]),
              let layout = store.layout(id: layoutID) else {
            throw KVVisualizerError.invalidProfile("layout_id is unknown")
        }
        guard let familyValue = kvValueString(dictionary["layout_family"]),
              let family = KVLayoutFamily(rawValue: familyValue) else {
            throw KVVisualizerError.invalidProfile("layout_family is invalid")
        }
        guard let shapeValue = kvValueString(dictionary["shape"]),
              let shape = KVKeyboardShape(rawValue: shapeValue) else {
            throw KVVisualizerError.invalidProfile("shape is invalid")
        }
        guard layout.shape == shape else {
            throw KVVisualizerError.invalidProfile("layout_id and shape disagree")
        }
        if family != .auto {
            let expectedLayout = store.layout(family: family, shape: shape)
            guard layout.family == family, layout.id == expectedLayout.id else {
                throw KVVisualizerError.invalidProfile("layout_id does not match layout_family")
            }
        }
        guard let annotationObjects = dictionary["annotations"] as? [[String: Any]],
              annotationObjects.count <= 512 else {
            throw KVVisualizerError.invalidProfile("annotations must be an array of at most 512 objects")
        }

        var annotations: [KVAnnotation] = []
        var identities = Set<String>()
        for object in annotationObjects {
            guard let namespace = kvValueString(object["namespace"]),
                  namespace == "key" || namespace == "media" else {
                throw KVVisualizerError.invalidProfile("annotation namespace must be key or media")
            }
            guard let code = kvStrictJSONInt(object["raw_code"]),
                  (0...65535).contains(code) else {
                throw KVVisualizerError.invalidProfile("annotation raw_code is unsafe")
            }
            let identity = kvIdentity(namespace: namespace, code: code)
            guard kvValueString(object["identity"]) == identity else {
                throw KVVisualizerError.invalidProfile("annotation identity does not match namespace/raw_code")
            }
            guard identities.insert(identity).inserted else {
                throw KVVisualizerError.invalidProfile("duplicate annotation \(identity)")
            }
            guard let label = kvValueString(object["label"]) else {
                throw KVVisualizerError.invalidProfile("annotation \(identity) has no label")
            }
            try validateLabel(label, field: "annotation \(identity)")
            let assigned: String?
            if let assignedObject = object["assigned_key_id"], !(assignedObject is NSNull) {
                guard let assignedValue = assignedObject as? String else {
                    throw KVVisualizerError.invalidProfile("annotation \(identity) has invalid assigned_key_id")
                }
                guard layout.keyByID[assignedValue] != nil else {
                    throw KVVisualizerError.invalidProfile("annotation \(identity) assigns an unknown key position")
                }
                assigned = assignedValue
            } else {
                assigned = nil
            }
            annotations.append(KVAnnotation(
                namespace: namespace,
                code: code,
                identity: identity,
                label: label,
                assignedKeyID: assigned
            ))
        }
        return KVParsedProfile(family: family, shape: shape, layoutID: layoutID, annotations: annotations)
    }

    private static func validateLabel(_ value: String, field: String) throws {
        guard !value.isEmpty, value.count <= 80 else {
            throw KVVisualizerError.invalidProfile("\(field) must be non-empty and at most 80 characters")
        }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw KVVisualizerError.invalidProfile("\(field) contains a control character")
        }
    }
}

private final class KVKeyboardCanvasView: NSView {
    private var layout: KVLayoutDefinition?
    private var capsLockState: String?
    private var keyStates: [String: KVKeyObservation] = [:]
    private var selectedKeyID: String?
    var onKeyClick: ((String) -> Void)?

    func update(snapshot: KVVisualizerSnapshot) {
        layout = snapshot.layout
        capsLockState = snapshot.capsLockState
        keyStates = snapshot.keyStates
        selectedKeyID = snapshot.selectedKeyID
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout else { return }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let canvasRect = bounds.insetBy(dx: 8, dy: 8)
        let bounds = layout.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(canvasRect.width / bounds.width, canvasRect.height / bounds.height)
        guard scale.isFinite, scale > 0 else { return }
        let usedWidth = bounds.width * scale
        let usedHeight = bounds.height * scale
        let origin = CGPoint(
            x: canvasRect.minX + (canvasRect.width - usedWidth) * 0.5,
            y: canvasRect.minY + (canvasRect.height - usedHeight) * 0.5
        )

        for key in layout.keys {
            let state = keyStates[key.id]
            let isPressed = (state?.pressCount ?? 0) > 0
            let isHeld = state?.held == true
            let isSelected = selectedKeyID == key.id
            let fillColor: NSColor
            if isHeld {
                fillColor = NSColor.systemOrange.withAlphaComponent(0.88)
            } else if isPressed {
                fillColor = NSColor.systemTeal.withAlphaComponent(0.74)
            } else {
                fillColor = NSColor.controlBackgroundColor
            }

            let path = NSBezierPath()
            for rect in key.rects {
                let screen = screenRect(rect, layoutBounds: bounds, scale: scale, origin: origin)
                    .insetBy(dx: 1.2, dy: 1.2)
                path.appendRoundedRect(screen, xRadius: min(5, screen.height * 0.16), yRadius: min(5, screen.height * 0.16))
            }
            fillColor.setFill()
            path.fill()
            (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isSelected ? 2.0 : 0.8
            path.stroke()

            let labelRect = screenRect(key.bounds, layoutBounds: bounds, scale: scale, origin: origin)
                .insetBy(dx: 3, dy: 2)
            let fontSize = max(8, min(13, labelRect.height * 0.30))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            (key.legend as NSString).draw(in: labelRect, withAttributes: attributes)
            if isPressed {
                let checkRect = NSRect(x: labelRect.maxX - 13, y: labelRect.minY + 1, width: 12, height: 12)
                ("✓" as NSString).draw(in: checkRect, withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.labelColor
                ])
            }
            if key.id == "capsLock", let capsLockState {
                let normalized = capsLockState.lowercased()
                let badge = normalized == "on" ? "●" : "○"
                let badgeRect = NSRect(x: labelRect.minX + 1, y: labelRect.minY + 1, width: 12, height: 12)
                (badge as NSString).draw(in: badgeRect, withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: normalized == "on" ? NSColor.systemGreen : NSColor.secondaryLabelColor
                ])
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let layout else { return }
        let canvasRect = bounds.insetBy(dx: 8, dy: 8)
        let layoutBounds = layout.bounds
        guard layoutBounds.width > 0, layoutBounds.height > 0 else { return }
        let scale = min(canvasRect.width / layoutBounds.width, canvasRect.height / layoutBounds.height)
        let origin = CGPoint(
            x: canvasRect.minX + (canvasRect.width - layoutBounds.width * scale) * 0.5,
            y: canvasRect.minY + (canvasRect.height - layoutBounds.height * scale) * 0.5
        )
        let point = convert(event.locationInWindow, from: nil)
        for key in layout.keys.reversed() {
            if key.rects.contains(where: {
                screenRect($0, layoutBounds: layoutBounds, scale: scale, origin: origin).contains(point)
            }) {
                onKeyClick?(key.id)
                return
            }
        }
    }

    private func screenRect(_ rect: CGRect, layoutBounds: CGRect, scale: CGFloat, origin: CGPoint) -> CGRect {
        CGRect(
            x: origin.x + (rect.minX - layoutBounds.minX) * scale,
            y: origin.y + (rect.minY - layoutBounds.minY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

private final class KVVisualizerRootView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var owner: KeyboardVisualizerController?

    private let familyPopup = NSPopUpButton()
    private let shapePopup = NSPopUpButton()
    private let resetButton = NSButton(title: "Reset test", target: nil, action: nil)
    private let reportButton = NSButton(title: "Save report", target: nil, action: nil)
    private let saveProfileButton = NSButton(title: "Save profile", target: nil, action: nil)
    private let loadProfileButton = NSButton(title: "Load profile", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename selected", target: nil, action: nil)
    private let assignButton = NSButton(title: "Assign selected: click key", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailView = NSTextView(frame: .zero)
    private let detailScrollView = NSScrollView(frame: .zero)
    private let canvasView = KVKeyboardCanvasView(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let tableScrollView = NSScrollView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "No unknown or extra keys yet.")
    private var rows: [KVTableRow] = []
    private var installed = false
    private var isRefreshing = false

    override var intrinsicContentSize: NSSize { NSSize(width: 1000, height: 400) }

    func installControls() {
        guard !installed else { return }
        installed = true
        translatesAutoresizingMaskIntoConstraints = false

        familyPopup.addItems(withTitles: KVLayoutFamily.allCases.map(\.rawValue))
        shapePopup.addItems(withTitles: KVKeyboardShape.allCases.map(\.rawValue))
        [familyPopup, shapePopup].forEach {
            $0.controlSize = .small
            $0.font = NSFont.systemFont(ofSize: 12)
            $0.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        familyPopup.target = self
        familyPopup.action = #selector(familyChanged(_:))
        shapePopup.target = self
        shapePopup.action = #selector(shapeChanged(_:))

        resetButton.target = self
        resetButton.action = #selector(resetClicked(_:))
        reportButton.target = self
        reportButton.action = #selector(reportClicked(_:))
        saveProfileButton.target = self
        saveProfileButton.action = #selector(saveProfileClicked(_:))
        loadProfileButton.target = self
        loadProfileButton.action = #selector(loadProfileClicked(_:))
        renameButton.target = self
        renameButton.action = #selector(renameClicked(_:))
        assignButton.target = self
        assignButton.action = #selector(assignClicked(_:))
        [resetButton, reportButton, saveProfileButton, loadProfileButton, renameButton, assignButton].forEach {
            $0.bezelStyle = .rounded
            $0.controlSize = .small
            $0.font = NSFont.systemFont(ofSize: 11)
            $0.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }

        let layoutLabel = NSTextField(labelWithString: "Layout")
        let shapeLabel = NSTextField(labelWithString: "Shape")
        [layoutLabel, shapeLabel].forEach { $0.font = NSFont.systemFont(ofSize: 11, weight: .semibold) }
        let toolbar = NSStackView(views: [
            layoutLabel, familyPopup, shapeLabel, shapePopup,
            resetButton, reportButton, saveProfileButton, loadProfileButton
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 7

        canvasView.wantsLayer = true
        canvasView.layer?.cornerRadius = 6
        canvasView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        canvasView.onKeyClick = { [weak self] keyID in
            self?.owner?.selectKey(keyID)
        }
        canvasView.translatesAutoresizingMaskIntoConstraints = false

        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.isRichText = false
        detailView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailView.textContainerInset = NSSize(width: 6, height: 5)
        detailView.drawsBackground = true
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailView.isVerticallyResizable = true
        detailView.isHorizontallyResizable = false
        detailView.autoresizingMask = [.width]
        detailView.textContainer?.widthTracksTextView = true

        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.borderType = .bezelBorder
        detailScrollView.hasVerticalScroller = true
        detailScrollView.hasHorizontalScroller = false
        detailScrollView.autohidesScrollers = true
        detailScrollView.documentView = detailView
        NSLayoutConstraint.activate([
            detailView.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor),
            detailView.heightAnchor.constraint(equalToConstant: 120)
        ])

        configureTable()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.borderType = .bezelBorder
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = false
        tableScrollView.autohidesScrollers = true
        tableScrollView.documentView = tableView

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.textColor = NSColor.secondaryLabelColor
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.isHidden = true

        let annotationToolbar = NSStackView(views: [renameButton, assignButton])
        annotationToolbar.orientation = .horizontal
        annotationToolbar.spacing = 7

        let sidebarTitle = NSTextField(labelWithString: "Unknown / extra keys")
        sidebarTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let legend = NSTextField(labelWithString: "Legend: orange held · teal pressed · gray unobserved")
        legend.font = NSFont.systemFont(ofSize: 10)
        legend.textColor = NSColor.secondaryLabelColor
        legend.lineBreakMode = .byWordWrapping
        legend.maximumNumberOfLines = 2

        let sidebar = NSStackView(views: [
            sidebarTitle, legend, tableScrollView, emptyLabel, annotationToolbar
        ])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 4
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let mainRow = NSStackView(views: [canvasView, sidebar])
        mainRow.orientation = .horizontal
        mainRow.alignment = .top
        mainRow.spacing = 10
        mainRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [toolbar, mainRow, detailScrollView, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            toolbar.heightAnchor.constraint(equalToConstant: 24),
            mainRow.heightAnchor.constraint(equalToConstant: 240),
            canvasView.heightAnchor.constraint(equalToConstant: 240),
            sidebar.widthAnchor.constraint(equalToConstant: 360),
            tableScrollView.heightAnchor.constraint(equalToConstant: 112),
            annotationToolbar.heightAnchor.constraint(equalToConstant: 24),
            detailScrollView.heightAnchor.constraint(equalToConstant: 68),
            statusLabel.heightAnchor.constraint(equalToConstant: 17)
        ])
        for section in [toolbar, mainRow, detailScrollView, statusLabel] {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for section in [sidebarTitle, legend, tableScrollView, emptyLabel, annotationToolbar] {
            section.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
    }

    func refresh(snapshot: KVVisualizerSnapshot) {
        guard installed else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        familyPopup.selectItem(withTitle: snapshot.familySelection.rawValue)
        shapePopup.selectItem(withTitle: snapshot.layout.shape.rawValue)
        canvasView.update(snapshot: snapshot)
        detailView.string = snapshot.detailText
        statusLabel.stringValue = snapshot.statusText
        if let errorText = snapshot.errorText, !errorText.isEmpty {
            statusLabel.stringValue = errorText
            statusLabel.textColor = snapshot.isError ? NSColor.systemRed : NSColor.secondaryLabelColor
        } else {
            statusLabel.textColor = NSColor.secondaryLabelColor
        }
        assignButton.title = snapshot.awaitingAssignment ? "Click a key to assign…" : "Assign selected: click key"
        rows = snapshot.tableRows
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        if let identity = snapshot.selectedIdentity,
           let row = rows.firstIndex(where: { $0.identity == identity }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    func presentRenamePrompt(defaultValue: String, completion: @escaping (String?) -> Void) {
        guard let window = owner?.view.window else {
            completion(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Name this key"
        alert.informativeText = "The name is saved with your keyboard profile."
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.headerView = NSTableHeaderView()
        let columns: [(String, String, CGFloat)] = [
            ("kind", "Kind", 56),
            ("name", "Name", 190), ("count", "Presses", 50),
            ("repeats", "Repeat", 50)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.rowHeight = 20
    }

    @objc private func familyChanged(_ sender: NSPopUpButton) {
        guard !isRefreshing else { return }
        guard let title = sender.titleOfSelectedItem, let family = KVLayoutFamily(rawValue: title) else { return }
        owner?.setFamily(family)
    }

    @objc private func shapeChanged(_ sender: NSPopUpButton) {
        guard !isRefreshing else { return }
        guard let title = sender.titleOfSelectedItem, let shape = KVKeyboardShape(rawValue: title) else { return }
        owner?.setShape(shape)
    }

    @objc private func resetClicked(_ sender: NSButton) { owner?.resetTest() }
    @objc private func reportClicked(_ sender: NSButton) { owner?.saveReport() }
    @objc private func saveProfileClicked(_ sender: NSButton) { owner?.saveProfile() }
    @objc private func loadProfileClicked(_ sender: NSButton) { owner?.loadProfile() }
    @objc private func renameClicked(_ sender: NSButton) { owner?.renameSelectedUnknown() }
    @objc private func assignClicked(_ sender: NSButton) { owner?.beginAssignment() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let item = rows[row]
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
        switch identifier {
        case "kind": field.stringValue = item.namespace
        case "identity": field.stringValue = item.identity
        case "name": field.stringValue = item.name
        case "count": field.stringValue = String(item.count)
        case "repeats": field.stringValue = String(item.repeatCount)
        default: field.stringValue = ""
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshing else { return }
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        owner?.selectIdentity(rows[row].identity)
    }
}
