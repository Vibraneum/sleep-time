import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'memory_service.dart';
import 'schedule.dart';

/// Who initiated a schedule change. Used for audit + deciding whether the
/// human baseline should move with the change.
enum ScheduleSource { userSettings, aiTonight, aiPermanent, system }

/// Outcome of an [ScheduleStore.apply] call.
enum ScheduleOutcome { granted, rejected }

/// Result of attempting to apply a schedule change.
class ScheduleChangeResult {
  final ScheduleOutcome outcome;
  final SleepSchedule applied;
  final List<String> reasons;

  const ScheduleChangeResult({
    required this.outcome,
    required this.applied,
    required this.reasons,
  });

  bool get granted => outcome == ScheduleOutcome.granted;
}

/// Single source of truth for the live schedule. The rest of the app reads
/// [current] (directly or through `AppConfig`'s getters) and listens for
/// changes. All writes funnel through [apply] so persistence, validation, and
/// the audit log stay consistent.
class ScheduleStore extends ChangeNotifier {
  ScheduleStore._();

  static ScheduleStore? _instance;
  static ScheduleStore get instance => _instance ??= ScheduleStore._();

  /// Pref keys — intentionally the SAME keys already written by main's
  /// `_loadConfig` and the settings screen, so nothing else has to migrate.
  static const _wakeUpHourKey = 'wakeup_hour';
  static const _wakeUpMinuteKey = 'wakeup_minute';
  static const _windDownHourKey = 'winddown_hour';
  static const _windDownMinuteKey = 'winddown_minute';
  static const _lockdownHourKey = 'lockdown_hour';
  static const _lockdownMinuteKey = 'lockdown_minute';
  static const _unlockHourKey = 'unlock_hour';
  static const _unlockMinuteKey = 'unlock_minute';

  SleepSchedule _current = SleepSchedule.defaults;
  SleepSchedule _baseline = SleepSchedule.defaults;

  /// Fields changed by an `aiTonight` apply this night, so [revertTonightNudges]
  /// knows exactly which fields to roll back to baseline. Cleared on revert and
  /// on any userSettings/aiPermanent apply (those move the baseline).
  final Set<String> _tonightNudgedFields = {};

  /// The source of the most recent apply (any source). Used by the home banner
  /// to decide whether the guardian touched the schedule.
  ScheduleSource? _lastChangeSource;

  /// A short human note about the most recent change, for the UI banner/chip.
  String? _lastChangeNote;

  /// The live schedule. Safe to read before [loadFromPrefs] (returns defaults).
  SleepSchedule get current => _current;

  /// The human-set schedule. AI "tonight" nudges revert to this on the nightly
  /// reset (see [revertTonightNudges]).
  SleepSchedule get baseline => _baseline;

  /// Source of the most recent apply, or null if none has happened.
  ScheduleSource? get lastChangeSource => _lastChangeSource;

  /// Short human note about the most recent change, or null.
  String? get lastChangeNote => _lastChangeNote;

  /// Fields the AI has nudged for tonight (read-only view, for tests/UI).
  Set<String> get tonightNudgedFields => Set.unmodifiable(_tonightNudgedFields);

  /// Clear the banner notice (e.g. when the user dismisses the home banner).
  void clearLastChangeNotice() {
    _lastChangeSource = null;
    _lastChangeNote = null;
    notifyListeners();
  }

  /// Load the schedule from SharedPreferences using the existing pref keys.
  /// Populates both [current] and [baseline].
  Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loaded = _readSchedule(prefs);
      _current = loaded;
      _baseline = loaded;
      notifyListeners();
    } catch (_) {
      // Keep defaults on any failure — reads must never crash.
    }
  }

  SleepSchedule _readSchedule(SharedPreferences prefs) {
    final d = SleepSchedule.defaults;
    return SleepSchedule(
      wakeUp: ScheduleTime(
        prefs.getInt(_wakeUpHourKey) ?? d.wakeUp.hour,
        prefs.getInt(_wakeUpMinuteKey) ?? d.wakeUp.minute,
      ),
      windDown: ScheduleTime(
        prefs.getInt(_windDownHourKey) ?? d.windDown.hour,
        prefs.getInt(_windDownMinuteKey) ?? d.windDown.minute,
      ),
      lockdown: ScheduleTime(
        prefs.getInt(_lockdownHourKey) ?? d.lockdown.hour,
        prefs.getInt(_lockdownMinuteKey) ?? d.lockdown.minute,
      ),
      unlock: ScheduleTime(
        prefs.getInt(_unlockHourKey) ?? d.unlock.hour,
        prefs.getInt(_unlockMinuteKey) ?? d.unlock.minute,
      ),
    );
  }

  /// The single write path for schedule changes.
  ///
  /// Validates [next]; if invalid, returns a rejected result WITHOUT mutating
  /// any state. If valid, persists all eight pref keys, updates [current]
  /// (and [baseline] for human/permanent sources), notifies listeners, and
  /// writes an audit row. Persistence failures are swallowed so the in-memory
  /// state and listeners still update.
  ScheduleChangeResult apply(
    SleepSchedule next, {
    required ScheduleSource source,
    String? reason,
  }) {
    final validation = next.validate();
    if (!validation.ok) {
      return ScheduleChangeResult(
        outcome: ScheduleOutcome.rejected,
        applied: _current,
        reasons: validation.violations,
      );
    }

    final previous = _current;
    _current = next;
    if (source == ScheduleSource.userSettings ||
        source == ScheduleSource.aiPermanent) {
      // These move the baseline, so there is nothing to revert later.
      _baseline = next;
      _tonightNudgedFields.clear();
    } else if (source == ScheduleSource.aiTonight) {
      // Track exactly which fields drifted from baseline so the nightly reset
      // can roll back only those.
      _recordTonightDrift(next);
    }

    _lastChangeSource = source;
    _lastChangeNote = reason;

    // Persist (fire-and-forget; swallow failures).
    _persist(next);

    // Audit (fire-and-forget; swallow failures inside the service).
    MemoryService.logScheduleChange(
      source: source.name,
      oldValue: previous.toMap().toString(),
      newValue: next.toMap().toString(),
      reason: reason,
      outcome: ScheduleOutcome.granted.name,
    );

    notifyListeners();

    return ScheduleChangeResult(
      outcome: ScheduleOutcome.granted,
      applied: next,
      reasons: const [],
    );
  }

  /// Record which fields of [next] differ from the current baseline so a later
  /// [revertTonightNudges] restores exactly those.
  void _recordTonightDrift(SleepSchedule next) {
    if (next.wakeUp != _baseline.wakeUp) _tonightNudgedFields.add('wakeUp');
    if (next.windDown != _baseline.windDown) {
      _tonightNudgedFields.add('windDown');
    }
    if (next.lockdown != _baseline.lockdown) {
      _tonightNudgedFields.add('lockdown');
    }
    if (next.unlock != _baseline.unlock) _tonightNudgedFields.add('unlock');
  }

  /// Roll back any `aiTonight` nudges to the baseline, leaving aiPermanent /
  /// userSettings changes intact (those already moved the baseline). No-op when
  /// nothing was nudged. Persists, audits, and notifies on a real change.
  /// Called by the scheduler on the nightly reset.
  void revertTonightNudges() {
    if (_tonightNudgedFields.isEmpty) return;

    final previous = _current;
    var reverted = _current;
    for (final field in _tonightNudgedFields) {
      switch (field) {
        case 'wakeUp':
          reverted = reverted.copyWith(wakeUp: _baseline.wakeUp);
        case 'windDown':
          reverted = reverted.copyWith(windDown: _baseline.windDown);
        case 'lockdown':
          reverted = reverted.copyWith(lockdown: _baseline.lockdown);
        case 'unlock':
          reverted = reverted.copyWith(unlock: _baseline.unlock);
      }
    }
    _tonightNudgedFields.clear();

    if (reverted == previous) return;

    _current = reverted;
    _lastChangeSource = ScheduleSource.system;
    _lastChangeNote = 'reverted tonight\'s nudges to baseline';
    _persist(reverted);
    MemoryService.logScheduleChange(
      source: ScheduleSource.system.name,
      oldValue: previous.toMap().toString(),
      newValue: reverted.toMap().toString(),
      reason: 'nightly revert of tonight nudges',
      outcome: ScheduleOutcome.granted.name,
    );
    notifyListeners();
  }

  Future<void> _persist(SleepSchedule s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_wakeUpHourKey, s.wakeUp.hour);
      await prefs.setInt(_wakeUpMinuteKey, s.wakeUp.minute);
      await prefs.setInt(_windDownHourKey, s.windDown.hour);
      await prefs.setInt(_windDownMinuteKey, s.windDown.minute);
      await prefs.setInt(_lockdownHourKey, s.lockdown.hour);
      await prefs.setInt(_lockdownMinuteKey, s.lockdown.minute);
      await prefs.setInt(_unlockHourKey, s.unlock.hour);
      await prefs.setInt(_unlockMinuteKey, s.unlock.minute);
    } catch (_) {}
  }

  /// Test-only reset so suites don't leak singleton state between cases.
  @visibleForTesting
  static void resetForTest() {
    _instance = null;
  }
}
