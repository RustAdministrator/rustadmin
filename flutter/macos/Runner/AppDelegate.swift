import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    var launched = false
    private var savingWindowGeometry = false

    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !savingWindowGeometry else { return .terminateLater }
        guard let window = sender.windows.first(where: { $0 is MainFlutterWindow }) as? MainFlutterWindow else {
            return .terminateNow
        }
        savingWindowGeometry = true
        // Command-Q bypasses windowShouldClose. Let Dart finish its config write
        // before quitting, but never trap Quit when the Flutter engine is gone.
        DispatchQueue.main.async {
            var replied = false
            let finish = {
                guard !replied else { return }
                replied = true
                sender.reply(toApplicationShouldTerminate: true)
            }
            window.persistGeometryBeforeExit(completion: finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
        }
        return .terminateLater
    }

    private func restoreMainWindow(_ sender: NSApplication) {
        guard let window = sender.windows.first(where: { $0 is MainFlutterWindow }) else {
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        dummy_method_to_enforce_bundling()
        // https://github.com/leanflutter/window_manager/issues/214
        return false
    }

    override func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if launched {
            handle_applicationShouldOpenUntitledFile()
            restoreMainWindow(sender)
        }
        return true
    }

    override func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        restoreMainWindow(sender)
        return true
    }

    override func applicationDidFinishLaunching(_ aNotification: Notification) {
        launched = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
