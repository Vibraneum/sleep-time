// Shared, header-only, dependency-free reader for the Sleep Time lock-state
// IPC file (`%LOCALAPPDATA%\SleepTime\state\lock.json`). Used by BOTH the
// Flutter runner and the sibling watchdog exe so they agree on the schema.
//
// NO JSON library by design: the file is tiny and written only by our Dart
// side (see lib/platform/windows_lock_state.dart). We scan for the few known
// fields by hand and stay robust to absence / partial writes (fail-open: if we
// can't read it, we report "not locked").
//
// Must compile warning-clean under MSVC /W4 /WX.
#ifndef RUNNER_SLEEP_LOCK_STATE_H_
#define RUNNER_SLEEP_LOCK_STATE_H_

#include <shlobj.h>
#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

namespace sleeplock {

// Parsed view of lock.json. `mode_grant` is true only when the file explicitly
// says "mode":"grant".
struct LockState {
  bool locked = false;
  bool mode_grant = false;
  std::int64_t grant_expiry_epoch_ms = 0;
  std::vector<std::wstring> allow;  // lower-cased image basenames
};

// Resolve `%LOCALAPPDATA%\SleepTime\state\lock.json`. Returns empty string on
// failure.
inline std::wstring LockStatePath() {
  wchar_t buffer[MAX_PATH];
  buffer[0] = L'\0';
  // Prefer the environment variable (cheap, honors redirection); fall back to
  // SHGetFolderPathW.
  DWORD len = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  std::wstring base;
  if (len > 0 && len < MAX_PATH) {
    base.assign(buffer, len);
  } else if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr,
                                        SHGFP_TYPE_CURRENT, buffer))) {
    base.assign(buffer);
  } else {
    return std::wstring();
  }
  return base + L"\\SleepTime\\state\\lock.json";
}

// Read the whole (tiny) file as a narrow string. Returns false if it does not
// exist or cannot be read.
inline bool ReadFileText(const std::wstring& path, std::string* out) {
  if (!out) {
    return false;
  }
  HANDLE handle =
      CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    return false;
  }
  out->clear();
  char buffer[1024];
  DWORD read = 0;
  bool ok = true;
  for (;;) {
    if (!ReadFile(handle, buffer, sizeof(buffer), &read, nullptr)) {
      ok = false;
      break;
    }
    if (read == 0) {
      break;
    }
    out->append(buffer, read);
    if (out->size() > 64 * 1024) {  // sanity cap on a file we control
      break;
    }
  }
  CloseHandle(handle);
  return ok;
}

inline wchar_t ToLowerW(wchar_t c) {
  if (c >= L'A' && c <= L'Z') {
    return static_cast<wchar_t>(c - L'A' + L'a');
  }
  return c;
}

// Convert a UTF-8/ASCII narrow string (we only emit ASCII image names) to a
// lower-cased wide string. Non-ASCII bytes are passed through as-is.
inline std::wstring NarrowToLowerWide(const std::string& s) {
  std::wstring result;
  result.reserve(s.size());
  for (char ch : s) {
    result.push_back(ToLowerW(static_cast<wchar_t>(static_cast<unsigned char>(ch))));
  }
  return result;
}

// Find the value of a `"key":` boolean. Returns true if present and `true`.
inline bool FindBoolTrue(const std::string& text, const char* key) {
  std::string needle = std::string("\"") + key + "\"";
  size_t pos = text.find(needle);
  if (pos == std::string::npos) {
    return false;
  }
  pos += needle.size();
  // Skip whitespace and the colon.
  while (pos < text.size() && (text[pos] == ' ' || text[pos] == ':' ||
                               text[pos] == '\t')) {
    ++pos;
  }
  return text.compare(pos, 4, "true") == 0;
}

// Find the string value of `"key":"value"`. Returns empty on absence.
inline std::string FindStringValue(const std::string& text, const char* key) {
  std::string needle = std::string("\"") + key + "\"";
  size_t pos = text.find(needle);
  if (pos == std::string::npos) {
    return std::string();
  }
  pos += needle.size();
  while (pos < text.size() && (text[pos] == ' ' || text[pos] == ':' ||
                               text[pos] == '\t')) {
    ++pos;
  }
  if (pos >= text.size() || text[pos] != '"') {
    return std::string();
  }
  ++pos;  // opening quote
  size_t end = text.find('"', pos);
  if (end == std::string::npos) {
    return std::string();
  }
  return text.substr(pos, end - pos);
}

// Find the integer value of `"key": <number>`. Returns 0 on absence.
inline std::int64_t FindIntValue(const std::string& text, const char* key) {
  std::string needle = std::string("\"") + key + "\"";
  size_t pos = text.find(needle);
  if (pos == std::string::npos) {
    return 0;
  }
  pos += needle.size();
  while (pos < text.size() && (text[pos] == ' ' || text[pos] == ':' ||
                               text[pos] == '\t')) {
    ++pos;
  }
  bool negative = false;
  if (pos < text.size() && text[pos] == '-') {
    negative = true;
    ++pos;
  }
  std::int64_t value = 0;
  bool any = false;
  while (pos < text.size() && text[pos] >= '0' && text[pos] <= '9') {
    value = value * 10 + (text[pos] - '0');
    any = true;
    ++pos;
  }
  if (!any) {
    return 0;
  }
  return negative ? -value : value;
}

// Parse the `"allow":[ "a.exe", "b.exe" ]` array into lower-cased wide
// basenames. Tolerant of whitespace; stops at the closing bracket.
inline std::vector<std::wstring> FindAllowList(const std::string& text) {
  std::vector<std::wstring> out;
  std::string needle = "\"allow\"";
  size_t pos = text.find(needle);
  if (pos == std::string::npos) {
    return out;
  }
  pos += needle.size();
  size_t open = text.find('[', pos);
  if (open == std::string::npos) {
    return out;
  }
  size_t close = text.find(']', open);
  if (close == std::string::npos) {
    close = text.size();
  }
  size_t cursor = open + 1;
  while (cursor < close) {
    size_t quote = text.find('"', cursor);
    if (quote == std::string::npos || quote >= close) {
      break;
    }
    size_t end = text.find('"', quote + 1);
    if (end == std::string::npos || end > close) {
      break;
    }
    std::string item = text.substr(quote + 1, end - quote - 1);
    if (!item.empty()) {
      out.push_back(NarrowToLowerWide(item));
    }
    cursor = end + 1;
  }
  return out;
}

// Read and parse the current lock state. On any failure, returns a default
// (unlocked) LockState — fail-open.
inline LockState Read() {
  LockState state;
  std::wstring path = LockStatePath();
  if (path.empty()) {
    return state;
  }
  std::string text;
  if (!ReadFileText(path, &text)) {
    return state;
  }
  state.locked = FindBoolTrue(text, "locked");
  state.mode_grant = FindStringValue(text, "mode") == "grant";
  state.grant_expiry_epoch_ms = FindIntValue(text, "grantExpiryEpochMs");
  state.allow = FindAllowList(text);
  return state;
}

// Lower-cased basename of a full path or bare name.
inline std::wstring BaseNameLower(const std::wstring& path) {
  size_t slash = path.find_last_of(L"\\/");
  std::wstring name =
      (slash == std::wstring::npos) ? path : path.substr(slash + 1);
  std::wstring lower;
  lower.reserve(name.size());
  for (wchar_t c : name) {
    lower.push_back(ToLowerW(c));
  }
  return lower;
}

// Case-insensitive basename membership test against an allow-list of
// already-lower-cased basenames.
inline bool IsAllowed(const std::wstring& image_path,
                      const std::vector<std::wstring>& allow) {
  std::wstring target = BaseNameLower(image_path);
  if (target.empty()) {
    return false;
  }
  for (const std::wstring& entry : allow) {
    if (BaseNameLower(entry) == target) {
      return true;
    }
  }
  return false;
}

// Resolve the image path of the process owning |hwnd|. Returns empty on
// failure (e.g. a protected/elevated process we cannot query).
inline std::wstring ProcessImageForWindow(HWND hwnd) {
  if (hwnd == nullptr) {
    return std::wstring();
  }
  DWORD process_id = 0;
  GetWindowThreadProcessId(hwnd, &process_id);
  if (process_id == 0) {
    return std::wstring();
  }
  HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return std::wstring();
  }
  wchar_t buffer[MAX_PATH];
  DWORD size = MAX_PATH;
  std::wstring result;
  if (QueryFullProcessImageNameW(process, 0, buffer, &size)) {
    result.assign(buffer, size);
  }
  CloseHandle(process);
  return result;
}

}  // namespace sleeplock

#endif  // RUNNER_SLEEP_LOCK_STATE_H_
