# ADR-0004: Global hotkeys use the KeyboardShortcuts package

## Status

Accepted — 2026-08-23

## Context

Five user-rebindable global hotkeys are needed, one of which (`dictate`) must distinguish key-down
from key-up so hold-to-talk works. Hand-rolling this means Carbon `RegisterEventHotKey`, manual
modifier bookkeeping, a bespoke recorder control, conflict detection against system shortcuts, and
persistence — several hundred lines of fragile, untestable code.

## Decision

Use `sindresorhus/KeyboardShortcuts` (from 2.0.0). `KeyboardShortcutsHotkeyService` adapts it to the
app's `HotkeyServicing` protocol, publishing `HotkeyEvent.keyDown`/`.keyUp` on an `AsyncStream`.
`KeyboardShortcuts.Recorder` is used directly in the Hotkeys settings tab. Defaults: ⌥Space,
⌥⇧Space, ⌥S, ⌥M, and no default for `refineSelection`.

## Consequences

- Recorder UI, conflict handling and `UserDefaults` persistence come for free and stay consistent
  with other Mac apps.
- Hotkey storage lives in the library's own defaults keys, outside `Settings`; `Settings` therefore
  does not model key combinations.
- Controllers depend on `HotkeyServicing`, not the library, so their state machines are unit-tested
  with a fake that pushes synthetic events.
- One more third-party dependency to track; it is MIT-licensed and widely used.
