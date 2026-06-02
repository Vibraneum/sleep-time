#include "flutter_window.h"

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "sleep_lock_state.h"

HHOOK FlutterWindow::keyboard_hook_ = nullptr;
HWINEVENTHOOK FlutterWindow::foreground_hook_ = nullptr;
HWND FlutterWindow::app_window_ = nullptr;

namespace {

// Safety-net re-read interval for lock.json. The latency-sensitive case
// (foreign window stealing focus) is handled by the SetWinEventHook below; this
// timer only catches missed events / external edits, so it can be slow.
constexpr UINT kLockStatePollMs = 5000;

// Whether lockdown is currently active per lock.json (cheap, fail-open).
bool IsLockActive() {
  return sleeplock::Read().locked;
}

// In grant mode, decide whether |hwnd| is an allowed foreground window we must
// NOT snap away from. In full mode (or when not in grant), nothing foreign is
// allowed. Our OWN window is always "allowed" so we never fight ourselves.
bool ShouldAllowForeground(HWND hwnd, HWND own_window) {
  if (hwnd == nullptr) {
    return false;
  }
  if (hwnd == own_window) {
    return true;
  }
  const sleeplock::LockState state = sleeplock::Read();
  if (!state.locked) {
    return true;  // not locked: never reclaim
  }
  if (!state.mode_grant) {
    return false;  // full lock: everything foreign is disallowed
  }
  // Grant mode: resolve the owning process image. If we cannot resolve it (e.g.
  // a protected / elevated process) we fail SAFE and reclaim.
  const std::wstring image = sleeplock::ProcessImageForWindow(hwnd);
  if (image.empty()) {
    return false;
  }
  return sleeplock::IsAllowed(image, state.allow);
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
  // Demoted from the old 250ms hot loop to a 5s safety-net poll; the
  // SetWinEventHook handles instant focus reclaim.
  SetTimer(app_window_, lock_state_timer_id_, kLockStatePollMs, nullptr);
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
  RemoveForegroundHook();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  app_window_ = nullptr;
  Win32Window::OnDestroy();
}

void FlutterWindow::UpdateLockState() {
  const bool should_lock = IsLockActive();
  if (should_lock == native_lock_active_) {
    return;
  }

  native_lock_active_ = should_lock;
  if (native_lock_active_) {
    InstallKeyboardHook();
    InstallForegroundHook();
    RefocusAppWindow();
  } else {
    RemoveKeyboardHook();
    RemoveForegroundHook();
  }
}

// Reclaim foreground to our own window. This is the highest-risk detail: a
// background thread / process cannot freely steal foreground on modern Windows
// unless we attach our input queue to the current foreground thread first.
//
// Sequence (all best-effort, all no-throw):
//   1. Find the current foreground window's thread.
//   2. AttachThreadInput(foreground -> us, TRUE) so SetForegroundWindow is
//      honored.
//   3. ShowWindow + SetForegroundWindow + SetWindowPos(HWND_TOPMOST).
//   4. Detach.
// We cannot beat a HIGHER integrity (elevated) foreground window — that case is
// documented as defeatable in windows_lockdown.dart.
void FlutterWindow::RefocusAppWindow() noexcept {
  if (app_window_ == nullptr) {
    return;
  }
  const HWND foreground = GetForegroundWindow();
  const DWORD our_thread = GetCurrentThreadId();
  DWORD foreground_thread = 0;
  bool attached = false;
  if (foreground != nullptr && foreground != app_window_) {
    foreground_thread = GetWindowThreadProcessId(foreground, nullptr);
    if (foreground_thread != 0 && foreground_thread != our_thread) {
      attached = AttachThreadInput(foreground_thread, our_thread, TRUE) != FALSE;
    }
  }

  ShowWindow(app_window_, SW_SHOW);
  SetForegroundWindow(app_window_);
  SetFocus(app_window_);
  // Pin above other top-most windows without resizing/moving.
  SetWindowPos(app_window_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

  if (attached) {
    AttachThreadInput(foreground_thread, our_thread, FALSE);
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

void FlutterWindow::InstallForegroundHook() {
  if (foreground_hook_ != nullptr) {
    return;
  }
  // Out-of-context + skip-own-process: we are only notified when a window from
  // ANOTHER process becomes foreground, which is exactly when we may need to
  // reclaim. WINEVENT_OUTOFCONTEXT means the callback runs on our thread via
  // the message loop (no DLL injection).
  foreground_hook_ = SetWinEventHook(
      EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, WinEventProc, 0,
      0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
}

void FlutterWindow::RemoveForegroundHook() {
  if (foreground_hook_ != nullptr) {
    UnhookWinEvent(foreground_hook_);
    foreground_hook_ = nullptr;
  }
}

void CALLBACK FlutterWindow::WinEventProc(HWINEVENTHOOK /*hook*/, DWORD event,
                                          HWND hwnd, LONG /*id_object*/,
                                          LONG /*id_child*/,
                                          DWORD /*event_thread*/,
                                          DWORD /*event_time*/) noexcept {
  if (event != EVENT_SYSTEM_FOREGROUND) {
    return;
  }
  // Only act while locked, and only when the new foreground is not allowed.
  if (!IsLockActive()) {
    return;
  }
  if (ShouldAllowForeground(hwnd, app_window_)) {
    return;  // grant mode: let an allowed app stay foreground.
  }
  RefocusAppWindow();
}

LRESULT CALLBACK FlutterWindow::KeyboardProc(int nCode, WPARAM wparam,
                                             LPARAM lparam) noexcept {
  if (nCode >= 0 && IsLockActive() &&
      (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN ||
       wparam == WM_KEYUP || wparam == WM_SYSKEYUP)) {
    const auto* key = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
    if (IsBlockedKey(key)) {
      // In grant mode, if an allowed app currently holds the foreground, do not
      // yank it away on a blocked-key event — just swallow the key.
      if (!ShouldAllowForeground(GetForegroundWindow(), app_window_)) {
        RefocusAppWindow();
      }
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
