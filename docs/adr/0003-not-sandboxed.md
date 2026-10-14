# ADR-0003: The app is not sandboxed and ships outside the Mac App Store

## Status

Accepted — 2026-08-23. Amended 2026-10-14: the Context's entitlement claim was unproven rather than
established, the `NSServices` path is recorded, and the decision is restated as the owner's scoping
choice, with the App Store door left open. See https://github.com/DZamataev/macomprendo/issues/14.

## Context

Four of the five hotkey actions need capabilities believed to be outside the App Sandbox: system-
wide hotkeys that fire while another app is frontmost, reading the focused element's selected text
through the Accessibility API, synthesising ⌘C/⌘V with `CGEvent`, and re-activating an arbitrary
application to paste into it.

This ADR originally claimed Apple provides no sandbox entitlement combination covering AX reading
of other processes plus global event synthesis. That claim is overstated. What the research
established (https://github.com/DZamataev/macomprendo/issues/16):

- Carbon global hotkeys work under the sandbox: `Color Picker`, sandboxed and App Store
  distributed, imports `RegisterEventHotKey`.
- AX client calls are not blocked by the sandbox as such. Sandboxed App Store apps here (`Hand
  Mirror`) import `AXUIElementCreateSystemWide`, `AXUIElementCopyElementAtPosition` and
  `AXUIElementGetPid` with `com.apple.security.app-sandbox` true, which suggests TCC consent, not
  the sandbox, is the real gate. No sampled app reads `AXSelectedText` from another process,
  though, so that case stays unproven.
- A sandbox-legal substitute for AX reads exists and was not mentioned here: `NSServices`, where
  the system hands the service the selection instead of the app reading it. `Pixelmator Pro`,
  sandboxed and App Store distributed, declares `NSServices` with `NSSendTypes` and an
  `openSelection` message; a service can also take a shortcut in System Settings. This rescues the
  three selection-driven actions without AX, at the cost of rewriting them.
- Against a sandboxed build: `CGEventPost` paste has first-hand reports of 2.4.5 rejections, and
  Apple DTS states temporary-exception entitlements are rarely approved on review.

## Decision

Macomprendo is built without App Sandbox, with the hardened runtime enabled, signed with a
Developer ID Application certificate, notarized, stapled, and distributed as a ZIP from GitHub
Releases. It requests Microphone and Accessibility permission during onboarding and checks both
before each action.

This is the owner's scoping choice, not a finding of impossibility. A sandboxed App Store build
would carry less functionality than the one already shipping — three of the five hotkey actions
would have to be rewritten onto `NSServices`, an approach not yet prototyped here, and insert-
by-paste has no proven sandbox path — for a benefit the owner does not want. The door stays open:
if those actions are ever rewritten onto `NSServices` and a sandboxed build is proven, the App
Store question can be reopened.

## Consequences

- Mac App Store distribution is not pursued for now, but is not foreclosed: reopening it means
  rewriting the selection-driven actions onto `NSServices` and proving AX reads or `CGEventPost`
  paste under the sandbox, not rediscovering an entitlement.
- Release engineering owns signing and notarization; `scripts/notarize-app.mjs` performs the whole
  chain and `spctl --assess` gates the artifact.
- Users must grant Accessibility in System Settings; the app deep-links to the right pane and
  degrades to copy-only with a toast when permission is missing.
- The absence of a sandbox raises the bar on the privacy promises: no telemetry, secrets only in
  the Keychain, and no network call the user has not configured.
- The App Store research outlives the decision
  (https://github.com/DZamataev/macomprendo/issues/17): `PrivacyInfo.xcprivacy`
  (`NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1`) attaches to required-reason API
  use, not to any store; an in-app route to the privacy policy is good practice regardless; and
  every nested executable and dylib must be signed inside-out with a valid identifier, never with
  `codesign --deep`.
