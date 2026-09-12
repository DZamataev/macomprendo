# ADR-0003: The app is not sandboxed and ships outside the Mac App Store

## Status

Accepted — 2026-08-23

## Context

The four core features need capabilities the App Sandbox does not grant: system-wide hotkeys that
fire while another app is frontmost, reading the focused element's selected text through the
Accessibility API, synthesising ⌘C/⌘V with `CGEvent`, and re-activating an arbitrary application to
paste into it. Apple provides no sandbox entitlement combination that covers AX reading of other
processes plus global event synthesis.

## Decision

Macomprendo is built without App Sandbox, with the hardened runtime enabled, signed with a
Developer ID Application certificate, notarized, stapled, and distributed as a ZIP from GitHub
Releases. It requests Microphone and Accessibility permission explicitly during onboarding and
checks both before each action.

## Consequences

- Mac App Store distribution is off the table for as long as these features exist.
- Release engineering owns signing and notarization; `scripts/notarize-app.mjs` performs the whole
  chain and `spctl --assess` gates the artifact.
- Users must grant Accessibility in System Settings; the app deep-links to the right pane and
  degrades to copy-only with a toast when permission is missing.
- The absence of a sandbox raises the bar on the privacy promises: no telemetry, secrets only in the
  Keychain, and no network call the user has not configured.
