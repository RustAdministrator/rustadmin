#include "flutter_window.h"

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <texture_rgba_renderer/texture_rgba_renderer_plugin_c_api.h>
#include <flutter_gpu_texture_renderer/flutter_gpu_texture_renderer_plugin_c_api.h>

#include "flutter/generated_plugin_registrant.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <optional>
#include <memory>
#include <utility>

#include "win32_desktop.h"

namespace {

constexpr char kHostChannelName[] = "org.rustdesk.rustdesk/host";

HWND RootWindowForController(flutter::FlutterViewController* controller) {
  if (controller == nullptr || controller->view() == nullptr) {
    return nullptr;
  }

  HWND child = controller->view()->GetNativeWindow();
  if (child == nullptr || !IsWindow(child)) {
    return nullptr;
  }

  HWND root = GetAncestor(child, GA_ROOT);
  return root != nullptr && IsWindow(root) ? root : nullptr;
}

bool ParseFocusArgument(const flutter::EncodableValue* arguments,
                        bool* focus) {
  if (focus == nullptr) {
    return false;
  }

  *focus = true;
  if (arguments == nullptr ||
      std::holds_alternative<std::monostate>(*arguments)) {
    return true;
  }

  const auto* args_map = std::get_if<flutter::EncodableMap>(arguments);
  if (args_map == nullptr) {
    return false;
  }

  const auto focus_it = args_map->find(flutter::EncodableValue("focus"));
  if (focus_it == args_map->end()) {
    return true;
  }

  const auto* focus_value = std::get_if<bool>(&focus_it->second);
  if (focus_value == nullptr) {
    return false;
  }

  *focus = *focus_value;
  return true;
}

bool ShowWindowWithoutActivation(HWND window) {
  if (window == nullptr || !IsWindow(window)) {
    return false;
  }

  if (IsIconic(window)) {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    if (!GetWindowPlacement(window, &placement)) {
      return false;
    }
    placement.showCmd = SW_SHOWNOACTIVATE;
    if (!SetWindowPlacement(window, &placement)) {
      return false;
    }
  } else {
    ShowWindow(window, SW_SHOWNOACTIVATE);
  }

  if (!SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                       SWP_NOOWNERZORDER)) {
    return false;
  }

  return IsWindow(window) != FALSE;
}

bool ShowWindowWithFocus(HWND window) {
  if (window == nullptr || !IsWindow(window)) {
    return false;
  }

  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  return GetForegroundWindow() == window || SetForegroundWindow(window) != FALSE;
}

bool IsConnectionWindowFocused(flutter::FlutterViewController* controller) {
  HWND window = RootWindowForController(controller);
  return window != nullptr && GetForegroundWindow() == window;
}

void HandleHostMethodCall(
    flutter::FlutterViewController* controller,
    const flutter::MethodCall<>& call,
    std::unique_ptr<flutter::MethodResult<>> result) {
  if (call.method_name() == "showConnectionWindow") {
    bool focus = true;
    if (!ParseFocusArgument(call.arguments(), &focus)) {
      result->Success(false);
      return;
    }

    HWND window = RootWindowForController(controller);
    result->Success(focus ? ShowWindowWithFocus(window)
                          : ShowWindowWithoutActivation(window));
    return;
  }

  if (call.method_name() == "isConnectionWindowFocused") {
    result->Success(IsConnectionWindowFocused(controller));
    return;
  }

  if (call.method_name() == "bumpMouse") {
    auto arguments = call.arguments();

    int dx = 0, dy = 0;

    if (arguments != nullptr &&
        std::holds_alternative<flutter::EncodableMap>(*arguments)) {
      auto argsMap = std::get<flutter::EncodableMap>(*arguments);

      auto dxIt = argsMap.find(flutter::EncodableValue("dx"));
      auto dyIt = argsMap.find(flutter::EncodableValue("dy"));

      if ((dxIt != argsMap.end()) && std::holds_alternative<int>(dxIt->second)) {
        dx = std::get<int>(dxIt->second);
      }
      if ((dyIt != argsMap.end()) && std::holds_alternative<int>(dyIt->second)) {
        dy = std::get<int>(dyIt->second);
      }
    } else if (arguments != nullptr &&
               std::holds_alternative<flutter::EncodableList>(*arguments)) {
      auto argsList = std::get<flutter::EncodableList>(*arguments);

      if ((argsList.size() >= 1) && std::holds_alternative<int>(argsList[0])) {
        dx = std::get<int>(argsList[0]);
      }
      if ((argsList.size() >= 2) && std::holds_alternative<int>(argsList[1])) {
        dy = std::get<int>(argsList[1]);
      }
    }

    bool succeeded = Win32Desktop::BumpMouse(dx, dy);

    result->Success(succeeded);
    return;
  }

  result->NotImplemented();
}

struct HostMethodCallHandler {
  flutter::FlutterViewController* controller;

  void operator()(
      const flutter::MethodCall<>& call,
      std::unique_ptr<flutter::MethodResult<>> result) const {
    HandleHostMethodCall(controller, call, std::move(result));
  }
};

void RegisterHostChannel(flutter::FlutterViewController* controller) {
  if (controller == nullptr || controller->engine() == nullptr ||
      controller->view() == nullptr) {
    return;
  }

  flutter::MethodChannel<> channel(
      controller->engine()->messenger(), kHostChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler(HostMethodCallHandler{controller});
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterHostChannel(flutter_controller_.get());

  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    RegisterHostChannel(flutter_view_controller);
    auto *registry = flutter_view_controller->engine();
    TextureRgbaRendererPluginCApiRegisterWithRegistrar(
        registry->GetRegistrarForPlugin("TextureRgbaRendererPlugin"));
    FlutterGpuTextureRendererPluginCApiRegisterWithRegistrar(
        registry->GetRegistrarForPlugin("FlutterGpuTextureRendererPluginCApi"));
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
