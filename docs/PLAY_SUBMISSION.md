# Google Play submission notes — Sleep Time (Android)

This document is the source of truth for the Play Console review of Sleep Time.
It covers the sensitive permissions we declare, why each is needed, the
in-product disclosures, and the demo material reviewers will expect. Everything
here reflects the M4 (foreground service + alarms) and M5 (per-app selective
unlock + overlay + permission onboarding) work.

## One-line product description

A bedtime sleep-enforcement app. At a user-configured bedtime it shows a calm
full-screen lock over other apps; the user can negotiate short, time-limited
exceptions with an AI guardian. It is a Digital Wellbeing tool — not assistive
technology, not a device-admin/kiosk lockdown.

---

## Foreground service: `specialUse`

- **Type:** `FOREGROUND_SERVICE_SPECIAL_USE` (`SleepGuardianService`).
- **Why:** the guardian must keep the user's bedtime schedule alive while the app
  is backgrounded — re-deriving state on each alarm and posting the persistent
  notification. None of the predefined FGS types fit a "personal bedtime
  schedule enforcer".
- **Manifest declaration:** the nested
  `android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE` string is present and reads:
  *"Enforces a user-configured bedtime lock schedule while the app is
  backgrounded."*
- **Dismissability:** the persistent notification carries a "Turn off" action
  that stops the service (FGS dismissability policy).
- **Demo video to provide:** show the app enter bedtime, the persistent
  notification appearing, the lock overlay appearing over another app, and the
  "Turn off" action stopping it.

## Accessibility service (OPTIONAL)

- **Service:** `SleepAccessibilityService`.
- **Category framing:** **Digital Wellbeing** — NOT "disability assistance".
- **It is OPTIONAL.** The app is fully functional with this service disabled.
  UsageStats is the primary foreground-app detector; accessibility only feeds the
  same evaluation path a little faster. Android 17 Advanced Protection may
  silently revoke non-tool accessibility services, and the guardian is built to
  keep working when that happens.
- **Config (`res/xml/accessibility_service_config.xml`):**
  - `accessibilityEventTypes="typeWindowStateChanged"` only.
  - `canRetrieveWindowContent="false"` — never reads screen content.
  - `notificationTimeout="500"` debounce.
  - Observe-only: NO input injection, NO gesture dispatch, NO content reads.
  - **`isAccessibilityTool` is deliberately NOT set** (it is not assistive tech).
- **Prominent disclosure (MANDATORY, in-product):** before the user is ever sent
  to the system Accessibility settings, `PermissionsOnboardingScreen` shows a
  dialog ("Optional: faster bedtime lock") explaining what the helper does, that
  it only observes app switches, that it never reads/taps/types, that the app
  works fully without it, and that it can be turned off any time. The redirect
  only happens after the user taps "Continue".
- **Demo video to provide:** show the prominent-disclosure dialog appearing
  BEFORE the Accessibility settings, then the user enabling the service, then the
  app working. Also show the app working with accessibility OFF (UsageStats only).

## Prominent disclosure requirement (summary)

The Accessibility prominent disclosure is implemented in
`lib/ui/permissions_onboarding_screen.dart` (`_showAccessibilityDisclosure`). It
runs strictly before `AndroidLockdown.requestAccessibility()`. Reviewers can
trigger it from onboarding or from Settings → Android → Permissions → Faster lock
→ Grant.

---

## Sensitive / notable permissions and justifications

| Permission | Why we need it | Notes |
|---|---|---|
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE` | Keep the bedtime guardian alive in the background. | specialUse subtype declared. |
| `PACKAGE_USAGE_STATS` | **PRIMARY** foreground-app detector: decide whether the app in front is allowed during lockdown. | User-granted from Usage Access settings; `tools:ignore="ProtectedPermissions"`. Never auto-granted. |
| `SYSTEM_ALERT_WINDOW` | Draw the `TYPE_APPLICATION_OVERLAY` bedtime lock / countdown banner over other apps. | Falls back to bringing our activity to the front if the overlay is hidden/refused. |
| `BIND_ACCESSIBILITY_SERVICE` | OPTIONAL latency enhancement (see above). | Digital Wellbeing; observe-only; prominent disclosure precedes redirect; app works without it. |
| `SCHEDULE_EXACT_ALARM` | Fire wind-down / lock / unlock at the exact configured times. | Guarded by `canScheduleExactAlarms()`; degrades to inexact (idle-resilient) alarms when not granted. We do NOT request the auto-granted `USE_EXACT_ALARM`. |
| `POST_NOTIFICATIONS` | Persistent guardian notification + bedtime reminders. | Android 13+ runtime prompt. |
| `RECEIVE_BOOT_COMPLETED` | Re-arm bedtime alarms after a reboot (via WorkManager, not a direct FGS start). | |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Keep overnight alarms reliable on aggressive OEM battery managers. | Optional; requested via the system dialog, never auto-applied. |
| `WAKE_LOCK` | Hold a screen wake lock ONLY while the lock overlay is visible. | Released as soon as the overlay is hidden. |

**Not requested (deliberately):**
- `QUERY_ALL_PACKAGES` — the app catalog uses `getInstalledApplications(0)` and
  filters to launchable apps; no broad package-visibility grant is needed.
- Device Admin / `lockTask` / screen-pinning — removed entirely; Play-incompatible.

---

## Data safety

- **App usage data (which app is in front):** collected locally via UsageStats /
  the optional accessibility helper. Used only on-device to decide what to block
  during the bedtime window. **Not transmitted off the device.**
- **Allow-list / negotiable-apps selection:** stored locally
  (SharedPreferences). Not transmitted.
- **Chat messages (negotiation):** the text the user types to negotiate, plus the
  necessary context, is sent to the configured AI provider — **Anthropic**
  (Claude) or **Google Gemini** — to generate the guardian's reply. Users supply
  their own API key (BYOK) or use a bundled Concierge key. This must be disclosed
  in Data Safety as "messages sent to a third-party AI provider".
- **No ads, no analytics SDKs, no advertising ID.**
- **Encryption in transit:** AI calls are HTTPS.

---

## Reviewer walkthrough checklist

1. First run → onboarding lists permissions; hard gates (overlay, usage access,
   exact alarm) block "Done" until granted; battery + accessibility never block.
2. Trigger bedtime (or use safe-mode in dev) → lock overlay appears over a
   foreground app; "Open Sleep Time" brings the negotiation UI forward.
3. Negotiate a per-app unlock for an app on the user-approved list → the app is
   freed for N minutes with a countdown banner; re-blocks on expiry.
4. Confirm the app still locks correctly with the Accessibility helper DISABLED.
5. Confirm the Accessibility prominent disclosure shows BEFORE the settings
   redirect.
