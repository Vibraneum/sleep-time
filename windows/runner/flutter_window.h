#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void UpdateLockState();
  bool IsLockFlagPresent() const;
  void InstallKeyboardHook();
  void RemoveKeyboardHook();
  static void RefocusAppWindow() noexcept;
  static LRESULT CALLBACK KeyboardProc(int nCode, WPARAM wparam,
                                       LPARAM lparam) noexcept;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  bool native_lock_active_ = false;
  UINT_PTR lock_state_timer_id_ = 1;

  static HHOOK keyboard_hook_;
  static HWND app_window_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
