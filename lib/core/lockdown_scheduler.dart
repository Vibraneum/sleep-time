import 'dart:async';

import 'config.dart';
import 'memory_service.dart';
import 'poke_service.dart';

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
  String? _lastSleepLogDate;

  final void Function(LockdownState state) onStateChange;
  final void Function(Duration remaining)? onGrantTick;
  final void Function()? onGrantExpired;

  LockdownScheduler({
    required this.onStateChange,
    this.onGrantTick,
    this.onGrantExpired,
  });

  LockdownState get state => _state;
  int get grantsUsedTonight => _grantsUsedTonight;
  DateTime? get grantExpiry => _grantExpiry;

  Duration? get grantRemaining {
    if (_grantExpiry == null) return null;
    final remaining = _grantExpiry!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void start() {
    _updateState();
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) => _updateState());
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
      unawaited(PokeService.sendBedtimeWarning());
    }

    if (newState == LockdownState.locked && !_lockdownNotified) {
      _lockdownNotified = true;
      unawaited(PokeService.sendLockdownActive());
    }

    if ((previousState == LockdownState.locked ||
            previousState == LockdownState.granted) &&
        newState == LockdownState.unlocked) {
      unawaited(_logSleepIfNeeded());
      _grantsUsedTonight = 0;
      _grantedMinutesTonight = 0;
      _windDownNotified = false;
      _lockdownNotified = false;
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
    }

    if (AppConfig.isLockdownTime(now)) return LockdownState.locked;
    if (AppConfig.isWindDownTime(now)) return LockdownState.windDown;
    if (AppConfig.isAwakeTime(now)) return LockdownState.awake;
    return LockdownState.unlocked;
  }

  void grantExtension(int minutes) {
    final safeMinutes = AppConfig.sanitizeGrantedMinutes(minutes);
    _grantsUsedTonight++;
    _grantedMinutesTonight += safeMinutes;
    _grantExpiry = DateTime.now().add(Duration(minutes: safeMinutes));
    _state = LockdownState.granted;
    onStateChange(_state);
    unawaited(PokeService.sendGrantNotification(safeMinutes));

    _grantTimer?.cancel();
    _grantTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = grantRemaining;
      if (remaining == null || remaining <= Duration.zero) {
        _grantTimer?.cancel();
        _grantExpiry = null;
        _updateState();
        onGrantExpired?.call();
      } else {
        onGrantTick?.call(remaining);
      }
    });
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
