import AppKit
import Foundation

private enum UpdateError: LocalizedError {
    case missingArgument(String)
    case invalidSource(URL)
    case invalidTarget(URL)
    case sameBundle
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "RustAdmin Update was started without \(name)."
        case .invalidSource(let url):
            return "The update source is not a valid RustAdmin app:\n\(url.path)"
        case .invalidTarget(let url):
            return "The installed RustAdmin app was not found:\n\(url.path)"
        case .sameBundle:
            return "The update source is already the installed RustAdmin app. Open a newer copy from the downloaded archive."
        case .failed(let message):
            return message
        }
    }
}

private struct UpdateRequest {
    let source: URL
    let target: URL
    let appName: String
    let serviceID: String

    var daemonPlist: String {
        "/Library/LaunchDaemons/\(serviceID)_service.plist"
    }

    var agentPlist: String {
        "/Library/LaunchAgents/\(serviceID)_server.plist"
    }

    var sourceVersion: String {
        Self.bundleVersion(at: source)
    }

    var installedVersion: String {
        Self.bundleVersion(at: target)
    }

    static func parse(arguments: [String]) throws -> UpdateRequest {
        guard let sourcePath = value(for: "--source", in: arguments) else {
            throw UpdateError.missingArgument("the update source")
        }
        guard let targetPath = value(for: "--target", in: arguments) else {
            throw UpdateError.missingArgument("the installed app path")
        }
        guard let appName = value(for: "--app-name", in: arguments), !appName.isEmpty else {
            throw UpdateError.missingArgument("the app name")
        }
        guard let serviceID = value(for: "--service-id", in: arguments), !serviceID.isEmpty else {
            throw UpdateError.missingArgument("the service identifier")
        }

        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let target = URL(fileURLWithPath: targetPath).standardizedFileURL
        let sourceExecutable = source
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(appName)
        let targetExecutable = target
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(appName)

        guard FileManager.default.isExecutableFile(atPath: sourceExecutable.path) else {
            throw UpdateError.invalidSource(source)
        }
        guard FileManager.default.isExecutableFile(atPath: targetExecutable.path) else {
            throw UpdateError.invalidTarget(target)
        }

        let resolvedSource = source.resolvingSymlinksInPath()
        let resolvedTarget = target.resolvingSymlinksInPath()
        guard resolvedSource != resolvedTarget else {
            throw UpdateError.sameBundle
        }

        return UpdateRequest(
            source: source,
            target: target,
            appName: appName,
            serviceID: serviceID
        )
    }

    func runPrivilegedUpdate() throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            Self.privilegedUpdateScript,
            source.path,
            target.path,
            appName,
            NSUserName(),
            daemonPlist,
            agentPlist,
        ]
        process.standardError = errorPipe
        process.standardOutput = errorPipe

        do {
            try process.run()
        } catch {
            throw UpdateError.failed("Could not start the macOS update helper: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = output.flatMap { $0.isEmpty ? nil : $0 }
            throw UpdateError.failed(detail ?? "The update was canceled or macOS could not replace the installed app.")
        }
    }

    private static func value(for name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func bundleVersion(at url: URL) -> String {
        let infoURL = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return "unknown"
        }

        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let revision = (info["RustAdminRevision"] as? String)
            ?? (info["CFBundleVersion"] as? String)
        guard let revision, !revision.isEmpty else {
            return version
        }
        return "\(version) (\(revision))"
    }

    private static let privilegedUpdateScript = #"""
on run {source_dir, target_app, app_name, user_name, daemon_plist, agent_plist}
    set source_q to quoted form of source_dir
    set target_q to quoted form of target_app
    set user_q to quoted form of user_name
    set daemon_q to quoted form of daemon_plist
    set agent_q to quoted form of agent_plist

    set check_paths to "/bin/test -d " & source_q & " && /bin/test -f " & source_q & "/Contents/Info.plist && /bin/test " & source_q & " != " & target_q & ";"
    set discover_state to "uid=$(/usr/bin/id -u " & user_q & " 2>/dev/null || true); daemon_label=$(/usr/bin/basename " & daemon_q & " .plist); agent_label=$(/usr/bin/basename " & agent_q & " .plist); daemon_installed=0; daemon_running=0; agent_running=0; agent_domain=''; if /bin/test -f " & daemon_q & " && /bin/test -f " & agent_q & "; then daemon_installed=1; fi; if [ \"$daemon_installed\" = 1 ] && /bin/launchctl print system/$daemon_label >/dev/null 2>&1; then daemon_running=1; fi; if [ \"$daemon_installed\" = 1 ] && [ -n \"$uid\" ]; then if /bin/launchctl print gui/$uid/$agent_label >/dev/null 2>&1; then agent_running=1; agent_domain=gui/$uid; elif /bin/launchctl print user/$uid/$agent_label >/dev/null 2>&1; then agent_running=1; agent_domain=user/$uid; fi; fi;"
    set unload_agent to "if [ \"$agent_running\" = 1 ]; then /bin/launchctl bootout \"$agent_domain/$agent_label\" 2>/dev/null || /bin/launchctl unload -w " & agent_q & " 2>/dev/null || true; fi;"
    set unload_daemon to "if [ \"$daemon_running\" = 1 ]; then /bin/launchctl bootout system/$daemon_label 2>/dev/null || /bin/launchctl unload -w " & daemon_q & " 2>/dev/null || true; fi;"
    set kill_others to "pids=$(/usr/bin/pgrep -x " & quoted form of app_name & " || true); if [ -n \"$pids\" ]; then echo \"$pids\" | /usr/bin/xargs /bin/kill -9 || true; fi;"
    set copy_files to "staging=" & target_q & ".new.$$; backup=" & target_q & ".old.$$; /bin/rm -rf \"$staging\" \"$backup\"; /usr/bin/ditto " & source_q & " \"$staging\"; /usr/sbin/chown -R " & user_q & ":staff \"$staging\"; /bin/mv " & target_q & " \"$backup\"; if ! /bin/mv \"$staging\" " & target_q & "; then /bin/mv \"$backup\" " & target_q & "; exit 1; fi; /bin/rm -rf \"$backup\"; /usr/bin/xattr -r -d com.apple.quarantine " & target_q & " 2>/dev/null || true;"
    set restore_services to "if [ \"$daemon_running\" = 1 ]; then /bin/launchctl bootstrap system " & daemon_q & " 2>/dev/null || /bin/launchctl load -w " & daemon_q & "; /bin/launchctl kickstart -k system/$daemon_label 2>/dev/null || true; fi; if [ \"$agent_running\" = 1 ] && [ -n \"$agent_domain\" ]; then /bin/launchctl bootstrap \"$agent_domain\" " & agent_q & " 2>/dev/null || /bin/launchctl load -w " & agent_q & "; /bin/launchctl kickstart -k \"$agent_domain/$agent_label\" 2>/dev/null || true; fi;"

    set shell_script to "set -e;" & check_paths & discover_state & unload_agent & unload_daemon & kill_others & copy_files & restore_services
    do shell script shell_script with prompt "RustAdmin Update needs administrator permission to replace the installed app." with administrator privileges
end run
"""#
}

private final class UpdateWindowController: NSObject, NSWindowDelegate {
    private let request: UpdateRequest
    private let statusLabel = NSTextField(labelWithString: "Ready to update RustAdmin.")
    private let progressIndicator = NSProgressIndicator()
    private let updateButton = NSButton(title: "Update", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var hasStarted = false
    private var hasFinished = false
    private var window: NSWindow!

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
            return true
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
        statusLabel.stringValue = "Requesting administrator permission…"

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
            NSApp.terminate(nil)
            return
        }
        guard !hasStarted else { return }
        openBundle(request.source)
        NSApp.terminate(nil)
    }

    private func updateFinishedSuccessfully() {
        hasFinished = true
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusLabel.stringValue = "Update complete. Starting RustAdmin…"
        cancelButton.title = "Close"
        cancelButton.isEnabled = true
        openBundle(request.target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.cleanupAndTerminate()
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

    private func cleanupAndTerminate() {
        try? FileManager.default.removeItem(at: Bundle.main.bundleURL)
        NSApp.terminate(nil)
    }

    private func openBundle(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", url.path]
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
            statusLabel.widthAnchor.constraint(equalToConstant: 440),
            explanationLabel.widthAnchor.constraint(equalToConstant: 440),
        ])
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: UpdateWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        do {
            let request = try UpdateRequest.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            let controller = UpdateWindowController(request: request)
            windowController = controller
            controller.showWindow()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "RustAdmin Update"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.addButton(withTitle: "Close")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
