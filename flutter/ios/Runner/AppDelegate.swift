import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var clipboardChannel: FlutterMethodChannel?
  private var clipboardReadCount: Int?
  private var clipboardReadText: String?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    dummyMethodToEnforceBundling();
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "rustadmin/clipboard",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "readText" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self, UIApplication.shared.applicationState == .active else {
        result(nil)
        return
      }
      let pasteboard = UIPasteboard.general
      let count = pasteboard.changeCount
      if self.clipboardReadCount == count {
        result(self.clipboardReadText)
        return
      }
      var text: String?
      let types = pasteboard.types
      if !types.contains("public.file-url") &&
         !types.contains("com.apple.is-remote-clipboard") &&
         !types.contains("dyn.com.rustdesk.owner") {
        text = pasteboard.string
        if text == nil, let url = pasteboard.url, !url.isFileURL,
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
          text = url.absoluteString
        }
      }
      guard count == pasteboard.changeCount else {
        result(nil)
        return
      }
      if let value = text, value.utf8.count > 4 * 1024 * 1024 {
        text = nil
      }
      self.clipboardReadCount = count
      self.clipboardReadText = text
      result(text)
    }
    clipboardChannel = channel
  }
    
  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }
}
