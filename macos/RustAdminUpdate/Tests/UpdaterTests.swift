import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

private enum MockLaunchctlMode: Equatable {
    case absent
    case stopped
    case running
}

private struct ShellMocks {
    let logURL: URL
    let pgrepURL: URL
    let killURL: URL
    let launchctlURL: URL
    let chownURL: URL
    let moveURL: URL
    let daemonPlistURL: URL
    let agentPlistURL: URL
}

private struct UpdaterTestSuite {
    private let fileManager = FileManager.default
    private let product = UpdaterProduct.rustAdmin

    func run() throws {
        try testNumericVersionOrdering()
        try testExplicitArgumentsAndNewerRevision()
        try testMissingAndWrongBundles()
        try testSymlinkAliasAndDiscovery()
        try testStagingOwnershipBoundaries()
        try testPrivilegedScriptOrdering()
    }

    func dumpPrivilegedScript(to path: String, compilationSafe: Bool = false) throws {
        let script = compilationSafe
            ? UpdateRequest.privilegedUpdateScriptForCompilation
            : UpdateRequest.privilegedUpdateScript
        try script.write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )
    }

    private func testNumericVersionOrdering() throws {
        guard let oneTen = NumericVersion.parse("1.10"),
              let oneNine = NumericVersion.parse("1.9"),
              oneTen > oneNine
        else {
            throw TestFailure.failed("numeric version ordering treated 1.10 as older than 1.9")
        }

        let lowerRevision = BundleVersion(
            numericVersion: NumericVersion.parse("2.0.5")!,
            revision: 182,
            rawVersion: "2.0.5",
            rawRevision: "182"
        )
        let higherRevision = BundleVersion(
            numericVersion: NumericVersion.parse("2.0.5")!,
            revision: 184,
            rawVersion: "2.0.5",
            rawRevision: "184"
        )
        guard higherRevision > lowerRevision else {
            throw TestFailure.failed("revision ordering did not select the newer build")
        }

        let equivalentSpelling = BundleVersion(
            numericVersion: NumericVersion.parse("2.0.5.0")!,
            revision: 182,
            rawVersion: "2.0.5.0",
            rawRevision: "0182"
        )
        let canonicalSpelling = BundleVersion(
            numericVersion: NumericVersion.parse("2.0.5")!,
            revision: 182,
            rawVersion: "2.0.5",
            rawRevision: "182"
        )
        guard equivalentSpelling == canonicalSpelling else {
            throw TestFailure.failed("BundleVersion equality included raw metadata spelling")
        }
    }

    private func testExplicitArgumentsAndNewerRevision() throws {
        let root = try makeTemporaryDirectory(named: "explicit")
        defer { try? fileManager.removeItem(at: root) }

        let target = try makeApp(
            at: root.appendingPathComponent("installed/RustAdmin.app"),
            version: "2.0.5",
            revision: "182"
        )
        let source = try makeApp(
            at: root.appendingPathComponent("download/RustAdmin.app"),
            version: "2.0.5",
            revision: "184"
        )

        let arguments = [
            "--source", source.path,
            "--target", target.path,
            "--app-name", "RustAdmin",
            "--service-id", "io.github.rustadministrator.rustadmin",
        ]
        let request = try UpdateRequest.parse(arguments: arguments)
        guard request.source == source.standardizedFileURL,
              request.target == target.standardizedFileURL,
              request.sourceVersion.revision == 184,
              request.installedVersion.revision == 182,
              request.staging == nil
        else {
            throw TestFailure.failed("explicit updater arguments were not retained")
        }

        let olderSource = try makeApp(
            at: root.appendingPathComponent("older/RustAdmin.app"),
            version: "2.0.5",
            revision: "181"
        )
        do {
            _ = try UpdateRequest.make(source: olderSource, target: target, product: product)
            throw TestFailure.failed("an older source was accepted")
        } catch let error as UpdateError {
            guard case .sourceNotNewer = error else {
                throw TestFailure.failed("older source returned the wrong error: \(error)")
            }
        }
    }

    private func testMissingAndWrongBundles() throws {
        let root = try makeTemporaryDirectory(named: "validation")
        defer { try? fileManager.removeItem(at: root) }

        let target = try makeApp(
            at: root.appendingPathComponent("installed/RustAdmin.app"),
            version: "2.0.5",
            revision: "182"
        )
        let source = try makeApp(
            at: root.appendingPathComponent("download/RustAdmin.app"),
            version: "2.0.6",
            revision: "184"
        )
        let missingTarget = root.appendingPathComponent("missing/RustAdmin.app")

        do {
            _ = try UpdateRequest.make(source: source, target: missingTarget, product: product)
            throw TestFailure.failed("missing installed app was accepted")
        } catch let error as UpdateError {
            guard case .missingTarget(let url) = error, url == missingTarget.standardizedFileURL else {
                throw TestFailure.failed("missing installed app returned the wrong error: \(error)")
            }
            guard error.errorDescription?.lowercased().contains("drag rustadmin.app") == true else {
                throw TestFailure.failed("missing installed app did not explain drag-to-Applications installation")
            }
        }

        let wrongSource = try makeApp(
            at: root.appendingPathComponent("wrong/RustAdmin.app"),
            version: "2.0.7",
            revision: "185",
            bundleIdentifier: "com.example.other"
        )
        do {
            _ = try UpdateRequest.make(source: wrongSource, target: target, product: product)
            throw TestFailure.failed("wrong product identity was accepted")
        } catch let error as UpdateError {
            guard case .invalidSource = error else {
                throw TestFailure.failed("wrong product identity returned the wrong error: \(error)")
            }
        }

        let invalidVersion = try makeApp(
            at: root.appendingPathComponent("invalid/RustAdmin.app"),
            version: "2.beta",
            revision: "186"
        )
        do {
            _ = try UpdateRequest.make(source: invalidVersion, target: target, product: product)
            throw TestFailure.failed("non-numeric source version was accepted")
        } catch let error as UpdateError {
            guard case .invalidSource = error else {
                throw TestFailure.failed("invalid source version returned the wrong error: \(error)")
            }
        }
    }

    private func testSymlinkAliasAndDiscovery() throws {
        let root = try makeTemporaryDirectory(named: "discovery")
        defer { try? fileManager.removeItem(at: root) }

        let target = try makeApp(
            at: root.appendingPathComponent("installed/RustAdmin.app"),
            version: "2.0.5",
            revision: "182"
        )
        let sourceAlias = root.appendingPathComponent("alias/RustAdmin.app")
        try fileManager.createDirectory(at: sourceAlias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: sourceAlias, withDestinationURL: target)
        do {
            _ = try UpdateRequest.make(source: sourceAlias, target: target, product: product)
            throw TestFailure.failed("a symlink alias of the installed app was accepted")
        } catch let error as UpdateError {
            guard case .sameBundle = error else {
                throw TestFailure.failed("symlink alias returned the wrong error: \(error)")
            }
        }

        let source = try makeApp(
            at: root.appendingPathComponent("download/RustAdmin.app"),
            version: "2.0.6",
            revision: "184"
        )
        let helper = root.appendingPathComponent("download/RustAdminUpdate.app")
        try makeHelper(at: helper)
        guard SourceDiscovery.adjacentSource(to: helper, product: product) == source.standardizedFileURL else {
            throw TestFailure.failed("standalone helper did not discover its adjacent RustAdmin.app")
        }

        let enclosingRoot = root.appendingPathComponent("enclosing")
        let enclosingApp = try makeApp(
            at: enclosingRoot.appendingPathComponent("RustAdmin.app"),
            version: "2.0.6",
            revision: "184"
        )
        let embeddedHelper = enclosingApp
            .appendingPathComponent("Contents/Resources/RustAdminUpdate.app", isDirectory: true)
        try makeHelper(at: embeddedHelper)
        guard SourceDiscovery.adjacentSource(to: embeddedHelper, product: product) == enclosingApp.standardizedFileURL else {
            throw TestFailure.failed("embedded helper did not discover its enclosing RustAdmin.app")
        }

        _ = try makeApp(
            at: root.appendingPathComponent("RustAdmin.app"),
            version: "9.9.9",
            revision: "999"
        )
        let absentHelper = root.appendingPathComponent("copied/deeper/RustAdminUpdate.app")
        try makeHelper(at: absentHelper)
        guard SourceDiscovery.adjacentSource(to: absentHelper, product: product) == nil else {
            throw TestFailure.failed("helper selected an unrelated higher-ancestor RustAdmin.app")
        }
    }

    private func testStagingOwnershipBoundaries() throws {
        let root = try makeTemporaryDirectory(named: "staging")
        defer { try? fileManager.removeItem(at: root) }

        let helper = root.appendingPathComponent("RustAdminUpdate.app")
        try makeHelper(at: helper)
        let staging = try OwnedStagingDirectory.create(from: helper)
        guard OwnedStagingDirectory.provesOwnership(rootURL: staging.rootURL, token: staging.token),
              fileManager.fileExists(atPath: staging.appURL.path)
        else {
            throw TestFailure.failed("owned staging directory was not recognized")
        }

        let distributedHelper = root.appendingPathComponent("distributed/RustAdminUpdate.app")
        try makeHelper(at: distributedHelper)
        guard !OwnedStagingDirectory.provesOwnership(
            rootURL: distributedHelper,
            token: staging.token
        ) else {
            throw TestFailure.failed("distributed helper was mistaken for owned staging")
        }
        staging.cleanupIfOwned()
        guard !fileManager.fileExists(atPath: staging.rootURL.path),
              fileManager.fileExists(atPath: distributedHelper.path)
        else {
            throw TestFailure.failed("staging cleanup crossed the ownership boundary")
        }

        let foreignRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(OwnedStagingDirectory.directoryPrefix)foreign", isDirectory: true)
        try fileManager.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
        try Data("different-token".utf8).write(
            to: foreignRoot.appendingPathComponent(OwnedStagingDirectory.markerName)
        )
        guard !OwnedStagingDirectory.provesOwnership(
            rootURL: foreignRoot,
            token: staging.token
        ) else {
            throw TestFailure.failed("foreign marker was accepted as staging ownership")
        }
        try fileManager.removeItem(at: foreignRoot)
    }

    private func testPrivilegedScriptOrdering() throws {
        let script = UpdateRequest.privilegedUpdateScript
        guard script.contains("set assignments to"),
              script.contains("set rollback_q to quoted form of rollback"),
              !script.contains("trap '"),
              script.contains("set restore_services to"),
              script.contains("set cleanup_staging to"),
              script.contains("/usr/sbin/chown"),
              !script.contains("/usr/bin/chown")
        else {
            throw TestFailure.failed("privileged script is missing validation, staging, or rollback structure")
        }

        guard let staged = script.range(of: "set prepare_copy"),
              let stopped = script.range(of: "set stop_services"),
              staged.lowerBound < stopped.lowerBound
        else {
            throw TestFailure.failed("privileged script does not stage the payload before service stop")
        }

        try testGeneratedShellStopsBeforeMutation()
        try testNoServiceUpdateSuccess()
        try testStoppedServicePreservation()
        try testRunningServiceStopAndRestart()
        try testReplaceFailureRestoresTarget()
        try testRestoreMoveFailurePreservesBackup()
    }

    private func testGeneratedShellStopsBeforeMutation() throws {
        let root = try makeTemporaryDirectory(named: "shell-fixture")
        defer { try? fileManager.removeItem(at: root) }
        let mocks = try makeShellMocks(at: root, launchctlMode: .absent, chownSucceeds: true)
        let source = root.appendingPathComponent("Updater review's source/RustAdmin.app")
        let target = root.appendingPathComponent("Updater review's target/RustAdmin.app")
        let shellURL = try makeShellScript(
            at: root,
            named: "generated-update-shell.sh",
            source: source,
            target: target,
            mocks: mocks
        )

        let execution = try runProcess(executable: "/bin/sh", arguments: [shellURL.path])
        guard execution.status != 0,
              execution.output.contains("Update source disappeared before authorization."),
              !fileManager.fileExists(atPath: target.path)
        else {
            throw TestFailure.failed("missing-source fixture did not abort before mutation: \(execution.output)")
        }
    }

    private func testNoServiceUpdateSuccess() throws {
        let root = try makeTemporaryDirectory(named: "shell-no-service")
        defer { try? fileManager.removeItem(at: root) }
        let mocks = try makeShellMocks(at: root, launchctlMode: .absent, chownSucceeds: true)
        let source = try makeApp(
            at: root.appendingPathComponent("Updater review's source/RustAdmin.app"),
            version: "2.0.6",
            revision: "184"
        )
        let target = try makeApp(
            at: root.appendingPathComponent("Updater review's target/RustAdmin.app"),
            version: "2.0.5",
            revision: "182"
        )
        let shellURL = try makeShellScript(
            at: root,
            named: "no-service-shell.sh",
            source: source,
            target: target,
            mocks: mocks
        )
        let execution = try runProcess(executable: "/bin/sh", arguments: [shellURL.path])
        let log = try readLog(at: mocks.logURL)
        guard execution.status == 0,
              try metadataData(for: target) == metadataData(for: source),
              log.contains("/pgrep -x RustAdmin"),
              log.contains("/kill -9 999999"),
              log.contains("/chown -R"),
              !log.contains("/launchctl")
        else {
            throw TestFailure.failed("no-service update fixture failed or used a service command: \(execution.output)\n\(log)")
        }
        try assertNoBackupDirectories(in: target.deletingLastPathComponent())
    }

    private func testStoppedServicePreservation() throws {
        let root = try makeTemporaryDirectory(named: "shell-stopped-service")
        defer { try? fileManager.removeItem(at: root) }
        let mocks = try makeShellMocks(at: root, launchctlMode: .stopped, chownSucceeds: true)
        let source = try makeApp(
            at: root.appendingPathComponent("source/RustAdmin.app"),
            version: "2.0.6",
            revision: "184"
        )
        let target = try makeApp(
            at: root.appendingPathComponent("target/RustAdmin.app"),
            version: "2.0.5",
            revision: "182"
        )
        let shellURL = try makeShellScript(
            at: root,
            named: "stopped-service-shell.sh",
            source: source,
            target: target,
            mocks: mocks
        )
        let execution = try runProcess(executable: "/bin/sh", arguments: [shellURL.path])
        let log = try readLog(at: mocks.logURL)
        guard execution.status == 0,
              try metadataData(for: target) == metadataData(for: source),
              log.contains("/launchctl print system/"),
              log.contains("/launchctl print gui/"),
              !log.contains("/launchctl bootout"),
              !log.contains("/launchctl unload"),
              !log.contains("/launchctl bootstrap"),
              !log.contains("/launchctl load"),
              !log.contains("/launchctl kickstart")
        else {
            throw TestFailure.failed("stopped-service fixture changed service state or failed: \(execution.output)\n\(log)")
        }
        try assertNoBackupDirectories(in: target.deletingLastPathComponent())
    }

    private func testRunningServiceStopAndRestart() throws {
        let root = try makeTemporaryDirectory(named: "shell-running-service")
        defer { try? fileManager.removeItem(at: root) }
        let mocks = try makeShellMocks(at: root, launchctlMode: .running, chownSucceeds: true)
        let source = try makeApp(
            at: root.appendingPathComponent("source/RustAdmin.app"),
            version: "2.0.6",
            revision: "184"
        )
        let target = try makeApp(
            at: root.appendingPathComponent("target/RustAdmin.app"),
            version: "2.0.5",
            revision: "182"
        )
        let shellURL = try makeShellScript(
            at: root,
            named: "running-service-shell.sh",
            source: source,
            target: target,
            mocks: mocks
        )
        let execution = try runProcess(executable: "/bin/sh", arguments: [shellURL.path])
        let logLines = try readLog(at: mocks.logURL).split(separator: "\n").map(String.init)
        func index(of text: String) -> Int? {
            logLines.firstIndex(where: { $0.contains(text) })
        }
        let metadataMatches = try metadataData(for: target) == metadataData(for: source)
        let agentStop = index(of: "/launchctl bootout gui/")
        let daemonStop = index(of: "/launchctl bootout system/")
        let daemonStart = index(of: "/launchctl bootstrap system ")
        let daemonKick = index(of: "/launchctl kickstart -k system/")
        let agentStart = index(of: "/launchctl bootstrap gui/")
        let agentKick = index(of: "/launchctl kickstart -k gui/")
        let ordered = [agentStop, daemonStop, daemonStart, daemonKick, agentStart, agentKick]
            .compactMap { $0 }
        let usesLiveLaunchctl = logLines.contains(where: { $0.contains("/bin/launchctl") })
        guard execution.status == 0,
              metadataMatches,
              ordered.count == 6,
              ordered == ordered.sorted(),
              !usesLiveLaunchctl
        else {
            throw TestFailure.failed("running-service fixture did not stop/restart through the mock: status=\(execution.status) metadata=\(metadataMatches) indexes=\(ordered) live=\(usesLiveLaunchctl)\n\(execution.output)\n\(logLines.joined(separator: "\n"))")
        }
        try assertNoBackupDirectories(in: target.deletingLastPathComponent())
    }

    private func testReplaceFailureRestoresTarget() throws {
        let root = try makeTemporaryDirectory(named: "shell-replace-failure")
        defer { try? fileManager.removeItem(at: root) }
        let mocks = try makeShellMocks(at: root, launchctlMode: .absent, chownSucceeds: false)
        let source = try makeApp(
            at: root.appendingPathComponent("source/RustAdmin.app"),
            version: "2.0.6",
            revision: "184"
        )
        let target = try makeApp(
            at: root.appendingPathComponent("target/RustAdmin.app"),
            version: "2.0.5",
            revision: "182"
        )
        let originalMetadata = try metadataData(for: target)
        let oldMarker = target.appendingPathComponent("old-target-marker")
        try Data("old target payload".utf8).write(to: oldMarker)
        let shellURL = try makeShellScript(
            at: root,
            named: "replace-failure-shell.sh",
            source: source,
            target: target,
            mocks: mocks
        )
        let execution = try runProcess(executable: "/bin/sh", arguments: [shellURL.path])
        guard execution.status != 0,
              execution.output.contains("Could not set ownership on the installed RustAdmin app."),
              try metadataData(for: target) == originalMetadata,
              fileManager.fileExists(atPath: oldMarker.path),
              !fileManager.fileExists(atPath: source.appendingPathComponent("old-target-marker").path)
        else {
            throw TestFailure.failed("replace failure did not restore the old target: \(execution.output)")
        }
        try assertNoBackupDirectories(in: target.deletingLastPathComponent())
    }

    private func testRestoreMoveFailurePreservesBackup() throws {
        let root = try makeTemporaryDirectory(named: "shell-restore-move-failure")
        defer { try? fileManager.removeItem(at: root) }
        let mocks = try makeShellMocks(
            at: root,
            launchctlMode: .absent,
            chownSucceeds: false,
            failRestoreMove: true
        )
        let source = try makeApp(
            at: root.appendingPathComponent("Updater review's source/RustAdmin.app"),
            version: "2.0.6",
            revision: "184"
        )
        let target = try makeApp(
            at: root.appendingPathComponent("Updater review's target/RustAdmin.app"),
            version: "2.0.5",
            revision: "182"
        )
        let originalMetadata = try metadataData(for: target)
        let shellURL = try makeShellScript(
            at: root,
            named: "restore-move-failure-shell.sh",
            source: source,
            target: target,
            mocks: mocks
        )
        let execution = try runProcess(executable: "/bin/sh", arguments: [shellURL.path])
        let backupParent = target.deletingLastPathComponent()
        let leftoverBackups = try fileManager.contentsOfDirectory(at: backupParent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".RustAdminUpdate-backup.") }
        guard leftoverBackups.count == 1 else {
            throw TestFailure.failed("restore-move fixture did not leave exactly one backup: \(execution.output)")
        }
        let backupApp = leftoverBackups[0].appendingPathComponent(target.lastPathComponent)
        let backupMetadataMatches = try metadataData(for: backupApp) == originalMetadata
        let targetExists = fileManager.fileExists(atPath: target.path)
        let backupPaths = [backupApp.path, backupApp.resolvingSymlinksInPath().path]
        let reportsBackup = execution.output.contains("UPDATE ROLLBACK FAILED: intact backup remains at")
            && backupPaths.contains(where: { execution.output.contains($0) })
        guard execution.status != 0,
              reportsBackup,
              !targetExists,
              backupMetadataMatches
        else {
            throw TestFailure.failed("restore-move fixture did not preserve/report the backup: status=\(execution.status) reports=\(reportsBackup) targetExists=\(targetExists) metadata=\(backupMetadataMatches) backup=\(backupApp.path)\n\(execution.output)")
        }
    }

    private func makeShellMocks(
        at root: URL,
        launchctlMode: MockLaunchctlMode,
        chownSucceeds: Bool,
        failRestoreMove: Bool = false
    ) throws -> ShellMocks {
        let mocksRoot = root.appendingPathComponent("mocks", isDirectory: true)
        try fileManager.createDirectory(at: mocksRoot, withIntermediateDirectories: true)
        let logURL = root.appendingPathComponent("mock-commands.log")
        let pgrepURL = mocksRoot.appendingPathComponent("pgrep")
        let killURL = mocksRoot.appendingPathComponent("kill")
        let launchctlURL = mocksRoot.appendingPathComponent("launchctl")
        let chownURL = mocksRoot.appendingPathComponent("chown")
        let moveURL = mocksRoot.appendingPathComponent("mv")
        try makeMockCommand(
            at: pgrepURL,
            logURL: logURL,
            body: "printf '999999\\n'"
        )
        try makeMockCommand(
            at: killURL,
            logURL: logURL,
            body: "exit 0"
        )

        let launchctlBody: String
        switch launchctlMode {
        case .absent:
            launchctlBody = "exit 99"
        case .stopped:
            launchctlBody = "if [ \"$1\" = \"print\" ]; then exit 1; fi\nexit 99"
        case .running:
            launchctlBody = "exit 0"
        }
        try makeMockCommand(at: launchctlURL, logURL: logURL, body: launchctlBody)
        try makeMockCommand(
            at: chownURL,
            logURL: logURL,
            body: chownSucceeds ? "exit 0" : "exit 1"
        )

        let moveBody: String
        if failRestoreMove {
            moveBody = "case \"$1\" in\n*/.RustAdminUpdate-backup.*) exit 1 ;;\nesac\nexec /bin/mv \"$@\""
        } else {
            moveBody = "exec /bin/mv \"$@\""
        }
        try makeMockCommand(at: moveURL, logURL: logURL, body: moveBody)

        let serviceRoot = root.appendingPathComponent("services", isDirectory: true)
        try fileManager.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
        let daemonPlistURL = serviceRoot.appendingPathComponent("daemon.plist")
        let agentPlistURL = serviceRoot.appendingPathComponent("agent.plist")
        if launchctlMode != .absent {
            try Data().write(to: daemonPlistURL)
            try Data().write(to: agentPlistURL)
        }

        return ShellMocks(
            logURL: logURL,
            pgrepURL: pgrepURL,
            killURL: killURL,
            launchctlURL: launchctlURL,
            chownURL: chownURL,
            moveURL: moveURL,
            daemonPlistURL: daemonPlistURL,
            agentPlistURL: agentPlistURL
        )
    }

    private func makeMockCommand(at url: URL, logURL: URL, body: String) throws {
        let script = "#!/bin/sh\nprintf '%s\\n' \"$0 $*\" >> \(shellQuote(logURL.path))\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeShellScript(
        at root: URL,
        named name: String,
        source: URL,
        target: URL,
        mocks: ShellMocks,
        userName: String = NSUserName()
    ) throws -> URL {
        let shell = try UpdateRequest.generatedShellScriptForTesting(
            source: source,
            target: target,
            userName: userName,
            daemonPlist: mocks.daemonPlistURL,
            agentPlist: mocks.agentPlistURL,
            pgrepCommand: mocks.pgrepURL,
            killCommand: mocks.killURL,
            launchctlCommand: mocks.launchctlURL,
            chownCommand: mocks.chownURL,
            moveCommand: mocks.moveURL
        )
        guard !shell.contains("/usr/bin/pgrep"),
              !shell.contains("/bin/kill"),
              !shell.contains("/bin/launchctl"),
              !shell.contains("/usr/sbin/chown"),
              !shell.contains("/bin/mv")
        else {
            throw TestFailure.failed("generated fixture shell retained a live process, service, or ownership command")
        }

        let shellURL = root.appendingPathComponent(name)
        try shell.write(to: shellURL, atomically: true, encoding: .utf8)
        let syntax = try runProcess(executable: "/bin/sh", arguments: ["-n", shellURL.path])
        guard syntax.status == 0 else {
            throw TestFailure.failed("generated updater shell failed /bin/sh -n: \(syntax.output)")
        }
        return shellURL
    }

    private func readLog(at url: URL) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func metadataData(for app: URL) throws -> Data {
        try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    }

    private func assertNoBackupDirectories(in parent: URL) throws {
        let backups = try fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".RustAdminUpdate-backup.") }
        guard backups.isEmpty else {
            throw TestFailure.failed("temporary backup directory was not cleaned: \(backups.map(\.path).joined(separator: ", "))")
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runProcess(executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outputData, encoding: .utf8) ?? ""
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("rustadmin-updater-test-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @discardableResult
    private func makeApp(
        at url: URL,
        version: String,
        revision: String,
        bundleIdentifier: String = UpdaterProduct.rustAdmin.bundleIdentifier,
        executable: String = UpdaterProduct.rustAdmin.appName
    ) throws -> URL {
        let executableURL = url
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executable)
        try fileManager.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": revision,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        guard fileManager.createFile(atPath: executableURL.path, contents: Data()) else {
            throw TestFailure.failed("could not create test executable at \(executableURL.path)")
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return url
    }

    private func makeHelper(at url: URL) throws {
        let executableURL = url
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("RustAdminUpdate")
        try fileManager.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: executableURL.path, contents: Data()) else {
            throw TestFailure.failed("could not create test updater executable at \(executableURL.path)")
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }
}

@main
private struct UpdaterTestsMain {
    static func main() throws {
        let suite = UpdaterTestSuite()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2, arguments[0] == "--dump-privileged-script" {
            try suite.dumpPrivilegedScript(to: arguments[1])
            return
        }
        if arguments.count == 2, arguments[0] == "--dump-test-privileged-script" {
            try suite.dumpPrivilegedScript(to: arguments[1], compilationSafe: true)
            return
        }

        try suite.run()
        print("macOS updater focused tests passed")
    }
}
