# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security-sensitive bugs.

Instead, report them privately to the maintainers with:
- affected platform
- reproduction steps
- impact
- possible fix if known

## Scope notes

Sleep Time provides best-effort enforcement, especially on Windows.
It is not a hardened anti-tamper or enterprise endpoint-security product.

Known boundaries:
- Windows protections can be bypassed by determined local admins.
- Windows secure attention paths such as Ctrl+Alt+Del are outside the control of a normal Flutter desktop app.
- Android protections depend on device-admin / lock-task support.
- API keys should be supplied by the user or the deployment environment, never hardcoded into source control.

For more detail, see `docs/WINDOWS_THREAT_MODEL.md`.
