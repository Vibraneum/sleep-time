# Project review

## Product understanding

This project is aiming to be a bedtime-enforcement app with a strong personality layer:
- warning before bedtime
- hard lockdown during the night
- short exception handling through negotiation
- local memory/compliance tracking

## Critical findings

1. **Secrets exposure risk**
   - A local `.env` file exists with live-looking API credentials.
   - It is ignored by Git, which is good.
   - Those credentials should still be rotated if they were ever shared outside your machine.

2. **UI bug fixed**
   - `lib/ui/home_screen.dart` overflowed in tests and smaller windows.
   - Fixed by making the page scrollable.

3. **Lockdown integration bug fixed**
   - Platform lockdown implementations existed but were not wired to scheduler state.
   - Now the scheduler triggers Windows/Android lockdown activation and release.

4. **Missing API-key UX fixed**
   - Negotiation failed unclearly when Gemini was unset.
   - It now returns a direct settings message instead of crashing into a generic error path.

5. **Sleep logging bug fixed**
   - Nightly sleep logging existed but was never triggered.
   - Scheduler now logs the night once when returning to unlocked state.

6. **Time display bug fixed**
   - Unlock time text hardcoded `AM`.
   - Replaced with proper 12-hour formatting.

## Workflow review

### What was missing
- no git repository initialized locally
- no CI workflow
- placeholder README with no product guidance

### What was added
- local git initialization
- GitHub remote configured to `https://github.com/Vibraneum/sleep-time.git`
- GitHub Actions workflow for analyze + test
- product-focused README

## Remaining concerns

1. **Platform lockdown is not tamper-proof**
   - Windows registry/task-manager blocking is best effort only.
   - Users can still bypass determined enforcement.

2. **Poke API is assumed, not validated**
   - Endpoint and auth flow may need real integration testing.

3. **No migration strategy yet**
   - `sqflite` schema is simple and currently versioned at 1.
   - Future schema changes will need migrations.

4. **Limited test coverage**
   - There is now a passing widget path, but core scheduling logic deserves more direct unit tests.

## Recommended next steps

- add unit tests for schedule edge cases around midnight
- add integration tests for lockdown/grant transitions
- verify Poke API against a real sandbox
- define a release checklist for Android device-admin behavior and Windows kiosk expectations
