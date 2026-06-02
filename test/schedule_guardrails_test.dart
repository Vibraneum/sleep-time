import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/schedule.dart';
import 'package:sleep_time/core/schedule_guardrails.dart';

void main() {
  // Baseline = shipped defaults: wake 22:30, wind 23:00, lock 23:30, unlock 06:00.
  final baseline = SleepSchedule.defaults;
  const noBudget = NightlyAiBudget();

  GuardrailDecision check({
    SleepSchedule? current,
    required String field,
    required int hour,
    required int minute,
    ScheduleScope scope = ScheduleScope.tonight,
    NightlyAiBudget budget = noBudget,
    bool lockdownActive = false,
  }) {
    return ScheduleGuardrails.evaluate(
      baseline: baseline,
      current: current ?? baseline,
      field: field,
      hour: hour,
      minute: minute,
      scope: scope,
      budget: budget,
      lockdownActive: lockdownActive,
    );
  }

  group('per-nudge ±60 from baseline', () {
    test('grants a lockdown move within 60 min (23:30 -> 00:00, +30)', () {
      final d = check(field: 'lockdown', hour: 0, minute: 0);
      expect(d.outcome, GuardrailOutcome.granted);
      expect(d.applied.lockdown, const ScheduleTime(0, 0));
    });

    test('clamps to +60 when asking for +90 (23:30 -> 01:00 => 00:30)', () {
      final d = check(field: 'lockdown', hour: 1, minute: 0);
      expect(d.outcome, GuardrailOutcome.clamped);
      // baseline 23:30 + 60 = 00:30
      expect(d.applied.lockdown, const ScheduleTime(0, 30));
    });

    test('clamps earlier moves too (wakeUp -90 clamps to -60)', () {
      // baseline wake 22:30; asking 21:00 (-90) clamps to 21:30 (-60).
      final d = check(field: 'wakeUp', hour: 21, minute: 0);
      expect(d.outcome, GuardrailOutcome.clamped);
      expect(d.applied.wakeUp, const ScheduleTime(21, 30));
    });
  });

  group('hard envelopes', () {
    test('rejects lockdown after the 01:00 envelope', () {
      // The ±60 clamp runs before the envelope check, so to land outside the
      // 01:00 edge we need a baseline near it: baseline lockdown 00:30, ask
      // 01:30 (+60, within ±60) — still past the 01:00 hard edge.
      final lateBaseline = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(0, 30),
        unlock: const ScheduleTime(6, 0),
      );
      final d = ScheduleGuardrails.evaluate(
        baseline: lateBaseline,
        current: lateBaseline,
        field: 'lockdown',
        hour: 1,
        minute: 30,
        scope: ScheduleScope.tonight,
        budget: noBudget,
        lockdownActive: false,
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });

    test('rejects unlock outside the 09:00 envelope edge', () {
      // The ±60 clamp runs first, so to land past 09:00 we need a baseline near
      // it: baseline unlock 08:30, ask 09:30 (+60, within ±60) — past the edge.
      final lateBaseline = SleepSchedule.defaults.copyWith(
        unlock: const ScheduleTime(8, 30),
      );
      final d = ScheduleGuardrails.evaluate(
        baseline: lateBaseline,
        current: lateBaseline,
        field: 'unlock',
        hour: 9,
        minute: 30,
        scope: ScheduleScope.tonight,
        budget: noBudget,
        lockdownActive: false,
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });

    test('rejects unlock before the 04:00 envelope', () {
      // baseline unlock 06:00; 03:00 is -180 (clamps to 05:00) which is inside
      // the envelope, so that would be CLAMPED. Use a baseline closer to the
      // floor so a -60 nudge lands genuinely outside (03:30 < 04:00).
      final earlyBaseline = SleepSchedule.defaults.copyWith(
        unlock: const ScheduleTime(4, 30),
      );
      final d = ScheduleGuardrails.evaluate(
        baseline: earlyBaseline,
        current: earlyBaseline,
        field: 'unlock',
        hour: 3,
        minute: 30, // -60 from 04:30 = 03:30, outside the 04:00 floor
        scope: ScheduleScope.tonight,
        budget: noBudget,
        lockdownActive: false,
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });

    test('a user cannot push lockdown past 01:00 via repeated asks', () {
      // 1st: +30 -> 00:00 (delay 30)
      var d = check(field: 'lockdown', hour: 0, minute: 0);
      expect(d.outcome, GuardrailOutcome.granted);

      // 2nd ask, already +30: +60 -> 00:30 (delay total 60)
      d = check(
        field: 'lockdown',
        hour: 0,
        minute: 30,
        budget:
            const NightlyAiBudget(editsUsed: 1, cumulativeLockdownDelayMin: 30),
      );
      expect(d.outcome, GuardrailOutcome.granted);

      // 3rd ask, already +60: wants 00:30 (+60 from baseline) but only +30
      // remains under the 90-min cap.
      d = check(
        field: 'lockdown',
        hour: 0,
        minute: 30,
        budget:
            const NightlyAiBudget(editsUsed: 2, cumulativeLockdownDelayMin: 60),
      );
      // Clamps to baseline + remaining (30) = 00:00. Total tonight = 90, the
      // cap — bedtime can never be pushed past it via more asks.
      expect(d.outcome, GuardrailOutcome.clamped);
      expect(d.applied.lockdown, const ScheduleTime(0, 0));
    });
  });

  group('cumulative lockdown delay cap', () {
    test('clamps the delay to whatever budget remains', () {
      // Already delayed 60 of 90; ask for +60 more. Only 30 remains, so the
      // result is baseline (23:30) + remaining 30 = 00:00.
      final d = check(
        field: 'lockdown',
        hour: 0,
        minute: 30, // +60 from baseline
        budget:
            const NightlyAiBudget(editsUsed: 1, cumulativeLockdownDelayMin: 60),
      );
      expect(d.outcome, GuardrailOutcome.clamped);
      expect(d.applied.lockdown, const ScheduleTime(0, 0)); // baseline +30
    });

    test('rejects further delay once the cap is fully spent', () {
      final d = check(
        field: 'lockdown',
        hour: 0,
        minute: 15,
        budget:
            const NightlyAiBudget(editsUsed: 2, cumulativeLockdownDelayMin: 90),
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });

    test('pulling lockdown EARLIER is never blocked by the delay cap', () {
      // 23:15 is -15 from baseline 23:30 and still after windDown 23:00.
      final d = check(
        field: 'lockdown',
        hour: 23,
        minute: 15,
        budget:
            const NightlyAiBudget(editsUsed: 1, cumulativeLockdownDelayMin: 90),
      );
      expect(d.outcome, GuardrailOutcome.granted);
      expect(d.applied.lockdown, const ScheduleTime(23, 15));
    });
  });

  group('max 3 edits / night', () {
    test('rejects a 4th edit', () {
      final d = check(
        field: 'unlock',
        hour: 6,
        minute: 30,
        budget: const NightlyAiBudget(editsUsed: 3),
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });
  });

  group('no AI edit to lockdown while active', () {
    test('rejects a lockdown change once lockdown is active', () {
      final d = check(
        field: 'lockdown',
        hour: 0,
        minute: 0,
        lockdownActive: true,
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });

    test('still allows a non-lockdown field while active (unlock)', () {
      final d = check(
        field: 'unlock',
        hour: 6,
        minute: 30,
        lockdownActive: true,
      );
      expect(d.outcome, GuardrailOutcome.granted);
    });
  });

  group('ordering violation', () {
    test('rejects a windDown that would land before wakeUp', () {
      // baseline wake 22:30; move windDown to 22:00 (-60, within ±60) but that
      // violates wakeUp <= windDown ordering.
      final d = check(field: 'windDown', hour: 22, minute: 0);
      expect(d.outcome, GuardrailOutcome.rejected);
    });
  });

  group('malformed input', () {
    test('rejects an impossible time', () {
      final d = check(field: 'lockdown', hour: 25, minute: 0);
      expect(d.outcome, GuardrailOutcome.rejected);
    });
  });

  group('H2: wakeUp / windDown hard envelopes', () {
    test('rejects wakeUp earlier than the 20:00 floor', () {
      // baseline wake 22:30; the ±60 clamp runs first, so use a baseline near
      // the floor: 20:30, then ask 19:30 (-60) which lands below 20:00.
      final earlyBaseline = SleepSchedule.defaults.copyWith(
        wakeUp: const ScheduleTime(20, 30),
      );
      final d = ScheduleGuardrails.evaluate(
        baseline: earlyBaseline,
        current: earlyBaseline,
        field: 'wakeUp',
        hour: 19,
        minute: 30,
        scope: ScheduleScope.tonight,
        budget: noBudget,
        lockdownActive: false,
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });

    test('rejects windDown later than the 00:30 ceiling', () {
      // baseline windDown 23:00; near the ceiling at 00:00, ask 01:00 (+60),
      // past the 00:30 edge.
      final lateBaseline = SleepSchedule.defaults.copyWith(
        windDown: const ScheduleTime(0, 0),
        lockdown: const ScheduleTime(0, 30),
      );
      final d = ScheduleGuardrails.evaluate(
        baseline: lateBaseline,
        current: lateBaseline,
        field: 'windDown',
        hour: 1,
        minute: 0,
        scope: ScheduleScope.tonight,
        budget: noBudget,
        lockdownActive: false,
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });

    test('permanent wakeUp edit is still envelope-clamped via ±60', () {
      // A permanent-scope edit gets the same per-nudge clamp + envelope checks;
      // asking wakeUp 19:00 (-210) clamps to 21:30 (-60), inside the envelope.
      final d = check(
        field: 'wakeUp',
        hour: 19,
        minute: 0,
        scope: ScheduleScope.permanent,
      );
      expect(d.outcome, GuardrailOutcome.clamped);
      expect(d.applied.wakeUp, const ScheduleTime(21, 30));
    });
  });

  group('H2: cumulative wakeUp / windDown drift cap', () {
    test('clamps wakeUp drift to whatever budget remains', () {
      // Already drifted 70 of 90; ask for -60 more (22:30 -> 21:30). Only 20
      // remains, so the result is baseline (22:30) - 20 = 22:10.
      final d = check(
        field: 'wakeUp',
        hour: 21,
        minute: 30,
        budget:
            const NightlyAiBudget(editsUsed: 1, cumulativeWakeUpDriftMin: 70),
      );
      expect(d.outcome, GuardrailOutcome.clamped);
      expect(d.applied.wakeUp, const ScheduleTime(22, 10));
    });

    test('rejects further windDown drift once the cap is fully spent', () {
      final d = check(
        field: 'windDown',
        hour: 23,
        minute: 20,
        budget: const NightlyAiBudget(
            editsUsed: 2, cumulativeWindDownDriftMin: 90),
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });

    test('drift cap counts BOTH directions (later windDown also capped)', () {
      // Already drifted 90; asking for a +20 later windDown is still rejected.
      final d = check(
        field: 'windDown',
        hour: 23,
        minute: 20,
        budget: const NightlyAiBudget(
            editsUsed: 1, cumulativeWindDownDriftMin: 90),
      );
      expect(d.outcome, GuardrailOutcome.rejected);
    });
  });
}
