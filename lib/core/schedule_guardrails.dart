// Anti-manipulation policy for AI-SOURCED schedule changes ONLY.
//
// The human (Settings) path is intentionally unconstrained — a person sets
// the permanent baseline. This file exists so the *guardian* cannot be
// socially-engineered into pushing bedtime to 3 AM or disabling lockdown via
// a long string of "just five more minutes" asks. Every AI-proposed change
// runs through [ScheduleGuardrails.evaluate] before [ScheduleStore.apply].
//
// Pure Dart. No I/O. The caller (the negotiation engine) is responsible for
// computing the [NightlyAiBudget] from the audit table and for knowing whether
// lockdown is currently active.

import 'schedule.dart';

/// Tonight-only nudge vs a permanent baseline shift. Carried from the
/// `scope` field of the `adjust_schedule` tool input.
enum ScheduleScope { tonight, permanent }

/// What the guardrails decided about an AI-proposed change.
enum GuardrailOutcome {
  /// The proposed time is within all envelopes and budgets — apply as-is.
  granted,

  /// The proposal was reined in to the nearest allowed value (e.g. clamped to
  /// +60 from baseline). The returned [applied] schedule reflects the clamp.
  clamped,

  /// The proposal cannot be applied at all (outside the hard envelope, an
  /// ordering violation, budget exhausted, or lockdown already active).
  rejected,
}

/// Result of running the guardrails. When [outcome] is granted/clamped,
/// [applied] is the schedule to persist; when rejected, [applied] echoes the
/// unchanged `current` and nothing should be written.
class GuardrailDecision {
  final GuardrailOutcome outcome;
  final SleepSchedule applied;

  /// A short, user-truthful explanation, e.g. "can only move bedtime 60 min
  /// from your baseline". Surfaced back to the model as the tool_result and to
  /// the UI as a chip.
  final String humanReason;

  const GuardrailDecision({
    required this.outcome,
    required this.applied,
    required this.humanReason,
  });

  bool get blocked => outcome == GuardrailOutcome.rejected;
}

/// The tonight-so-far AI usage, computed by the caller from the
/// `schedule_changes` audit table (rows since 22:00 with an AI source).
class NightlyAiBudget {
  /// Number of AI schedule edits already applied tonight (granted or clamped).
  final int editsUsed;

  /// Cumulative minutes the AI has already *delayed* tonight's lockdown vs the
  /// baseline (positive = later bedtime). Earlier-than-baseline moves do not
  /// add to this.
  final int cumulativeLockdownDelayMin;

  /// Cumulative absolute drift (either direction) the AI has already applied to
  /// wakeUp tonight vs the baseline, in minutes.
  final int cumulativeWakeUpDriftMin;

  /// Cumulative absolute drift (either direction) the AI has already applied to
  /// windDown tonight vs the baseline, in minutes.
  final int cumulativeWindDownDriftMin;

  const NightlyAiBudget({
    this.editsUsed = 0,
    this.cumulativeLockdownDelayMin = 0,
    this.cumulativeWakeUpDriftMin = 0,
    this.cumulativeWindDownDriftMin = 0,
  });
}

/// Pure anti-manipulation policy for AI schedule changes.
///
/// NOTE TO PRODUCT: every numeric constant below is a first-pass guess and
/// needs product sign-off before launch. They are intentionally grouped and
/// documented so they can be tuned without touching the logic.
class ScheduleGuardrails {
  ScheduleGuardrails._();

  // --- Hard envelopes (wall-clock windows the AI may never leave) ---------

  /// Earliest the AI may set lockdown: 21:00. (Minutes-of-day.)
  static const int lockdownEnvelopeStartMin = 21 * 60; // 21:00

  /// Latest the AI may set lockdown: 01:00 next day. Stored as minutes past
  /// midnight on the *following* day so the wrap-aware window 21:00..01:00 is
  /// expressible as a single forward arc.
  static const int lockdownEnvelopeEndMin = 25 * 60; // 01:00 (+1 day)

  /// Earliest the AI may set unlock: 04:00.
  static const int unlockEnvelopeStartMin = 4 * 60; // 04:00

  /// Latest the AI may set unlock: 09:00.
  static const int unlockEnvelopeEndMin = 9 * 60; // 09:00

  // NEEDS PRODUCT SIGN-OFF: the wakeUp / windDown envelopes below are first-pass
  // guesses, like the lockdown/unlock ones. They cap how far the guardian can
  // walk the *monitoring* and *wind-down* boundaries (including via permanent
  // baseline edits, which are clamped to these too) so repeated nudges can't
  // drift the whole evening earlier/later across nights.

  /// Earliest the AI may set wakeUp (guardian wakes/monitors): 20:00.
  static const int wakeUpEnvelopeStartMin = 20 * 60; // 20:00

  /// Latest the AI may set wakeUp: 23:30.
  static const int wakeUpEnvelopeEndMin = 23 * 60 + 30; // 23:30

  /// Earliest the AI may set windDown: 20:30.
  static const int windDownEnvelopeStartMin = 20 * 60 + 30; // 20:30

  /// Latest the AI may set windDown: 00:30 next day. Stored as minutes past
  /// midnight on the *following* day so the wrap-aware window 20:30..00:30 is a
  /// single forward arc, mirroring the lockdown envelope encoding.
  static const int windDownEnvelopeEndMin = 24 * 60 + 30; // 00:30 (+1 day)

  // --- Per-nudge and cumulative caps --------------------------------------

  /// A single AI nudge may move a field at most this many minutes from the
  /// *baseline* value of that field (in either direction).
  static const int maxSingleNudgeMin = 60;

  /// Total AI-applied *delay* to lockdown across the night may not exceed this
  /// many minutes vs the baseline.
  static const int maxCumulativeLockdownDelayMin = 90;

  /// Total AI-applied *drift* (in either direction) to wakeUp or windDown
  /// across the night may not exceed this many minutes vs the baseline. Mirrors
  /// the lockdown cumulative cap so repeated nudges can't walk the evening
  /// monitoring/wind-down boundaries arbitrarily. NEEDS PRODUCT SIGN-OFF.
  static const int maxCumulativeWindowDriftMin = 90;

  /// Maximum number of AI schedule edits per night.
  static const int maxAiEditsPerNight = 3;

  static const int _dayMinutes = 24 * 60;

  /// Pull the [ScheduleTime] for a named field from a schedule.
  static ScheduleTime _field(SleepSchedule s, String field) {
    switch (field) {
      case 'wakeUp':
        return s.wakeUp;
      case 'windDown':
        return s.windDown;
      case 'lockdown':
        return s.lockdown;
      case 'unlock':
        return s.unlock;
      default:
        return s.lockdown;
    }
  }

  /// Build a copy of [s] with [field] replaced by [t].
  static SleepSchedule _withField(
    SleepSchedule s,
    String field,
    ScheduleTime t,
  ) {
    switch (field) {
      case 'wakeUp':
        return s.copyWith(wakeUp: t);
      case 'windDown':
        return s.copyWith(windDown: t);
      case 'lockdown':
        return s.copyWith(lockdown: t);
      case 'unlock':
        return s.copyWith(unlock: t);
      default:
        return s;
    }
  }

  /// Signed delta in minutes from [baseline] to [proposed], choosing the
  /// shorter wrap-aware direction (so 23:30 -> 00:15 reads as +45, not -1425).
  static int _wrapDelta(int baseline, int proposed) {
    var delta = proposed - baseline;
    if (delta > _dayMinutes ~/ 2) delta -= _dayMinutes;
    if (delta < -_dayMinutes ~/ 2) delta += _dayMinutes;
    return delta;
  }

  /// True when [minutesOfDay], interpreted on the lockdown 21:00..01:00 arc, is
  /// inside the envelope. The arc wraps past midnight, so a value like 00:30
  /// (=30) is mapped onto the +1-day axis (=1470) before the range check.
  static bool _withinLockdownEnvelope(int minutesOfDay) {
    final wrapped =
        minutesOfDay < lockdownEnvelopeStartMin // pre-21:00 => next-day side
            ? minutesOfDay + _dayMinutes
            : minutesOfDay;
    return wrapped >= lockdownEnvelopeStartMin &&
        wrapped <= lockdownEnvelopeEndMin;
  }

  static bool _withinUnlockEnvelope(int minutesOfDay) =>
      minutesOfDay >= unlockEnvelopeStartMin &&
      minutesOfDay <= unlockEnvelopeEndMin;

  static bool _withinWakeUpEnvelope(int minutesOfDay) =>
      minutesOfDay >= wakeUpEnvelopeStartMin &&
      minutesOfDay <= wakeUpEnvelopeEndMin;

  /// True when [minutesOfDay], interpreted on the windDown 20:30..00:30 arc, is
  /// inside the envelope. The arc wraps past midnight, so a value like 00:15
  /// (=15) is mapped onto the +1-day axis (=1455) before the range check —
  /// mirroring [_withinLockdownEnvelope].
  static bool _withinWindDownEnvelope(int minutesOfDay) {
    final wrapped = minutesOfDay < windDownEnvelopeStartMin
        ? minutesOfDay + _dayMinutes
        : minutesOfDay;
    return wrapped >= windDownEnvelopeStartMin &&
        wrapped <= windDownEnvelopeEndMin;
  }

  /// Wrap-aware ordering check for an AI candidate schedule. Delegates to the
  /// shared [scheduleArcIsCoherent] helper so the guardrails and
  /// [SleepSchedule.validate] can never disagree about whether an ordering is
  /// coherent. Range validity is already guaranteed before this is called.
  static bool _orderingOk(SleepSchedule s) => scheduleArcIsCoherent(
        wakeUpMin: s.wakeUp.minutesOfDay,
        windDownMin: s.windDown.minutesOfDay,
        lockdownMin: s.lockdown.minutesOfDay,
        unlockMin: s.unlock.minutesOfDay,
      );

  /// Evaluate one AI-proposed change. Pure — performs no I/O and mutates
  /// nothing.
  ///
  /// [baseline] is the human-set permanent schedule; [current] is the live
  /// (possibly already-nudged) schedule. [field]/[hour]/[minute] describe the
  /// proposal. [budget] is the tonight-so-far AI usage. [lockdownActive] is
  /// true when the scheduler is in locked/granted state (the AI may not touch
  /// tonight's lockdown field once we are inside lockdown).
  static GuardrailDecision evaluate({
    required SleepSchedule baseline,
    required SleepSchedule current,
    required String field,
    required int hour,
    required int minute,
    required ScheduleScope scope,
    required NightlyAiBudget budget,
    required bool lockdownActive,
  }) {
    // Edit-count cap first — independent of which field is touched.
    if (budget.editsUsed >= maxAiEditsPerNight) {
      return GuardrailDecision(
        outcome: GuardrailOutcome.rejected,
        applied: current,
        humanReason:
            'already adjusted the schedule $maxAiEditsPerNight times tonight; '
            'no more changes until tomorrow',
      );
    }

    // Once lockdown is active, the AI cannot move tonight's lockdown boundary
    // (no rescuing yourself out of a lock you are already inside).
    if (lockdownActive && field == 'lockdown') {
      return GuardrailDecision(
        outcome: GuardrailOutcome.rejected,
        applied: current,
        humanReason:
            "lockdown's already started — can't move tonight's bedtime now",
      );
    }

    // Range sanity. A malformed hour/minute is a hard reject.
    final rawProposed = ScheduleTime(hour, minute);
    if (!rawProposed.isValid) {
      return GuardrailDecision(
        outcome: GuardrailOutcome.rejected,
        applied: current,
        humanReason: 'that is not a real time',
      );
    }

    final baseField = _field(baseline, field);
    final baseMin = baseField.minutesOfDay;
    var proposedMin = rawProposed.minutesOfDay;
    var clamped = false;
    final reasons = <String>[];

    // --- Per-nudge ±60 from baseline -------------------------------------
    final delta = _wrapDelta(baseMin, proposedMin);
    if (delta.abs() > maxSingleNudgeMin) {
      final clampedDelta = delta > 0 ? maxSingleNudgeMin : -maxSingleNudgeMin;
      proposedMin = (baseMin + clampedDelta + _dayMinutes) % _dayMinutes;
      clamped = true;
      reasons.add('can only move $field ${maxSingleNudgeMin}min from baseline');
    }

    // --- Cumulative lockdown delay cap -----------------------------------
    // Only delays (later bedtime) count toward the cap; pulling lockdown
    // earlier is always welcome and never restricted by this rule.
    if (field == 'lockdown') {
      final proposedDelay = _wrapDelta(baseMin, proposedMin);
      if (proposedDelay > 0) {
        final remaining =
            maxCumulativeLockdownDelayMin - budget.cumulativeLockdownDelayMin;
        if (remaining <= 0) {
          return GuardrailDecision(
            outcome: GuardrailOutcome.rejected,
            applied: current,
            humanReason: 'bedtime is already as late as it can go tonight '
                '(max ${maxCumulativeLockdownDelayMin}min past baseline)',
          );
        }
        if (proposedDelay > remaining) {
          proposedMin = (baseMin + remaining + _dayMinutes) % _dayMinutes;
          clamped = true;
          reasons.add('bedtime can move at most ${remaining}min more tonight '
              '(${maxCumulativeLockdownDelayMin}min nightly cap)');
        }
      }
    }

    // --- Cumulative wakeUp / windDown drift cap --------------------------
    // Drift in EITHER direction counts toward the cap so repeated nudges can't
    // walk the monitoring / wind-down boundaries arbitrarily across the night.
    if (field == 'wakeUp' || field == 'windDown') {
      final alreadyDrifted = field == 'wakeUp'
          ? budget.cumulativeWakeUpDriftMin
          : budget.cumulativeWindDownDriftMin;
      final proposedDrift = _wrapDelta(baseMin, proposedMin).abs();
      if (proposedDrift > 0) {
        final remaining = maxCumulativeWindowDriftMin - alreadyDrifted;
        if (remaining <= 0) {
          return GuardrailDecision(
            outcome: GuardrailOutcome.rejected,
            applied: current,
            humanReason: '$field has already moved as far as it can tonight '
                '(max ${maxCumulativeWindowDriftMin}min from baseline)',
          );
        }
        if (proposedDrift > remaining) {
          final signedDelta = _wrapDelta(baseMin, proposedMin);
          final clampedDrift = signedDelta > 0 ? remaining : -remaining;
          proposedMin = (baseMin + clampedDrift + _dayMinutes) % _dayMinutes;
          clamped = true;
          reasons.add('$field can move at most ${remaining}min more tonight '
              '(${maxCumulativeWindowDriftMin}min nightly cap)');
        }
      }
    }

    // --- Hard envelopes ---------------------------------------------------
    if (field == 'lockdown' && !_withinLockdownEnvelope(proposedMin)) {
      return GuardrailDecision(
        outcome: GuardrailOutcome.rejected,
        applied: current,
        humanReason: 'bedtime must stay between 9:00 PM and 1:00 AM',
      );
    }
    if (field == 'unlock' && !_withinUnlockEnvelope(proposedMin)) {
      return GuardrailDecision(
        outcome: GuardrailOutcome.rejected,
        applied: current,
        humanReason: 'wake-up must stay between 4:00 AM and 9:00 AM',
      );
    }
    if (field == 'wakeUp' && !_withinWakeUpEnvelope(proposedMin)) {
      return GuardrailDecision(
        outcome: GuardrailOutcome.rejected,
        applied: current,
        humanReason: 'guardian wake time must stay between 8:00 PM and 11:30 PM',
      );
    }
    if (field == 'windDown' && !_withinWindDownEnvelope(proposedMin)) {
      return GuardrailDecision(
        outcome: GuardrailOutcome.rejected,
        applied: current,
        humanReason: 'wind-down must stay between 8:30 PM and 12:30 AM',
      );
    }

    // --- Build the candidate schedule and run ordering validation --------
    final newTime = ScheduleTime(proposedMin ~/ 60, proposedMin % 60);
    final candidate = _withField(current, field, newTime);
    if (!_orderingOk(candidate)) {
      return GuardrailDecision(
        outcome: GuardrailOutcome.rejected,
        applied: current,
        humanReason: 'that ordering does not make sense for $field',
      );
    }

    return GuardrailDecision(
      outcome: clamped ? GuardrailOutcome.clamped : GuardrailOutcome.granted,
      applied: candidate,
      humanReason: clamped ? reasons.join('; ') : 'ok',
    );
  }
}
