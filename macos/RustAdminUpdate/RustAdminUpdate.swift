import AppKit
import Foundation
import UniformTypeIdentifiers

struct UpdaterProduct: Equatable {
    static let rustAdmin = UpdaterProduct(
        appName: "RustAdmin",
        bundleIdentifier: "io.github.rustadministrator.rustadmin",
        serviceIdentifier: "io.github.rustadministrator.rustadmin"
    )

    let appName: String
    let bundleIdentifier: String
    let serviceIdentifier: String

    var defaultTarget: URL {
        URL(fileURLWithPath: "/Applications/\(appName).app", isDirectory: true)
    }
}

struct NumericVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [UInt64]

    static func parse(_ rawValue: String) -> NumericVersion? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty, !pieces.isEmpty else {
            return nil
        }

        var components = [UInt64]()
        components.reserveCapacity(pieces.count)
        for piece in pieces {
            guard !piece.isEmpty,
                  piece.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let component = UInt64(String(piece))
            else {
                return nil
            }
            components.append(component)
        }

        while components.count > 1 && components.last == 0 {
            components.removeLast()
        }
        return NumericVersion(components: components)
    }

    static func < (lhs: NumericVersion, rhs: NumericVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }
}

struct BundleVersion: Comparable, Equatable, CustomStringConvertible {
    let numericVersion: NumericVersion
    let revision: UInt64
    let rawVersion: String
    let rawRevision: String

    static func == (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
        lhs.numericVersion == rhs.numericVersion && lhs.revision == rhs.revision
    }

    static func < (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
        if lhs.numericVersion != rhs.numericVersion {
            return lhs.numericVersion < rhs.numericVersion
        }
        return lhs.revision < rhs.revision
    }

    var description: String {
        "\(rawVersion) (\(rawRevision))"
    }
}

enum BundleMetadataError: Error {
    case missingBundle
    case unreadableInfoPlist
    case missingProductIdentity
    case wrongProduct(expected: String, actual: String?)
    case wrongExecutable(expected: String, actual: String?)
    case missingExecutable
    case invalidVersion
    case invalidRevision

    var reason: String {
        switch self {
        case .missingBundle:
            return "The application bundle directory is missing."
        case .unreadableInfoPlist:
            return "Contents/Info.plist could not be read."
        case .missingProductIdentity:
            return "The application does not declare a product identity."
        case .wrongProduct(let expected, let actual):
            return "Expected bundle identifier \(expected), found \(actual ?? "missing")."
        case .wrongExecutable(let expected, let actual):
            return "Expected executable \(expected), found \(actual ?? "missing")."
        case .missingExecutable:
            return "The application executable is missing or not executable."
        case .invalidVersion:
            return "CFBundleShortVersionString must contain numeric dot-separated components."
        case .invalidRevision:
            return "RustAdminRevision or CFBundleVersion must contain a numeric revision."
        }
    }
}

struct BundleMetadata: Equatable {
    let bundleURL: URL
    let bundleIdentifier: String
    let executableName: String
    let shortVersionString: String
    let revisionString: String
    let version: BundleVersion

    var executableURL: URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
    }

    static func load(
        at url: URL,
        product: UpdaterProduct,
        fileManager: FileManager = .default
    ) throws -> BundleMetadata {
        let bundleURL = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BundleMetadataError.missingBundle
        }

        let infoURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let info = propertyList as? [String: Any]
        else {
            throw BundleMetadataError.unreadableInfoPlist
        }

        guard let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty
        else {
            throw BundleMetadataError.missingProductIdentity
        }
        guard bundleIdentifier == product.bundleIdentifier else {
            throw BundleMetadataError.wrongProduct(
                expected: product.bundleIdentifier,
                actual: bundleIdentifier
            )
        }

        let executableName = info["CFBundleExecutable"] as? String
        guard executableName == product.appName else {
            throw BundleMetadataError.wrongExecutable(
                expected: product.appName,
                actual: executableName
            )
        }

        if let packageType = info["CFBundlePackageType"] as? String, packageType != "APPL" {
            throw BundleMetadataError.wrongExecutable(expected: "APPL bundle", actual: packageType)
        }

        let executableURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(product.appName)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw BundleMetadataError.missingExecutable
        }

        guard let shortVersionString = info["CFBundleShortVersionString"] as? String,
              let numericVersion = NumericVersion.parse(shortVersionString)
        else {
            throw BundleMetadataError.invalidVersion
        }

        let revisionValue = (info["RustAdminRevision"] as? String)
            ?? (info["CFBundleVersion"] as? String)
        guard let revisionValue,
              let revision = UInt64(revisionValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw BundleMetadataError.invalidRevision
        }

        return BundleMetadata(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            executableName: product.appName,
            shortVersionString: shortVersionString.trimmingCharacters(in: .whitespacesAndNewlines),
            revisionString: revisionValue.trimmingCharacters(in: .whitespacesAndNewlines),
            version: BundleVersion(
                numericVersion: numericVersion,
                revision: revision,
                rawVersion: shortVersionString.trimmingCharacters(in: .whitespacesAndNewlines),
                rawRevision: revisionValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }
}

enum UpdateError: LocalizedError, Equatable {
    case malformedArguments(String)
    case missingArgument(String)
    case invalidSource(URL, String)
    case invalidTarget(URL, String)
    case missingTarget(URL)
    case sameBundle
    case sourceNotNewer(BundleVersion, BundleVersion)
    case sourceSelectionRequired
    case invalidStaging
    case stagingFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .malformedArguments(let message):
            return "RustAdmin Update received invalid arguments: \(message)"
        case .missingArgument(let name):
            return "RustAdmin Update was started without \(name)."
        case .invalidSource(let url, let reason):
            return "The update source is not a valid RustAdmin app:\n\(url.path)\n\(reason)"
        case .invalidTarget(let url, let reason):
            return "The installed RustAdmin app is not valid:\n\(url.path)\n\(reason)"
        case .missingTarget(let url):
            return "RustAdmin is not installed at \(url.path). Drag RustAdmin.app to the Applications folder before updating; no service was changed."
        case .sameBundle:
            return "The update source is already the installed RustAdmin app. Open a newer copy from the downloaded archive."
        case .sourceNotNewer(let source, let target):
            return "The selected RustAdmin version \(source) is not newer than the installed version \(target)."
        case .sourceSelectionRequired:
            return "Choose the newer RustAdmin.app from the downloaded archive or mounted installer."
        case .invalidStaging:
            return "The updater staging directory is not owned by this update operation."
        case .stagingFailed(let message):
            return "Could not prepare the RustAdmin updater: \(message)"
        case .failed(let message):
            return message
        }
    }
}

struct OwnedStagingDirectory: Equatable {
    static let directoryPrefix = "RustAdminUpdate-"
    static let markerName = ".rustadmin-updater-owner"

    let rootURL: URL
    let appURL: URL
    let token: String

    init(
        rootURL: URL,
        token: String,
        fileManager: FileManager = .default
    ) throws {
        guard Self.provesOwnership(rootURL: rootURL, token: token, fileManager: fileManager) else {
            throw UpdateError.invalidStaging
        }
        self.rootURL = rootURL.standardizedFileURL
        self.appURL = rootURL
            .standardizedFileURL
            .appendingPathComponent("RustAdminUpdate.app", isDirectory: true)
        self.token = token
    }

    static func create(
        from bundleURL: URL,
        fileManager: FileManager = .default
    ) throws -> OwnedStagingDirectory {
        let token = UUID().uuidString
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(directoryPrefix)\(token)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)
            let markerURL = rootURL.appendingPathComponent(markerName)
            try Data(token.utf8).write(to: markerURL, options: .atomic)
            let appURL = rootURL.appendingPathComponent("RustAdminUpdate.app", isDirectory: true)
            try fileManager.copyItem(at: bundleURL, to: appURL)
            return try OwnedStagingDirectory(rootURL: rootURL, token: token, fileManager: fileManager)
        } catch let error as UpdateError {
            try? fileManager.removeItem(at: rootURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw UpdateError.stagingFailed(error.localizedDescription)
        }
    }

    static func provesOwnership(
        rootURL: URL,
        token: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let rootURL = rootURL.standardizedFileURL
        let temporaryDirectory = fileManager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let parentURL = rootURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard parentURL == temporaryDirectory,
              rootURL.lastPathComponent.hasPrefix(directoryPrefix),
              !token.isEmpty
        else {
            return false
        }

        let markerURL = rootURL.appendingPathComponent(markerName)
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = String(data: markerData, encoding: .utf8)
        else {
            return false
        }
        return marker == token
    }

    func cleanupIfOwned(fileManager: FileManager = .default) {
        guard Self.provesOwnership(rootURL: rootURL, token: token, fileManager: fileManager) else {
            return
        }
        try? fileManager.removeItem(at: rootURL)
    }

    func launch(request: UpdateRequest) throws {
        let executableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("RustAdminUpdate")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UpdateError.stagingFailed("The staged updater executable is missing or not executable.")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = request.commandLineArguments(staging: self)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.stagingFailed(error.localizedDescription)
        }
    }
}

struct UpdateRequest: Equatable {
    let source: URL
    let target: URL
    let product: UpdaterProduct
    let sourceInfo: BundleMetadata
    let targetInfo: BundleMetadata
    let staging: OwnedStagingDirectory?

    var sourceVersion: BundleVersion {
        sourceInfo.version
    }

    var installedVersion: BundleVersion {
        targetInfo.version
    }

    var daemonPlist: String {
        "/Library/LaunchDaemons/\(product.serviceIdentifier)_service.plist"
    }

    var agentPlist: String {
        "/Library/LaunchAgents/\(product.serviceIdentifier)_server.plist"
    }

    static func parse(arguments: [String]) throws -> UpdateRequest {
        let options = try UpdaterArguments.parse(arguments: arguments)
        let product = UpdaterProduct(
            appName: options.appName,
            bundleIdentifier: UpdaterProduct.rustAdmin.bundleIdentifier,
            serviceIdentifier: options.serviceIdentifier
        )
        let staging: OwnedStagingDirectory?
        if let stagingRoot = options.stagingRoot, let stagingToken = options.stagingToken {
            staging = try OwnedStagingDirectory(rootURL: stagingRoot, token: stagingToken)
        } else {
            staging = nil
        }

        return try make(
            source: options.source,
            target: options.target,
            product: product,
            staging: staging
        )
    }

    static func make(
        source: URL,
        target: URL,
        product: UpdaterProduct,
        staging: OwnedStagingDirectory? = nil,
        fileManager: FileManager = .default
    ) throws -> UpdateRequest {
        let source = source.standardizedFileURL
        let target = target.standardizedFileURL
        guard source.resolvingSymlinksInPath() != target.resolvingSymlinksInPath() else {
            throw UpdateError.sameBundle
        }

        let sourceInfo: BundleMetadata
        do {
            sourceInfo = try BundleMetadata.load(at: source, product: product, fileManager: fileManager)
        } catch let error as BundleMetadataError {
            throw UpdateError.invalidSource(source, error.reason)
        } catch {
            throw UpdateError.invalidSource(source, error.localizedDescription)
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw UpdateError.missingTarget(target)
        }

        let targetInfo: BundleMetadata
        do {
            targetInfo = try BundleMetadata.load(at: target, product: product, fileManager: fileManager)
        } catch let error as BundleMetadataError {
            throw UpdateError.invalidTarget(target, error.reason)
        } catch {
            throw UpdateError.invalidTarget(target, error.localizedDescription)
        }

        guard sourceInfo.version > targetInfo.version else {
            throw UpdateError.sourceNotNewer(sourceInfo.version, targetInfo.version)
        }

        return UpdateRequest(
            source: source,
            target: target,
            product: product,
            sourceInfo: sourceInfo,
            targetInfo: targetInfo,
            staging: staging
        )
    }

    static func discoverNoArgumentRequest(
        bundleURL: URL,
        product: UpdaterProduct = .rustAdmin,
        fileManager: FileManager = .default
    ) throws -> UpdateRequest {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: product.defaultTarget.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw UpdateError.missingTarget(product.defaultTarget)
        }

        guard let source = SourceDiscovery.adjacentSource(
            to: bundleURL,
            product: product,
            fileManager: fileManager
        )
        else {
            throw UpdateError.sourceSelectionRequired
        }

        return try make(
            source: source,
            target: product.defaultTarget,
            product: product,
            fileManager: fileManager
        )
    }

    func commandLineArguments(staging: OwnedStagingDirectory? = nil) -> [String] {
        var arguments = [
            "--source", source.path,
            "--target", target.path,
            "--app-name", product.appName,
            "--service-id", product.serviceIdentifier,
        ]
        if let staging {
            arguments += [
                "--staging-root", staging.rootURL.path,
                "--staging-token", staging.token,
            ]
        }
        return arguments
    }

    func runPrivilegedUpdate() throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            Self.privilegedUpdateScript,
            source.path,
            target.path,
            product.appName,
            NSUserName(),
            product.bundleIdentifier,
            sourceInfo.shortVersionString,
            sourceInfo.revisionString,
            targetInfo.shortVersionString,
            targetInfo.revisionString,
            daemonPlist,
            agentPlist,
        ]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw UpdateError.failed("Could not start the macOS update helper: \(error.localizedDescription)")
        }

        // Drain the pipe while osascript is running. Waiting first can deadlock
        // when the privileged shell emits more output than the pipe can hold.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = output.flatMap { $0.isEmpty ? nil : $0 }
            throw UpdateError.failed(detail ?? "The update was canceled or macOS could not replace the installed app.")
        }
    }

    static let privilegedUpdateScript = #"""
on run argv
    if (count of argv) is less than 11 then error "RustAdmin Update received incomplete authorization arguments."
    set source_dir to item 1 of argv
    set target_app to item 2 of argv
    set app_name to item 3 of argv
    set user_name to item 4 of argv
    set expected_bundle_id to item 5 of argv
    set expected_source_version to item 6 of argv
    set expected_source_revision to item 7 of argv
    set expected_target_version to item 8 of argv
    set expected_target_revision to item 9 of argv
    set daemon_plist to item 10 of argv
    set agent_plist to item 11 of argv
    set test_mode to ""
    if (count of argv) is greater than or equal to 12 then
        set test_mode to item 12 of argv
    end if

    set source_q to quoted form of source_dir
    set target_q to quoted form of target_app
    set app_name_q to quoted form of app_name
    set user_q to quoted form of user_name
    set expected_id_q to quoted form of expected_bundle_id
    set expected_source_version_q to quoted form of expected_source_version
    set expected_source_revision_q to quoted form of expected_source_revision
    set expected_target_version_q to quoted form of expected_target_version
    set expected_target_revision_q to quoted form of expected_target_revision
    set daemon_q to quoted form of daemon_plist
    set agent_q to quoted form of agent_plist

    set assignments to "source_dir=" & source_q & ";target_app=" & target_q & ";app_name=" & app_name_q & ";user_name=" & user_q & ";expected_bundle_id=" & expected_id_q & ";expected_source_version=" & expected_source_version_q & ";expected_source_revision=" & expected_source_revision_q & ";expected_target_version=" & expected_target_version_q & ";expected_target_revision=" & expected_target_revision_q & ";daemon_plist=" & daemon_q & ";agent_plist=" & agent_q & ";"
    set validate_paths to "if [ ! -d \"$source_dir\" ]; then echo 'Update source disappeared before authorization.' >&2; exit 1; fi; if [ ! -f \"$source_dir/Contents/Info.plist\" ]; then echo 'Update source metadata is missing.' >&2; exit 1; fi; if [ ! -x \"$source_dir/Contents/MacOS/$app_name\" ]; then echo 'Update source executable is missing.' >&2; exit 1; fi; if [ ! -d \"$target_app\" ]; then echo 'Installed RustAdmin disappeared before authorization.' >&2; exit 1; fi; if [ ! -f \"$target_app/Contents/Info.plist\" ]; then echo 'Installed RustAdmin metadata is missing.' >&2; exit 1; fi; if [ ! -x \"$target_app/Contents/MacOS/$app_name\" ]; then echo 'Installed RustAdmin executable is missing.' >&2; exit 1; fi;"
    set validate_identity to "if ! source_real=$(cd \"$source_dir\" && /bin/pwd -P); then echo 'Could not resolve the update source before authorization.' >&2; exit 1; fi; if ! target_real=$(cd \"$target_app\" && /bin/pwd -P); then echo 'Could not resolve the installed RustAdmin app before authorization.' >&2; exit 1; fi; if [ \"$source_real\" = \"$target_real\" ]; then echo 'Update source and installed RustAdmin resolve to the same bundle.' >&2; exit 1; fi; source_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$source_dir/Contents/Info.plist\" 2>/dev/null || true); target_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$target_app/Contents/Info.plist\" 2>/dev/null || true); if [ \"$source_id\" != \"$expected_bundle_id\" ] || [ \"$target_id\" != \"$expected_bundle_id\" ]; then echo 'RustAdmin product identity changed before authorization.' >&2; exit 1; fi; source_exec=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \"$source_dir/Contents/Info.plist\" 2>/dev/null || true); target_exec=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \"$target_app/Contents/Info.plist\" 2>/dev/null || true); if [ \"$source_exec\" != \"$app_name\" ] || [ \"$target_exec\" != \"$app_name\" ]; then echo 'RustAdmin executable identity changed before authorization.' >&2; exit 1; fi; source_type=$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' \"$source_dir/Contents/Info.plist\" 2>/dev/null || true); target_type=$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' \"$target_app/Contents/Info.plist\" 2>/dev/null || true); if [ \"$source_type\" != APPL ] || [ \"$target_type\" != APPL ]; then echo 'RustAdmin bundle type changed before authorization.' >&2; exit 1; fi; source_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \"$source_dir/Contents/Info.plist\" 2>/dev/null || true); target_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \"$target_app/Contents/Info.plist\" 2>/dev/null || true); source_revision=$(/usr/libexec/PlistBuddy -c 'Print :RustAdminRevision' \"$source_dir/Contents/Info.plist\" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"$source_dir/Contents/Info.plist\" 2>/dev/null || true); target_revision=$(/usr/libexec/PlistBuddy -c 'Print :RustAdminRevision' \"$target_app/Contents/Info.plist\" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"$target_app/Contents/Info.plist\" 2>/dev/null || true); if [ \"$source_version\" != \"$expected_source_version\" ] || [ \"$source_revision\" != \"$expected_source_revision\" ] || [ \"$target_version\" != \"$expected_target_version\" ] || [ \"$target_revision\" != \"$expected_target_revision\" ]; then echo 'RustAdmin version metadata changed before authorization.' >&2; exit 1; fi;"
    set prepare_copy to "staging_root=$(/usr/bin/mktemp -d \"${TMPDIR:-/tmp}/RustAdminUpdate-stage.XXXXXX\"); staging_app=\"$staging_root/$(/usr/bin/basename \"$target_app\")\"; if ! /usr/bin/ditto \"$source_dir\" \"$staging_app\"; then echo 'Could not stage the update payload.' >&2; exit 1; fi; if [ ! -x \"$staging_app/Contents/MacOS/$app_name\" ]; then echo 'Staged update payload is incomplete.' >&2; exit 1; fi; target_parent=$(/usr/bin/dirname \"$target_app\"); target_name=$(/usr/bin/basename \"$target_app\"); backup_root=$(/usr/bin/mktemp -d \"$target_parent/.RustAdminUpdate-backup.XXXXXX\"); backup_app=\"$backup_root/$target_name\";"
    set discover_state to "uid=$(/usr/bin/id -u \"$user_name\" 2>/dev/null || true); daemon_label=$(/usr/bin/basename \"$daemon_plist\" .plist); agent_label=$(/usr/bin/basename \"$agent_plist\" .plist); services_installed=0; daemon_running=0; agent_running=0; agent_domain=''; if [ -f \"$daemon_plist\" ] && [ -f \"$agent_plist\" ]; then services_installed=1; fi; if [ \"$services_installed\" = 1 ] && /bin/launchctl print \"system/$daemon_label\" >/dev/null 2>&1; then daemon_running=1; fi; if [ \"$services_installed\" = 1 ] && [ -n \"$uid\" ]; then if /bin/launchctl print \"gui/$uid/$agent_label\" >/dev/null 2>&1; then agent_running=1; agent_domain=gui/$uid; elif /bin/launchctl print \"user/$uid/$agent_label\" >/dev/null 2>&1; then agent_running=1; agent_domain=user/$uid; fi; fi;"
    set restore_services to "restore_failed=0; if [ \"$daemon_running\" = 1 ]; then if ! ( /bin/launchctl bootstrap system \"$daemon_plist\" 2>/dev/null || /bin/launchctl load -w \"$daemon_plist\" 2>/dev/null ); then restore_failed=1; fi; if ! /bin/launchctl kickstart -k \"system/$daemon_label\" 2>/dev/null; then restore_failed=1; fi; fi; if [ \"$agent_running\" = 1 ] && [ -n \"$agent_domain\" ]; then if ! ( /bin/launchctl bootstrap \"$agent_domain\" \"$agent_plist\" 2>/dev/null || /bin/launchctl load -w \"$agent_plist\" 2>/dev/null ); then restore_failed=1; fi; if ! /bin/launchctl kickstart -k \"$agent_domain/$agent_label\" 2>/dev/null; then restore_failed=1; fi; fi;"
    set cleanup_staging to "if [ -n \"${staging_root:-}\" ] && [ -e \"$staging_root\" ]; then /bin/rm -rf \"$staging_root\"; fi;"
    set cleanup_backup to "if [ -n \"${backup_root:-}\" ] && [ -e \"$backup_root\" ]; then /bin/rm -rf \"$backup_root\"; fi;"
    set cleanup_files to cleanup_staging & cleanup_backup
    set rollback to "status=$?; trap - EXIT; rollback_failed=0; if [ \"${target_moved:-0}\" = 1 ]; then if [ -e \"$target_app\" ] || [ -L \"$target_app\" ]; then if ! /bin/rm -rf \"$target_app\"; then echo \"UPDATE ROLLBACK FAILED: could not remove the replacement; intact backup remains at $backup_app\" >&2; rollback_failed=1; fi; fi; if [ \"$rollback_failed\" = 0 ]; then if [ -e \"$backup_app\" ] || [ -L \"$backup_app\" ]; then if ! /bin/mv \"$backup_app\" \"$target_app\"; then echo \"UPDATE ROLLBACK FAILED: intact backup remains at $backup_app\" >&2; rollback_failed=1; fi; else echo \"UPDATE ROLLBACK FAILED: backup is missing at $backup_app\" >&2; rollback_failed=1; fi; fi; fi; " & restore_services & "if [ \"$restore_failed\" = 1 ]; then echo 'UPDATE ROLLBACK FAILED: could not restore one or more previously running services.' >&2; rollback_failed=1; fi; if [ \"$rollback_failed\" = 0 ]; then " & cleanup_files & " else " & cleanup_staging & " fi; if [ \"$rollback_failed\" = 1 ]; then exit 1; fi; exit $status;"
    set stop_services to "stop_failed=0; if [ \"$agent_running\" = 1 ]; then if ! ( /bin/launchctl bootout \"$agent_domain/$agent_label\" 2>/dev/null || /bin/launchctl unload -w \"$agent_plist\" 2>/dev/null ); then stop_failed=1; fi; fi; if [ \"$daemon_running\" = 1 ]; then if ! ( /bin/launchctl bootout \"system/$daemon_label\" 2>/dev/null || /bin/launchctl unload -w \"$daemon_plist\" 2>/dev/null ); then stop_failed=1; fi; fi; if [ \"$stop_failed\" = 1 ]; then echo 'Could not stop all running RustAdmin services.' >&2; exit 1; fi;"
    set kill_processes to "pids=$(/usr/bin/pgrep -x \"$app_name\" || true); if [ -n \"$pids\" ]; then echo \"$pids\" | /usr/bin/xargs /bin/kill -9 || true; fi;"
    set replace_app to "if ! /bin/mv \"$target_app\" \"$backup_app\"; then echo 'Could not preserve the installed RustAdmin app.' >&2; exit 1; fi; target_moved=1; if ! /bin/mv \"$staging_app\" \"$target_app\"; then echo 'Could not install the staged RustAdmin app.' >&2; exit 1; fi; if ! /usr/sbin/chown -R \"${user_name}:staff\" \"$target_app\"; then echo 'Could not set ownership on the installed RustAdmin app.' >&2; exit 1; fi; /usr/bin/xattr -r -d com.apple.quarantine \"$target_app\" 2>/dev/null || true;"

    set rollback_q to quoted form of rollback
    set shell_script to "set -eu;daemon_running=0;agent_running=0;agent_domain='';target_moved=0;staging_root='';backup_root='';" & assignments & validate_paths & validate_identity & "trap " & rollback_q & " EXIT;" & prepare_copy & discover_state & stop_services & kill_processes & replace_app & restore_services & "if [ \"$restore_failed\" = 1 ]; then echo 'Could not restore one or more previously running RustAdmin services.' >&2; exit 1; fi; trap - EXIT;" & cleanup_files
    if test_mode is "return-shell-script" then return shell_script
    do shell script shell_script with prompt "RustAdmin Update needs administrator permission to replace the installed app." with administrator privileges
end run
"""#

#if RUSTADMIN_UPDATER_TESTS
    static func generatedShellScriptForTesting(
        source: URL,
        target: URL,
        userName: String,
        daemonPlist: URL,
        agentPlist: URL,
        pgrepCommand: URL,
        killCommand: URL,
        launchctlCommand: URL,
        chownCommand: URL,
        moveCommand: URL? = nil
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            privilegedUpdateScriptForCompilation,
            source.path,
            target.path,
            UpdaterProduct.rustAdmin.appName,
            userName,
            UpdaterProduct.rustAdmin.bundleIdentifier,
            "2.0.6",
            "184",
            "2.0.5",
            "182",
            daemonPlist.path,
            agentPlist.path,
            "return-shell-script",
        ]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
        } catch {
            throw UpdateError.failed("Could not start osascript for shell generation: \(error.localizedDescription)")
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, let output, !output.isEmpty else {
            throw UpdateError.failed(output ?? "osascript could not generate the updater shell script.")
        }
        func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        var shell = output
        let replacements: [(String, URL)] = [
            ("/usr/bin/pgrep", pgrepCommand),
            ("/bin/kill", killCommand),
            ("/bin/launchctl", launchctlCommand),
            ("/usr/sbin/chown", chownCommand),
        ]
        for (original, replacement) in replacements {
            shell = shell.replacingOccurrences(of: original, with: shellQuote(replacement.path))
        }
        if let moveCommand {
            shell = shell.replacingOccurrences(of: "/bin/mv", with: shellQuote(moveCommand.path))
        }
        return shell
    }

    static var privilegedUpdateScriptForCompilation: String {
        privilegedUpdateScript.replacingOccurrences(
            of: "    do shell script shell_script with prompt \"RustAdmin Update needs administrator permission to replace the installed app.\" with administrator privileges\n",
            with: "    return shell_script\n"
        )
    }
#endif
}

struct UpdaterArguments {
    let source: URL
    let target: URL
    let appName: String
    let serviceIdentifier: String
    let stagingRoot: URL?
    let stagingToken: String?

    static func parse(arguments: [String]) throws -> UpdaterArguments {
        let supported = Set([
            "--source",
            "--target",
            "--app-name",
            "--service-id",
            "--staging-root",
            "--staging-token",
        ])
        for argument in arguments where argument.hasPrefix("--") && !supported.contains(argument) {
            throw UpdateError.malformedArguments("unknown option \(argument)")
        }

        func value(for name: String) throws -> String {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
                throw UpdateError.missingArgument(name)
            }
            let value = arguments[index + 1]
            guard !value.hasPrefix("--") else {
                throw UpdateError.missingArgument(name)
            }
            return value
        }

        func optionalValue(for name: String) throws -> String? {
            guard let index = arguments.firstIndex(of: name) else {
                return nil
            }
            guard arguments.indices.contains(index + 1) else {
                throw UpdateError.missingArgument(name)
            }
            let value = arguments[index + 1]
            guard !value.hasPrefix("--") else {
                throw UpdateError.missingArgument(name)
            }
            return value
        }

        let source = URL(fileURLWithPath: try value(for: "--source")).standardizedFileURL
        let target = URL(fileURLWithPath: try value(for: "--target")).standardizedFileURL
        let appName = try value(for: "--app-name")
        let serviceIdentifier = try value(for: "--service-id")
        guard !appName.isEmpty, !serviceIdentifier.isEmpty else {
            throw UpdateError.malformedArguments("application and service identifiers cannot be empty")
        }
        guard !appName.contains("/") else {
            throw UpdateError.malformedArguments("application name cannot contain '/'")
        }

        let stagingRootValue = try optionalValue(for: "--staging-root")
        let stagingTokenValue = try optionalValue(for: "--staging-token")
        guard (stagingRootValue == nil) == (stagingTokenValue == nil) else {
            throw UpdateError.malformedArguments("--staging-root and --staging-token must be supplied together")
        }

        return UpdaterArguments(
            source: source,
            target: target,
            appName: appName,
            serviceIdentifier: serviceIdentifier,
            stagingRoot: stagingRootValue.map { URL(fileURLWithPath: $0).standardizedFileURL },
            stagingToken: stagingTokenValue
        )
    }
}

enum SourceDiscovery {
    static func adjacentSource(
        to bundleURL: URL,
        product: UpdaterProduct,
        fileManager: FileManager = .default
    ) -> URL? {
        let helperURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let immediateCandidate = bundleURL
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(product.appName).app", isDirectory: true)
        if immediateCandidate.resolvingSymlinksInPath() != helperURL,
           (try? BundleMetadata.load(at: immediateCandidate, product: product, fileManager: fileManager)) != nil {
            return immediateCandidate.standardizedFileURL
        }

        var ancestor = helperURL.deletingLastPathComponent()
        while ancestor.pathComponents.count > 1 {
            guard ancestor.pathExtension == "app" else {
                ancestor = ancestor.deletingLastPathComponent()
                continue
            }

            let resourcesURL = ancestor
                .appendingPathComponent("Contents/Resources", isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let helperPath = helperURL.path
            if helperPath == resourcesURL.path || helperPath.hasPrefix(resourcesURL.path + "/"),
               (try? BundleMetadata.load(at: ancestor, product: product, fileManager: fileManager)) != nil {
                return ancestor.standardizedFileURL
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
        return nil
    }
}

#if !RUSTADMIN_UPDATER_TESTS
private final class UpdateWindowController: NSObject, NSWindowDelegate {
    private let request: UpdateRequest
    private let statusLabel = NSTextField(labelWithString: "Ready to update RustAdmin.")
    private let progressIndicator = NSProgressIndicator()
    private let updateButton = NSButton(title: "Update", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var hasStarted = false
    private var hasFinished = false
    private var window: NSWindow!

    var isPrivilegedUpdateRunning: Bool {
        hasStarted && !hasFinished
    }

    init(request: UpdateRequest) {
        self.request = request
        super.init()
        buildWindow()
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasFinished {
            cleanupAndTerminate()
            return false
        }
        guard !hasStarted else { return false }
        cancel()
        return false
    }

    @objc private func update() {
        guard !hasStarted else { return }
        hasStarted = true
        updateButton.isEnabled = false
        cancelButton.isEnabled = false
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "Updating RustAdmin… Approve the macOS permission request to continue."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.request.runPrivilegedUpdate()
                DispatchQueue.main.async { self.updateFinishedSuccessfully() }
            } catch {
                DispatchQueue.main.async { self.updateFailed(error) }
            }
        }
    }

    @objc private func cancel() {
        if hasFinished {
            cleanupAndTerminate()
            return
        }
        guard !hasStarted else { return }
        cleanupAndTerminate()
    }

    private func updateFinishedSuccessfully() {
        hasFinished = true
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusLabel.stringValue = "Update complete. Starting RustAdmin…"
        cancelButton.title = "Close"
        cancelButton.isEnabled = true
        openBundle(request.target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.cleanupAndTerminate()
        }
    }

    private func updateFailed(_ error: Error) {
        hasStarted = false
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        updateButton.title = "Try Again"
        updateButton.isEnabled = true
        cancelButton.isEnabled = true
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        statusLabel.stringValue = message
    }

    func cleanupStaging() {
        request.staging?.cleanupIfOwned()
    }

    private func cleanupAndTerminate() {
        cleanupStaging()
        NSApp.terminate(nil)
    }

    private func openBundle(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "RustAdmin Update"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let icon = NSImage(named: NSImage.applicationIconName)
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            ?? NSImage()
        let iconView = NSImageView(image: icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "A newer RustAdmin is ready")
        titleLabel.font = .boldSystemFont(ofSize: 20)

        let versionLabel = NSTextField(labelWithString: "Installed: \(request.installedVersion)    New: \(request.sourceVersion)")
        versionLabel.textColor = .secondaryLabelColor

        let explanationLabel = NSTextField(labelWithString: "RustAdmin will close, update the application and any installed service, then reopen.")
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.maximumNumberOfLines = 2

        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = true

        updateButton.target = self
        updateButton.action = #selector(update)
        updateButton.keyEquivalent = "\r"

        cancelButton.target = self
        cancelButton.action = #selector(cancel)

        let header = NSStackView(views: [iconView, titleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
        ])

        let statusRow = NSStackView(views: [progressIndicator, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 8

        let buttons = NSStackView(views: [NSView(), cancelButton, updateButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let content = NSStackView(views: [header, versionLabel, explanationLabel, statusRow, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        content.translatesAutoresizingMaskIntoConstraints = false

        window.contentView = NSView()
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -56),
            statusLabel.widthAnchor.constraint(equalToConstant: 440),
            explanationLabel.widthAnchor.constraint(equalToConstant: 440),
        ])
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: UpdateWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.isEmpty {
            do {
                let request = try UpdateRequest.discoverNoArgumentRequest(bundleURL: Bundle.main.bundleURL)
                try stageAndRelaunch(request: request)
            } catch UpdateError.sourceSelectionRequired {
                chooseSource()
            } catch {
                showError(error)
            }
            return
        }

        do {
            let request = try UpdateRequest.parse(arguments: arguments)
            let controller = UpdateWindowController(request: request)
            windowController = controller
            controller.showWindow()
        } catch {
            showError(error)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if windowController?.isPrivilegedUpdateRunning == true {
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.cleanupStaging()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func stageAndRelaunch(request: UpdateRequest) throws {
        let staging = try OwnedStagingDirectory.create(from: Bundle.main.bundleURL)
        do {
            try staging.launch(request: request)
        } catch {
            staging.cleanupIfOwned()
            throw error
        }
        NSApp.terminate(nil)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.message = "Choose the newer RustAdmin.app from the downloaded archive or mounted installer."
        panel.prompt = "Choose RustAdmin"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = Bundle.main.bundleURL.deletingLastPathComponent()

        guard panel.runModal() == .OK, let source = panel.url else {
            NSApp.terminate(nil)
            return
        }

        do {
            let request = try UpdateRequest.make(
                source: source,
                target: UpdaterProduct.rustAdmin.defaultTarget,
                product: .rustAdmin
            )
            try stageAndRelaunch(request: request)
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "RustAdmin Update"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "Close")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

@main
private struct RustAdminUpdateMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
#endif
