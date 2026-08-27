# ADR-0005: Phosphor Icons in-app, SF Symbols for the menubar item

## Status

Accepted — 2026-08-23. **The packaging half is superseded by ADR-0008**: Phosphor is vendored as
SVGs from `@phosphor-icons/core`, and the `phosphor-icons/swift` SwiftPM package is *not* used.
Only the choice of icon set and the SF-Symbol-only rule for the status item still stand.

## Context

The UI needs a consistent icon set with multiple weights across the Quick Panel, HUD, settings tabs
and onboarding. SF Symbols is the platform default but its licence restricts use to Apple platform
UI and its coverage of the specific glyphs this app wants (waveform states, preset kinds, endpoint
kinds) is uneven. Separately, a menubar status item must supply a *template* image so macOS can tint
it for light, dark and menu-bar-highlight states.

## Decision

Use `phosphor-icons/swift` (MIT, six weights) through a single `UI/Components/Icon.swift` wrapper for
all in-app iconography. Use an SF Symbol template image for the `MenuBarExtra` status item only.

## Consequences

- Icon usage funnels through one wrapper, so weight and size conventions stay consistent and the set
  can be swapped in one place.
- Two icon sources coexist; the rule "SF Symbol only for the status item" must be stated in
  `AGENTS.md` so it is not eroded.
- Phosphor adds a small binary size cost; it is MIT-licensed, so redistribution inside the app is
  unencumbered.
- The *delivery mechanism* for Phosphor changed during implementation; see ADR-0008. This ADR's
  choice of icon set and the SF-Symbol-only rule for the status item are unaffected.
