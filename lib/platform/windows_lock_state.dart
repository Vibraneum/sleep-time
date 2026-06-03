import 'dart:convert';

/// Pure (no-I/O) model + (de)serializer for the Windows lock-state IPC file
/// (`%LOCALAPPDATA%\SleepTime\state\lock.json`).
///
/// Extracted from [WindowsLockdown] so the JSON round-trip and the allow-list /
/// friendly-name resolution logic can be unit-tested on any host (the C++ side
/// has a hand-rolled parser that must agree with this schema — keep them in
/// sync).
///
/// Schema:
/// ```json
/// { "locked": true, "mode": "full"|"grant",
///   "allow": ["chrome.exe", ...], "grantExpiryEpochMs": 0 }
/// ```
class WindowsLockState {
  const WindowsLockState({
    required this.locked,
    this.mode = 'full',
    this.allow = const [],
    this.grantExpiryEpochMs = 0,
  });

  final bool locked;

  /// `"full"` = whole-screen overlay; `"grant"` = selective allow-list mode.
  final String mode;

  /// Process image names (e.g. `chrome.exe`) the overlay must NOT snap away
  /// from while in grant mode. Always lower-cased basenames.
  final List<String> allow;

  /// Absolute epoch-ms after which a grant expires (0 when not in grant mode).
  final int grantExpiryEpochMs;

  Map<String, dynamic> toJson() => {
        'locked': locked,
        'mode': mode,
        'allow': allow,
        'grantExpiryEpochMs': grantExpiryEpochMs,
      };

  String encode() => jsonEncode(toJson());

  static WindowsLockState decode(String source) {
    final raw = jsonDecode(source);
    if (raw is! Map) {
      throw const FormatException('lock.json is not a JSON object');
    }
    final allowRaw = raw['allow'];
    final allow = <String>[];
    if (allowRaw is List) {
      for (final entry in allowRaw) {
        if (entry is String && entry.trim().isNotEmpty) {
          allow.add(entry.toString());
        }
      }
    }
    return WindowsLockState(
      // Clamp to the IPC-supported values only: a corrupt/stale lock.json must
      // not push an unsupported mode through to the C++ side.
      locked: raw['locked'] == true,
      mode: raw['mode'] == 'grant' ? 'grant' : 'full',
      allow: allow,
      grantExpiryEpochMs:
          raw['grantExpiryEpochMs'] is num ? (raw['grantExpiryEpochMs'] as num).toInt() : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowsLockState &&
      other.locked == locked &&
      other.mode == mode &&
      other.grantExpiryEpochMs == grantExpiryEpochMs &&
      _listEquals(other.allow, allow);

  @override
  int get hashCode => Object.hash(locked, mode, grantExpiryEpochMs, Object.hashAll(allow));

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Friendly-name → Windows image-name resolution used so the guardian can say
/// "chrome" and we resolve it to the process image name the C++ allow-list
/// matches against. Small and extensible by design.
class WindowsAppResolver {
  WindowsAppResolver._();

  /// Friendly aliases → canonical image name. Keys are lower-cased; lookups are
  /// case-insensitive. If a value isn't found, the input is normalised to an
  /// `.exe` basename directly (so the guardian can also pass a raw image name).
  static const Map<String, String> _friendlyToImage = {
    'chrome': 'chrome.exe',
    'google chrome': 'chrome.exe',
    'edge': 'msedge.exe',
    'microsoft edge': 'msedge.exe',
    'firefox': 'firefox.exe',
    'brave': 'brave.exe',
    'vscode': 'Code.exe',
    'vs code': 'Code.exe',
    'visual studio code': 'Code.exe',
    'code': 'Code.exe',
    'spotify': 'Spotify.exe',
    'slack': 'slack.exe',
    'discord': 'Discord.exe',
    'notion': 'Notion.exe',
    'obsidian': 'Obsidian.exe',
    'zoom': 'Zoom.exe',
    'teams': 'ms-teams.exe',
    'terminal': 'WindowsTerminal.exe',
    'explorer': 'explorer.exe',
    'word': 'WINWORD.EXE',
    'excel': 'EXCEL.EXE',
  };

  /// Resolve a single friendly name to an image name. Returns null when the
  /// input is blank.
  static String? resolve(String identifier) {
    final trimmed = identifier.trim();
    if (trimmed.isEmpty) return null;
    final mapped = _friendlyToImage[trimmed.toLowerCase()];
    if (mapped != null) return mapped;
    // Already an image name? Keep it, ensuring a single `.exe` suffix.
    if (trimmed.toLowerCase().endsWith('.exe')) return trimmed;
    return '$trimmed.exe';
  }

  /// Resolve a comma/space-separated list of friendly names into image names,
  /// dropping blanks and duplicates (case-insensitive on the resolved name).
  static List<String> resolveAll(Iterable<String> identifiers) {
    final out = <String>[];
    final seen = <String>{};
    for (final id in identifiers) {
      final resolved = resolve(id);
      if (resolved == null) continue;
      final key = resolved.toLowerCase();
      if (seen.add(key)) out.add(resolved);
    }
    return out;
  }

  /// Case-insensitive basename match used to mirror the C++ allow-list check in
  /// Dart tests. [allow] entries and [imageName] may be full paths or bare
  /// names; only the basename is compared.
  static bool isAllowed(String imageName, List<String> allow) {
    final target = _basename(imageName).toLowerCase();
    if (target.isEmpty) return false;
    for (final entry in allow) {
      if (_basename(entry).toLowerCase() == target) return true;
    }
    return false;
  }

  static String _basename(String path) {
    var p = path.trim();
    final slash = p.lastIndexOf('\\');
    final fwd = p.lastIndexOf('/');
    final cut = slash > fwd ? slash : fwd;
    if (cut >= 0) p = p.substring(cut + 1);
    return p;
  }
}
