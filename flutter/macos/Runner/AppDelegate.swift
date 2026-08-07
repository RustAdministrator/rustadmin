import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    var launched = false

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
