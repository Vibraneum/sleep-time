import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'memory_service.dart';
import 'schedule_store.dart';

enum LockdownState {
  inactive,
  awake,
  windDown,
  locked,
  granted,
  unlocked,
}

class LockdownScheduler {
  LockdownState _state = LockdownState.unlocked;
  Timer? _ticker;
  Timer? _grantTimer;
  DateTime? _grantExpiry;

  /// When non-empty, the active grant is a *selective* per-app grant (M2): the
  /// overlay stays armed and only these image names are allowed through. Empty
  /// for a full grant. Persisted so a crash mid-selective-grant restores.
  List<String> _grantAllow = const [];
  int _grantsUsedTonight = 0;
  int _grantedMinutesTonight = 0;
  bool _windDownNotified = false;
  bool _lockdownNotified = false;
  bool _permanentlyUnlocked = false;
  String? _lastSleepLogDate;

  /// Manual "lock now" override (the home Test/Lock-now button). When true the
  /// scheduler reports `locked` regardless of the clock, so the real platform
  /// takeover engages on demand. Cleared by a full unlock (safe word /
  /// end_session), on the nightly reset, and AUTOMATICALLY at the scheduled
  /// morning unlock time (see [_manualLockReleaseAt]) so a manual lock can never
  /// trap the user past wake time.
  bool _manualLock = false;

  /// The instant a manual lock auto-releases — the next occurrence of the
  /// scheduled unlock time after the lock was engaged. Once `now` reaches this,
  /// [_computeState] clears [_manualLock] and falls through to the normal
  /// schedule (which returns unlocked in the morning). Cleared whenever
  /// [_manualLock] is cleared.
  DateTime? _manualLockReleaseAt;

  /// The lockdown-start instant captured when we FIRST entered `locked` this
  /// night. Used by [_logSleepIfNeeded] instead of a fresh
  /// `lockdownStartForDate` so a mid-night schedule edit (which would move the
  /// computed lockdown start) cannot double-log or skip a sleep_log row.
  /// Cleared on the nightly reset.
  DateTime? _activeLockdownStart;

  final void Function(LockdownState state) onStateChange;
  final void Function(Duration remaining)? onGrantTick;
  final void Function()? onGrantExpired;

  /// Called when a selective (per-app) grant starts. The host wires this to the
  /// platform layer (e.g. [WindowsLockdown.grantSelective]). [allow] is the
  /// resolved image-name allow-list; [minutes] is the sanitized duration.
  final void Function(List<String> allow, int minutes)? onSelectiveGrant;

  LockdownScheduler({
    required this.onStateChange,
    this.onGrantTick,
    this.onGrantExpired,
    this.onSelectiveGrant,
  });

  // Pref keys for persisting grant state across restarts so a crash
  // mid-grant restores the remaining time instead of instant re-lock.
  static const _grantExpiryKey = 'grant_expiry_ms';
  static const _grantsUsedKey = 'grants_used_tonight';
  static const _grantedMinutesKey = 'granted_minutes_tonight';
  static const _grantAllowKey = 'grant_allow_images';

  /// The lockdown-night (yyyy-MM-dd of the lockdown START) the persisted
  /// counters belong to. Used on restore to discard yesterday's counters so a
  /// relaunch the next day doesn't carry stale nightly caps into tonight.
  static const _grantNightKey = 'grant_night';

  /// The lockdown-night date string for [now] — the date of the lockdown START
  /// that [now] falls under. Pure so it can be unit-tested.
  @visibleForTesting
  static String nightKeyFor(DateTime now) =>
      AppConfig.lockdownStartForDate(now).toIso8601String().split('T')[0];

  LockdownState get state => _state;
  int get grantsUsedTonight => _grantsUsedTonight;
  DateTime? get grantExpiry => _grantExpiry;

  /// The active selective-grant allow-list (image names). Empty when the active
  /// grant is a full grant or there's no grant.
  List<String> get grantAllow => List.unmodifiable(_grantAllow);

  /// True when the active grant is a selective per-app grant (vs a full grant).
  bool get isSelectiveGrant => _grantExpiry != null && _grantAllow.isNotEmpty;

  /// Exposed for tests only: a selective grant must NEVER permanently unlock.
  @visibleForTesting
  bool get permanentlyUnlocked => _permanentlyUnlocked;

  Duration? get grantRemaining {
    if (_grantExpiry == null) return null;
    final remaining = _grantExpiry!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void start() {
    // React to live schedule edits (human or guardian) immediately so a change
    // takes effect without waiting for the next 15s tick. Registered before
    // restoration so a schedule change during restore is never missed.
    ScheduleStore.instance.addListener(_onScheduleChanged);
    // Gate the FIRST _updateState() and the periodic ticker on grant
    // restoration completing. Otherwise the deferred first update could emit
    // locked/unlocked before an in-flight grant restores (restart flicker /
    // wrong re-lock).
    restoreGrantState().then((_) {
      _updateState();
      _ticker =
          Timer.periodic(const Duration(seconds: 15), (_) => _updateState());
    });
  }

  void _onScheduleChanged() => _updateState();

  /// Lock the device right now, independent of the schedule (manual "lock now" /
  /// test affordance). Drives the real platform takeover via [onStateChange] →
  /// the host's platform sync. Cleared by [fullUnlock] or the nightly reset.
  void forceLock() {
    _manualLock = true;
    // A manual lock must still release at the scheduled morning unlock time so
    // it can never trap the user past wake time.
    _manualLockReleaseAt = nextUnlockAfter(DateTime.now());
    _permanentlyUnlocked = false;
    _updateState();
  }

  /// The next occurrence of the scheduled unlock time strictly after [from]:
  /// today's unlock if it is still ahead, otherwise tomorrow's. Pure so it can
  /// be unit-tested without a wall clock.
  @visibleForTesting
  DateTime nextUnlockAfter(DateTime from) {
    final today = DateTime(
      from.year,
      from.month,
      from.day,
      AppConfig.unlockHour,
      AppConfig.unlockMinute,
    );
    if (today.isAfter(from)) return today;
    final tomorrow = from.add(const Duration(days: 1));
    return DateTime(
      tomorrow.year,
      tomorrow.month,
      tomorrow.day,
      AppConfig.unlockHour,
      AppConfig.unlockMinute,
    );
  }

  /// True when a manual lock has reached its scheduled release time and should
  /// be cleared. Pure (takes [now]) so the morning-release behavior is testable
  /// without depending on the wall clock. False when there is no manual lock or
  /// no recorded release instant.
  @visibleForTesting
  bool manualLockExpired(DateTime now) {
    if (!_manualLock || _manualLockReleaseAt == null) return false;
    return !now.isBefore(_manualLockReleaseAt!);
  }

  /// Persist the current grant state. Fire-and-forget; failures are swallowed
  /// to match the rest of the persistence layer.
  Future<void> _persistGrantState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_grantExpiry != null) {
        await prefs.setInt(
            _grantExpiryKey, _grantExpiry!.millisecondsSinceEpoch);
        await prefs.setStringList(_grantAllowKey, _grantAllow);
      } else {
        await prefs.remove(_grantExpiryKey);
        await prefs.remove(_grantAllowKey);
      }
      await prefs.setInt(_grantsUsedKey, _grantsUsedTonight);
      await prefs.setInt(_grantedMinutesKey, _grantedMinutesTonight);
      // Stamp the night these counters belong to so a next-day relaunch can
      // detect + discard stale counters.
      await prefs.setString(_grantNightKey, nightKeyFor(DateTime.now()));
    } catch (_) {}
  }

  /// Reload grant state on start. If a stored expiry is still in the future,
  /// resume the granted state and countdown timer; if it's in the past (or
  /// missing), clear it so we fall through to the normal schedule.
  Future<void> restoreGrantState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Only carry counters forward if they belong to TONIGHT's lockdown. After
      // a next-day relaunch (grant already expired) stale counters would wrongly
      // constrain tonight's caps, so reset them and drop the stored grant.
      final storedNight = prefs.getString(_grantNightKey);
      final currentNight = nightKeyFor(DateTime.now());
      if (storedNight != null && storedNight != currentNight) {
        _grantsUsedTonight = 0;
        _grantedMinutesTonight = 0;
        await prefs.remove(_grantsUsedKey);
        await prefs.remove(_grantedMinutesKey);
        await prefs.remove(_grantExpiryKey);
        await prefs.remove(_grantAllowKey);
        await prefs.remove(_grantNightKey);
        return;
      }
      _grantsUsedTonight = prefs.getInt(_grantsUsedKey) ?? 0;
      _grantedMinutesTonight = prefs.getInt(_grantedMinutesKey) ?? 0;
      final expiryMs = prefs.getInt(_grantExpiryKey);
      if (expiryMs == null) return;

      final expiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
      if (expiry.isAfter(DateTime.now())) {
        _grantExpiry = expiry;
        _grantAllow = prefs.getStringList(_grantAllowKey) ?? const [];
        _state = LockdownState.granted;
        onStateChange(_state);
        // Re-arm a selective grant's platform allow-list after a crash so the
        // overlay restores in the correct (grant) mode rather than full lock.
        if (_grantAllow.isNotEmpty) {
          onSelectiveGrant?.call(
            _grantAllow,
            expiry.difference(DateTime.now()).inMinutes.clamp(1, 1 << 30),
          );
        }
        _startGrantTimer();
      } else {
        _grantExpiry = null;
        _grantAllow = const [];
        await prefs.remove(_grantExpiryKey);
        await prefs.remove(_grantAllowKey);
      }
    } catch (_) {}
  }

  void _startGrantTimer() {
    _grantTimer?.cancel();
    _grantTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = grantRemaining;
      if (remaining == null || remaining <= Duration.zero) {
        _grantTimer?.cancel();
        _grantExpiry = null;
        _grantAllow = const [];
        unawaited(_persistGrantState());
        _updateState();
        onGrantExpired?.call();
      } else {
        onGrantTick?.call(remaining);
      }
    });
  }

  void stop() {
    ScheduleStore.instance.removeListener(_onScheduleChanged);
    _ticker?.cancel();
    _grantTimer?.cancel();
    _ticker = null;
    _grantTimer = null;
  }

  /// Guards [_updateState] against synchronous re-entry. [revertTonightNudges]
  /// calls `notifyListeners()` on the ScheduleStore, which re-enters
  /// [_updateState] through [_onScheduleChanged]; this flag drops that nested
  /// call so the revert can't recurse. Behavior is otherwise identical.
  bool _inUpdateState = false;

  void _updateState() {
    if (_inUpdateState) return;
    _inUpdateState = true;
    try {
      _updateStateInner();
    } finally {
      _inUpdateState = false;
    }
  }

  void _updateStateInner() {
    final previousState = _state;
    final newState = _computeState();

    if (newState != _state) {
      _state = newState;
      onStateChange(_state);
    }

    if (newState == LockdownState.windDown && !_windDownNotified) {
      _windDownNotified = true;
    }

    if (newState == LockdownState.locked && !_lockdownNotified) {
      _lockdownNotified = true;
    }

    // Capture the night's lockdown start the FIRST time we enter locked. A
    // later schedule edit shifts what lockdownStartForDate would compute, so we
    // freeze it here and reuse it for sleep logging.
    if (newState == LockdownState.locked && _activeLockdownStart == null) {
      _activeLockdownStart = AppConfig.lockdownStartForDate(DateTime.now());
    }

    if ((previousState == LockdownState.locked ||
            previousState == LockdownState.granted) &&
        newState == LockdownState.unlocked) {
      unawaited(_logSleepIfNeeded());
      _grantsUsedTonight = 0;
      _grantedMinutesTonight = 0;
      _grantAllow = const [];
      _windDownNotified = false;
      _lockdownNotified = false;
      _activeLockdownStart = null;
      _manualLock = false;
      _manualLockReleaseAt = null;
      // Roll back any tonight-only guardian nudges for the next night.
      ScheduleStore.instance.revertTonightNudges();
      unawaited(_persistGrantState());
    }
  }

  LockdownState _computeState() {
    final now = DateTime.now();

    if (_grantExpiry != null && now.isBefore(_grantExpiry!)) {
      return LockdownState.granted;
    }

    if (_grantExpiry != null && !now.isBefore(_grantExpiry!)) {
      _grantExpiry = null;
      _grantAllow = const [];
      _grantTimer?.cancel();
      unawaited(_persistGrantState());
    }

    if (_permanentlyUnlocked) {
      // Reset the flag once we're naturally outside lockdown hours.
      if (!AppConfig.isLockdownTime(now)) _permanentlyUnlocked = false;
      return LockdownState.unlocked;
    }

    // Manual lock-now overrides the clock so the takeover can be engaged/tested
    // on demand. A grant (above) still wins so the user can always negotiate out.
    // BUT a manual lock must NOT trap the user past wake time: once we reach the
    // scheduled morning unlock, clear it and fall through to the normal schedule
    // (which returns unlocked in the morning).
    if (_manualLock) {
      if (manualLockExpired(now)) {
        _manualLock = false;
        _manualLockReleaseAt = null;
      } else {
        return LockdownState.locked;
      }
    }

    if (AppConfig.isLockdownTime(now)) return LockdownState.locked;
    if (AppConfig.isWindDownTime(now)) return LockdownState.windDown;
    if (AppConfig.isAwakeTime(now)) return LockdownState.awake;
    return LockdownState.unlocked;
  }

  /// End an active grant EARLY ("back to sleep early") without permanently
  /// unlocking. Cancels the grant (timer + expiry + allow-list), persists, and
  /// recomputes the state so we fall back to `locked` (respecting `_manualLock`
  /// / the schedule). Unlike [fullUnlock] this NEVER sets `_permanentlyUnlocked`
  /// — the user is voluntarily returning to lockdown, so the takeover must
  /// re-arm. No-op if there's no active grant.
  void endGrantEarly() {
    if (_grantExpiry == null) return;
    _grantTimer?.cancel();
    _grantTimer = null;
    _grantExpiry = null;
    _grantAllow = const [];
    unawaited(_persistGrantState());
    // Recompute: with the grant cleared this returns to locked (manual lock or
    // schedule) or unlocked if we're genuinely outside lockdown hours. It does
    // NOT set _permanentlyUnlocked, so onStateChange re-arms the takeover.
    _updateState();
  }

  /// Fully unlock for the rest of the night — no timer, no re-lock.
  void fullUnlock() {
    _grantTimer?.cancel();
    _grantExpiry = null;
    _grantAllow = const [];
    _manualLock = false;
    _manualLockReleaseAt = null;
    _permanentlyUnlocked = true;
    _state = LockdownState.unlocked;
    onStateChange(_state);
    unawaited(_persistGrantState());
  }

  void grantExtension(int minutes) {
    final safeMinutes = AppConfig.sanitizeGrantedMinutes(minutes);
    _grantsUsedTonight++;
    _grantedMinutesTonight += safeMinutes;
    _grantAllow = const [];
    _grantExpiry = DateTime.now().add(Duration(minutes: safeMinutes));
    _state = LockdownState.granted;
    onStateChange(_state);
    unawaited(_persistGrantState());

    _startGrantTimer();
  }

  /// Selective per-app grant (M2). Like [grantExtension] it enters the granted
  /// state with a countdown, but it carries an [allow] image-name list and does
  /// NOT permanently unlock — the overlay stays armed and re-locks on expiry.
  /// The host's [onSelectiveGrant] wires this to the platform layer.
  void grantSelective({required List<String> allow, required int minutes}) {
    final safeMinutes = AppConfig.sanitizeGrantedMinutes(minutes);
    _grantsUsedTonight++;
    _grantedMinutesTonight += safeMinutes;
    _grantAllow = List.unmodifiable(allow);
    _grantExpiry = DateTime.now().add(Duration(minutes: safeMinutes));
    _state = LockdownState.granted;
    onStateChange(_state);
    onSelectiveGrant?.call(_grantAllow, safeMinutes);
    unawaited(_persistGrantState());

    _startGrantTimer();
  }

  Future<void> _logSleepIfNeeded() async {
    final now = DateTime.now();
    // Prefer the start captured at lock-entry; fall back to a fresh compute
    // only if we somehow never recorded one (e.g. grant restored across a
    // restart without re-entering locked).
    final lockdownStart =
        _activeLockdownStart ?? AppConfig.lockdownStartForDate(now);
    final date = lockdownStart.toIso8601String().split('T')[0];
    if (_lastSleepLogDate == date) return;
    _lastSleepLogDate = date;

    await MemoryService.logSleep(
      lockdownStart: lockdownStart,
      grantsUsed: _grantsUsedTonight,
      totalExtraMinutes: _grantedMinutesTonight,
    );
  }

  void dispose() => stop();
}
