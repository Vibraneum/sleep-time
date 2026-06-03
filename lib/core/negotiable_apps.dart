import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single app the user has approved the guardian to be ABLE to unlock during
/// lockdown (the opt-in negotiable set). This is distinct from the active
/// allow-list ([AppAllowlist]): being on this list does not unlock anything; it
/// only authorizes the `unlock_app` tool to free it for a timed window.
@immutable
class NegotiableApp {
  final String package;
  final String label;

  const NegotiableApp({required this.package, required this.label});

  Map<String, dynamic> toMap() => {'package': package, 'label': label};

  factory NegotiableApp.fromMap(Map<String, dynamic> map) => NegotiableApp(
        package: (map['package'] as String?) ?? '',
        label: (map['label'] as String?) ?? (map['package'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is NegotiableApp &&
      other.package == package &&
      other.label == label;

  @override
  int get hashCode => Object.hash(package, label);
}

/// SharedPreferences-backed, user-approved set of apps the guardian may unlock.
/// Pure data layer; the platform unlock path consults [isApproved] / [resolve]
/// to constrain `unlock_app` to this set.
class NegotiableAppStore {
  NegotiableAppStore._();

  /// Process-wide singleton so the editor screen and the unlock path share one
  /// in-memory view.
  static final NegotiableAppStore instance = NegotiableAppStore._();

  static const String prefsKey = 'negotiable_apps';

  final List<NegotiableApp> _apps = [];
  final StreamController<List<NegotiableApp>> _controller =
      StreamController<List<NegotiableApp>>.broadcast();

  Stream<List<NegotiableApp>> get changes => _controller.stream;

  List<NegotiableApp> get apps => List.unmodifiable(_apps);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      _apps.clear();
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final item in list) {
          try {
            _apps.add(
                NegotiableApp.fromMap((item as Map).cast<String, dynamic>()));
          } catch (_) {}
        }
      }
    } catch (_) {}
    _emit();
  }

  bool isApproved(String package) =>
      _apps.any((a) => a.package == package);

  /// Resolve a guardian-supplied [identifier] (a package or a friendly label)
  /// to an approved app, or null if it is not on the approved list. Matching is
  /// case-insensitive on the label and exact on the package.
  NegotiableApp? resolve(String identifier) {
    final id = identifier.trim();
    if (id.isEmpty) return null;
    for (final a in _apps) {
      if (a.package == id) return a;
    }
    final lower = id.toLowerCase();
    for (final a in _apps) {
      if (a.label.toLowerCase() == lower) return a;
    }
    // Loose contains match as a last resort (e.g. "youtube" → "YouTube"). This
    // gates a privileged unlock, so an AMBIGUOUS match (e.g. "youtube" matching
    // both "YouTube" and "YouTube Music") must resolve to null rather than
    // silently picking whichever happens to be first.
    final matches = _apps
        .where((a) =>
            a.label.toLowerCase().contains(lower) ||
            a.package.toLowerCase().contains(lower))
        .toList(growable: false);
    if (matches.length == 1) return matches.single;
    return null;
  }

  Future<void> add(NegotiableApp app) async {
    if (app.package.isEmpty) return;
    _apps.removeWhere((a) => a.package == app.package);
    _apps.add(app);
    await _save();
    _emit();
  }

  Future<void> remove(String package) async {
    final before = _apps.length;
    _apps.removeWhere((a) => a.package == package);
    if (_apps.length != before) {
      await _save();
      _emit();
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_apps.map((a) => a.toMap()).toList());
      await prefs.setString(prefsKey, raw);
    } catch (_) {}
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(apps);
    }
  }

  @visibleForTesting
  void resetForTest() {
    _apps.clear();
  }
}
