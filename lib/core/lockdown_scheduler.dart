import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'memory_service.dart';

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
  int _grantsUsedTonight = 0;
  int _grantedMinutesTonight = 0;
  bool _windDownNotified = false;
  bool _lockdownNotified = false;
  bool _permanentlyUnlocked = false;
  String? _lastSleepLogDate;

  final void Function(LockdownState state) onStateChange;
  final void Function(Duration remaining)? onGrantTick;
  final void Function()? onGrantExpired;

  LockdownScheduler({
    required this.onStateChange,
    this.onGrantTick,
    this.onGrantExpired,
  });

  // Pref keys for persisting grant state across restarts so a crash
  // mid-grant restores the remaining time instead of instant re-lock.
  static const _grantExpiryKey = 'grant_expiry_ms';
  static const _grantsUsedKey = 'grants_used_tonight';
  static const _grantedMinutesKey = 'granted_minutes_tonight';

  LockdownState get state => _state;
  int get grantsUsedTonight => _grantsUsedTonight;
  DateTime? get grantExpiry => _grantExpiry;

  Duration? get grantRemaining {
    if (_grantExpiry == null) return null;
    final remaining = _grantExpiry!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void start() {
    // Restore any in-flight grant from a previous run before the first tick.
    unawaited(restoreGrantState());
    // Defer first update so it doesn't fire during initState/build
    Timer(Duration.zero, _updateState);
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) => _updateState());
  }

  /// Persist the current grant state. Fire-and-forget; failures are swallowed
  /// to match the rest of the persistence layer.
  Future<void> _persistGrantState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_grantExpiry != null) {
        await prefs.setInt(
            _grantExpiryKey, _grantExpiry!.millisecondsSinceEpoch);
      } else {
        await prefs.remove(_grantExpiryKey);
      }
      await prefs.setInt(_grantsUsedKey, _grantsUsedTonight);
      await prefs.setInt(_grantedMinutesKey, _grantedMinutesTonight);
    } catch (_) {}
  }

  /// Reload grant state on start. If a stored expiry is still in the future,
  /// resume the granted state and countdown timer; if it's in the past (or
  /// missing), clear it so we fall through to the normal schedule.
  Future<void> restoreGrantState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _grantsUsedTonight = prefs.getInt(_grantsUsedKey) ?? 0;
      _grantedMinutesTonight = prefs.getInt(_grantedMinutesKey) ?? 0;
      final expiryMs = prefs.getInt(_grantExpiryKey);
      if (expiryMs == null) return;

      final expiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
      if (expiry.isAfter(DateTime.now())) {
        _grantExpiry = expiry;
        _state = LockdownState.granted;
        onStateChange(_state);
        _startGrantTimer();
      } else {
        _grantExpiry = null;
        await prefs.remove(_grantExpiryKey);
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
        unawaited(_persistGrantState());
        _updateState();
        onGrantExpired?.call();
      } else {
        onGrantTick?.call(remaining);
      }
    });
  }

  void stop() {
    _ticker?.cancel();
    _grantTimer?.cancel();
    _ticker = null;
    _grantTimer = null;
  }

  void _updateState() {
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

    if ((previousState == LockdownState.locked ||
            previousState == LockdownState.granted) &&
        newState == LockdownState.unlocked) {
      unawaited(_logSleepIfNeeded());
      _grantsUsedTonight = 0;
      _grantedMinutesTonight = 0;
      _windDownNotified = false;
      _lockdownNotified = false;
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
      _grantTimer?.cancel();
      unawaited(_persistGrantState());
    }

    if (_permanentlyUnlocked) {
      // Reset the flag once we're naturally outside lockdown hours.
      if (!AppConfig.isLockdownTime(now)) _permanentlyUnlocked = false;
      return LockdownState.unlocked;
    }

    if (AppConfig.isLockdownTime(now)) return LockdownState.locked;
    if (AppConfig.isWindDownTime(now)) return LockdownState.windDown;
    if (AppConfig.isAwakeTime(now)) return LockdownState.awake;
    return LockdownState.unlocked;
  }

  /// Fully unlock for the rest of the night — no timer, no re-lock.
  void fullUnlock() {
    _grantTimer?.cancel();
    _grantExpiry = null;
    _permanentlyUnlocked = true;
    _state = LockdownState.unlocked;
    onStateChange(_state);
    unawaited(_persistGrantState());
  }

  void grantExtension(int minutes) {
    final safeMinutes = AppConfig.sanitizeGrantedMinutes(minutes);
    _grantsUsedTonight++;
    _grantedMinutesTonight += safeMinutes;
    _grantExpiry = DateTime.now().add(Duration(minutes: safeMinutes));
    _state = LockdownState.granted;
    onStateChange(_state);
    unawaited(_persistGrantState());

    _startGrantTimer();
  }

  Future<void> _logSleepIfNeeded() async {
    final now = DateTime.now();
    final lockdownStart = AppConfig.lockdownStartForDate(now);
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
