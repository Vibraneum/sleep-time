import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A single selectively-allowed app with an expiry. Pure data — no platform
/// calls. The native enforcement layer (later milestone) reads these to decide
/// what to let through during lockdown.
class AllowlistEntry {
  final String identifier;
  final String label;
  final DateTime expiresAt;

  const AllowlistEntry({
    required this.identifier,
    required this.label,
    required this.expiresAt,
  });

  bool get isActive => DateTime.now().isBefore(expiresAt);

  Map<String, dynamic> toMap() => {
        'identifier': identifier,
        'label': label,
        'expires_at': expiresAt.toIso8601String(),
      };

  factory AllowlistEntry.fromMap(Map<String, dynamic> map) => AllowlistEntry(
        identifier: map['identifier'] as String? ?? '',
        label: map['label'] as String? ?? '',
        expiresAt: DateTime.parse(map['expires_at'] as String),
      );
}

/// SharedPreferences-backed selective-unlock allowlist. Pure data layer; the
/// platform lockdown code consumes [activeEntries] / [isAllowed] separately.
class AppAllowlist {
  AppAllowlist();

  static const String _prefsKey = 'app_allowlist';

  final List<AllowlistEntry> _entries = [];
  final StreamController<List<AllowlistEntry>> _controller =
      StreamController<List<AllowlistEntry>>.broadcast();

  /// Broadcast stream of the current entry list, emitted on every mutation.
  Stream<List<AllowlistEntry>> get changes => _controller.stream;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      _entries.clear();
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final item in list) {
          try {
            _entries.add(AllowlistEntry.fromMap(
                (item as Map).cast<String, dynamic>()));
          } catch (_) {}
        }
      }
    } catch (_) {}
    _emit();
  }

  List<AllowlistEntry> activeEntries() =>
      _entries.where((e) => e.isActive).toList(growable: false);

  bool isAllowed(String identifier) =>
      _entries.any((e) => e.identifier == identifier && e.isActive);

  Future<void> add(AllowlistEntry entry) async {
    _entries.removeWhere((e) => e.identifier == entry.identifier);
    _entries.add(entry);
    await _save();
    _emit();
  }

  Future<void> purgeExpired() async {
    final before = _entries.length;
    _entries.removeWhere((e) => !e.isActive);
    if (_entries.length != before) {
      await _save();
      _emit();
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_entries.map((e) => e.toMap()).toList());
      await prefs.setString(_prefsKey, raw);
    } catch (_) {}
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(activeEntries());
    }
  }

  void dispose() {
    _controller.close();
  }
}
