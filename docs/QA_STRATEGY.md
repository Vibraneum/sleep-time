# QA strategy

How Sleep Time is tested, and how to test the dangerous parts without locking
yourself out.

## The golden rule: never QA real enforcement on your primary machine

Sleep Time can take over your screen (Windows) or block your apps (Android).

- All development runs default to **safe mode** (`AppConfig.simulateLockdown`,
  defaults to `kDebugMode`). In safe mode the full lock → negotiate → grant →
  unlock UI flows end-to-end with **zero** platform side effects: no fullscreen,
  no always-on-top, no keyboard hook, no watchdog (Windows), no overlay/FGS
  escalation (Android). Exercise every flow here first.
- To test **real** enforcement, flip safe mode off **only** on a throwaway
  Windows user account / VM, or a spare Android device — never your primary
  session. The Windows watchdog is hard-coded to never spawn while simulating.

## Test pyramid

### Unit (the load-bearing logic — fast, hermetic, run on every change)
- `schedule_test.dart` — `SleepSchedule.validate()` incl. the wrap-aware
  cross-midnight arc (`scheduleArcIsCoherent`), ranges, copyWith, (de)serialize.
- `schedule_guardrails_test.dart` — envelopes (lockdown/unlock/windDown/wakeUp),
  ±60 nudge clamp, cumulative caps, max-3-edits, no-edit-while-active, the
  "can't push past the envelope via repeated asks" proof.
- `schedule_store_test.dart` / `schedule_audit_test.dart` — `apply` granted vs
  rejected, baseline handling, `revertTonightNudges`, structured audit logging,
  regex-free budget recovery.
- `guardian_tools_test.dart` — `guardianDecisionFromToolUse` for every tool/action,
  clamping, deny/unknown/missing-message fallbacks.
- `anthropic_request_test.dart` — request body shape (tools present,
  `tool_choice:any`, `disable_parallel_tool_use`, cache_control on last system +
  last tool, constant tool_choice) and the tool_result-FIRST history invariant.
- `lockdown_scheduler_test.dart` — selective vs full grant, no `_permanentlyUnlocked`
  on selective, reentrancy guard.
- `windows_lockdown_test.dart` / `windows_unlock_gating_test.dart` — lock.json
  round-trip, image-name matching, and the approved-app gate on `unlock_app`.
- `overlay_size_test.dart`, `guardian_copy_test.dart`, `permission_gating_test.dart`,
  `negotiable_apps_test.dart`, `android_lockdown_test.dart`.

### Widget / golden
- Lockdown overlay (full/banner/mini) and granted views (full + per-app) in both
  safe and real mode; the negotiation chat (greeting, deny-then-retry, the
  grant/unlock/schedule action chips, mounted-check before delayed dispatch);
  onboarding gating.

### Integration / device (manual until automated with Patrol)
- **Android matrix** (real device, not emulator): boot recovery restart;
  Doze via `adb shell dumpsys deviceidle force-idle` (alarm still fires); overlay
  over a third-party app; service kill-and-restart; Samsung/Xiaomi/OnePlus battery
  killers; **app still works with Accessibility disabled** (UsageStats-only);
  Battery Historian target < ~1%/hr for the FGS.
- **Windows matrix** (throwaway account, safe mode OFF): kill `sleep_time.exe` →
  watchdog relaunch (~seconds); kill the watchdog → app respawns; ~0% idle CPU
  while locked (proves event-driven, not polling); selective allow (approved app
  holds foreground, others snapped away, HUD counts down, re-lock on expiry);
  reboot-while-locked returns at login.

## CI gate
`flutter analyze` clean + the full `flutter test` suite green on every PR before
merge. Builds (`flutter build windows --release`, `flutter build apk`) run before
a release; device matrices are run manually pre-release.

## Reviewing changes
Author and review are separate passes — never self-approve a change in the same
session. A full-branch review caught a critical cross-midnight schedule bug and
two safety-relevant unlock/guardrail gaps that per-file checks missed; budget a
review pass for anything touching the engine, scheduler/store, or native layers.
