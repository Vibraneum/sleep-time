# Windows Threat Model

## Plain-English positioning

Sleep Time on Windows is currently a **friction app**, not a hardened kiosk product.

That means:
- it is designed to make it annoying and inconvenient to keep using the computer at night
- it is **not** designed to defeat a determined admin or a highly technical attacker

## What "friction app" means

A friction app is appropriate when the user wants help enforcing their own boundary.

Examples:
- staying off the PC after 11:30 PM
- forcing a deliberate negotiation before using the machine again
- reducing impulsive late-night browsing or gaming

A friction app works by adding meaningful resistance, not by promising impossible security.

## What a kiosk-style product would mean

A kiosk-style product is much more locked down and operationally heavy.
That usually involves:
- admin privileges or managed-device policy
- login/session restrictions
- startup watchdogs
- dedicated shell replacement or MSIX / assigned-access flows
- code signing and managed deployment expectations

That is a very different product category.

## Current Sleep Time protections

Sleep Time currently tries to:
- show a fullscreen always-on-top app
- block ordinary close behavior
- hide taskbar/shell affordances
- refocus itself repeatedly
- best-effort change a few registry policies
- best-effort stop Explorer in release mode during active lockdown
- restore the desktop when the lockdown ends or the app next starts

## What it does not protect against

Sleep Time does not claim to fully stop:
- `Ctrl+Alt+Del`
- local admin bypass
- safe mode / recovery mode workarounds
- external policy editors or privileged tools
- someone intentionally killing or modifying the app with elevated privileges

## Why this matters

If we overstate the product, users will assume guarantees Windows desktop apps cannot honestly provide.

The correct promise today is:
- **good self-control support for normal use**
- **not anti-tamper security**

## Product direction recommendation

For now, Sleep Time should stay in the friction-app category and clearly document that.
That gives us a coherent product story without promising impossible Windows guarantees.

If the project later wants stronger enforcement, that should be treated as a separate roadmap track with its own architecture and threat model.
