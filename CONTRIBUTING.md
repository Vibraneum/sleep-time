# Contributing

Thanks for contributing to Sleep Time.

## Local development

```bash
flutter pub get
flutter analyze
flutter test
```

## Branching

- `main` is the primary integration branch
- use short-lived feature or fix branches

## Pull requests

Please:
- keep PRs focused
- update tests when behavior changes
- update docs when setup or workflows change
- use labels when possible: `feature`, `fix`, `docs`, `ci`, `refactor`, `breaking`

Those labels improve draft release notes.

## Manual releases

Releases are intentionally manual.

### Recommended flow

1. Merge approved changes into `main`
2. Update `CHANGELOG.md`
3. Run the GitHub Actions **Manual Release** workflow
4. Enter a semantic version like `0.1.0`
5. Let the workflow create the tag and publish the release artifact

## Provider support

Please preserve support for:
- Concierge Gemini default key flow
- user BYOK flow
- Gemini provider
- Anthropic provider

## Security

Never commit real API keys or secrets.
Review `SECURITY.md` before reporting vulnerabilities.

## Windows behavior

Before changing Windows enforcement, read:
- `CURRENT_STATE.md`
- `docs/WINDOWS_THREAT_MODEL.md`
- `docs/WINDOWS_PACKAGING_AND_SIGNING.md`
