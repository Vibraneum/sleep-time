// Sleep Time watchdog — a tiny, no-window, no-Flutter Win32 exe that relaunches
// sleep_time.exe if it is killed while lock.json says we are locked.
//
// Contract:
//   argv[1] = main process PID (decimal)               [optional]
//   argv[2] = full path to sleep_time.exe              [optional]
// If argv is absent we resolve sleep_time.exe next to this watchdog exe and
// skip the "wait on the original PID" optimization (we only watch lock.json).
//
// Single-instance: a named mutex (Global\SleepTimeWatchdogPresent). A second
// instance exits immediately so the reciprocal Dart respawn never piles up.
//
// Anti-fork-bomb: never relaunch more than once per kMinRelaunchIntervalMs.
//
// Exit: cleanly when lock.json.locked flips false.
//
// Must compile warning-clean under MSVC /W4 /WX.

#include <windows.h>
#include <tlhelp32.h>

#include <cstdint>
#include <cstdlib>
#include <string>

#include "sleep_lock_state.h"

namespace {

constexpr wchar_t kMutexName[] = L"Global\\SleepTimeWatchdogPresent";
constexpr DWORD kPollIntervalMs = 1000;
constexpr DWORD kMinRelaunchIntervalMs = 5000;

// Resolve sleep_time.exe sitting next to this watchdog exe.
std::wstring SiblingAppPath() {
  wchar_t module_path[MAX_PATH];
  DWORD len = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return std::wstring();
  }
  std::wstring path(module_path, len);
  size_t slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return std::wstring();
  }
  return path.substr(0, slash + 1) + L"sleep_time.exe";
}

// Launch the app. Returns true if CreateProcess succeeded.
bool LaunchApp(const std::wstring& app_path) {
  if (app_path.empty()) {
    return false;
  }
  STARTUPINFOW si;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi;
  ZeroMemory(&pi, sizeof(pi));

  // CreateProcessW may modify the command-line buffer, so copy it.
  std::wstring command_line = L"\"" + app_path + L"\"";
  std::wstring mutable_cmd = command_line;

  BOOL ok = CreateProcessW(app_path.c_str(), mutable_cmd.data(), nullptr,
                           nullptr, FALSE, 0, nullptr, nullptr, &si, &pi);
  if (ok) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return true;
  }
  return false;
}

// Open a handle to the original main process so we can wait on its death
// directly (faster than polling). Returns nullptr if the PID is unknown/gone.
HANDLE OpenMainProcess(DWORD pid) {
  if (pid == 0) {
    return nullptr;
  }
  return OpenProcess(SYNCHRONIZE, FALSE, pid);
}

// Is any process named sleep_time.exe currently running? Used by the no-PID
// (login autostart) path where we have no handle to wait on.
bool IsAppRunning() {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return true;  // Can't tell — assume running so we don't spawn duplicates.
  }
  PROCESSENTRY32W entry;
  ZeroMemory(&entry, sizeof(entry));
  entry.dwSize = sizeof(entry);
  bool found = false;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (_wcsicmp(entry.szExeFile, L"sleep_time.exe") == 0) {
        found = true;
        break;
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return found;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE /*instance*/, HINSTANCE /*prev*/,
                    PWSTR /*cmd_line*/, int /*show*/) {
  // Single-instance guard.
  HANDLE mutex = CreateMutexW(nullptr, TRUE, kMutexName);
  if (mutex == nullptr) {
    return 1;
  }
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    // Another watchdog already owns it.
    CloseHandle(mutex);
    return 0;
  }

  // Parse argv (PID + path) if provided.
  DWORD main_pid = 0;
  std::wstring app_path;
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv != nullptr) {
    if (argc >= 2) {
      main_pid = static_cast<DWORD>(_wtoi(argv[1]));
    }
    if (argc >= 3) {
      app_path.assign(argv[2]);
    }
    LocalFree(argv);
  }
  if (app_path.empty()) {
    app_path = SiblingAppPath();
  }

  HANDLE main_process = OpenMainProcess(main_pid);
  ULONGLONG last_relaunch = 0;

  for (;;) {
    const sleeplock::LockState state = sleeplock::Read();
    if (!state.locked) {
      break;  // Lock released — stand down.
    }

    // Wait either for the tracked main process to die or for the poll timeout.
    DWORD wait_ms = kPollIntervalMs;
    bool main_dead = false;
    if (main_process != nullptr) {
      DWORD result = WaitForSingleObject(main_process, wait_ms);
      if (result == WAIT_OBJECT_0) {
        main_dead = true;
      }
    } else {
      Sleep(wait_ms);
    }

    // Re-check the lock after waking — it may have been released while we slept.
    const sleeplock::LockState fresh = sleeplock::Read();
    if (!fresh.locked) {
      break;
    }

    // Determine if the app is running. If we were tracking a handle and it
    // died, or we have no handle, probe by attempting a relaunch guarded by the
    // anti-fork-bomb interval. We rely on the app's own single-instance
    // behavior is NOT guaranteed, so we only relaunch when we KNOW it died
    // (tracked handle signaled) or when we have no handle and detect absence.
    bool need_relaunch = false;
    if (main_process != nullptr) {
      // Fast path: we hold a handle to the tracked PID and it signaled death.
      need_relaunch = main_dead;
    } else {
      // No tracked handle (login-autostart path, or we already lost the PID
      // after a prior relaunch): fall back to a process-name presence check.
      need_relaunch = !IsAppRunning();
    }

    if (need_relaunch) {
      const ULONGLONG now = GetTickCount64();
      if (now - last_relaunch >= kMinRelaunchIntervalMs) {
        if (LaunchApp(app_path)) {
          last_relaunch = now;
        }
        // Stop tracking the dead handle; we cannot know the new PID, so fall
        // back to lock.json + process-name polling for the rest of this lock.
        if (main_process != nullptr) {
          CloseHandle(main_process);
          main_process = nullptr;
        }
      } else {
        // Too soon — wait out the remaining interval before another attempt.
        const ULONGLONG remaining = kMinRelaunchIntervalMs - (now - last_relaunch);
        Sleep(static_cast<DWORD>(remaining));
      }
    }
  }

  if (main_process != nullptr) {
    CloseHandle(main_process);
  }
  ReleaseMutex(mutex);
  CloseHandle(mutex);
  return 0;
}
