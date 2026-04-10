# Windows Packaging and Signing

## Current packaging

The project currently supports:
- portable Windows release build (`flutter build windows --release`)
- Inno Setup installer generation through the manual release workflow

## Why signing matters

Unsigned Windows apps and installers trigger more SmartScreen friction and lower user trust.
For a desktop app, code signing is one of the highest-value release improvements.

## Recommended next steps

### 1. Obtain a code-signing certificate

Options usually include:
- OV code-signing certificate
- EV code-signing certificate

EV generally gives stronger SmartScreen reputation benefits, but costs more and is more operationally strict.

### 2. Sign both artifacts

Sign:
- `sleep_time.exe`
- the generated installer `.exe`

### 3. Store signing secrets outside the repo

Use:
- GitHub Actions secrets
- secure certificate storage
- password-protected PFX handling

Never commit certificates or signing passwords.

### 4. Add verification to release steps

After signing, verify signatures in CI before publishing the release.

## Suggested release posture

Short term:
- keep manual releases
- ship installer + portable zip
- document Windows limitations clearly

Medium term:
- add signing
- add checksum publishing
- add release notes for known Windows behavior boundaries
