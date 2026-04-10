#include "flutter_window.h"

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

HHOOK FlutterWindow::keyboard_hook_ = nullptr;
HWND FlutterWindow::app_window_ = nullptr;

namespace {
constexpr wchar_t kLockFlagFilename[] = L"sleep_time.locked";

bool HasLockFlag() {
  wchar_t temp_path[MAX_PATH];
  DWORD path_length = GetTempPathW(MAX_PATH, temp_path);
  if (path_length == 0 || path_length > MAX_PATH) {
    return false;
  }

  std::wstring full_path(temp_path);
  full_path += kLockFlagFilename;
  DWORD attributes = GetFileAttributesW(full_path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

bool IsBlockedKey(const KBDLLHOOKSTRUCT* key) {
  if (!key) {
    return false;
  }

  const bool alt_down = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
  const bool ctrl_down = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
  const bool shift_down = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;

  switch (key->vkCode) {
    case VK_LWIN:
    case VK_RWIN:
    case VK_APPS:
      return true;
    case VK_TAB:
      return alt_down;
    case VK_ESCAPE:
      return alt_down || ctrl_down || (ctrl_down && shift_down);
    case VK_F4:
      return alt_down;
    case VK_SPACE:
      return alt_down;
    default:
      return false;
  }
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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  app_window_ = GetHandle();
  SetTimer(app_window_, lock_state_timer_id_, 250, nullptr);
  UpdateLockState();

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (app_window_ != nullptr) {
    KillTimer(app_window_, lock_state_timer_id_);
  }
  RemoveKeyboardHook();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  app_window_ = nullptr;
  Win32Window::OnDestroy();
}

void FlutterWindow::UpdateLockState() {
  const bool should_lock = IsLockFlagPresent();
  if (should_lock == native_lock_active_) {
    return;
  }

  native_lock_active_ = should_lock;
  if (native_lock_active_) {
    InstallKeyboardHook();
    RefocusAppWindow();
  } else {
    RemoveKeyboardHook();
  }
}

bool FlutterWindow::IsLockFlagPresent() const {
  return HasLockFlag();
}

void FlutterWindow::RefocusAppWindow() noexcept {
  if (app_window_ != nullptr) {
    ShowWindow(app_window_, SW_SHOW);
    SetForegroundWindow(app_window_);
    SetFocus(app_window_);
  }
}

void FlutterWindow::InstallKeyboardHook() {
  if (keyboard_hook_ != nullptr) {
    return;
  }
  keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardProc,
                                     GetModuleHandle(nullptr), 0);
}

void FlutterWindow::RemoveKeyboardHook() {
  if (keyboard_hook_ != nullptr) {
    UnhookWindowsHookEx(keyboard_hook_);
    keyboard_hook_ = nullptr;
  }
}

LRESULT CALLBACK FlutterWindow::KeyboardProc(int nCode, WPARAM wparam,
                                             LPARAM lparam) noexcept {
  if (nCode >= 0 && HasLockFlag() &&
      (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN ||
       wparam == WM_KEYUP || wparam == WM_SYSKEYUP)) {
    const auto* key = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
    if (IsBlockedKey(key)) {
      RefocusAppWindow();
      return 1;
    }
  }

  return CallNextHookEx(keyboard_hook_, nCode, wparam, lparam);
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (native_lock_active_) {
    if (message == WM_CLOSE) {
      RefocusAppWindow();
      return 0;
    }
    if (message == WM_SYSCOMMAND) {
      const auto command = static_cast<UINT>(wparam & 0xFFF0);
      if (command == SC_CLOSE || command == SC_TASKLIST ||
          command == SC_MINIMIZE) {
        RefocusAppWindow();
        return 0;
      }
    }
  }

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
    case WM_TIMER:
      if (wparam == lock_state_timer_id_) {
        UpdateLockState();
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
