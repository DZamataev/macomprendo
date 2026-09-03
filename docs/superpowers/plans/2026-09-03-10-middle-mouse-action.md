# Middle mouse action plan

1. Add the optional persisted action and independent mouse mode to `Settings`, defaulting absent
   values to disabled and Hold respectively; cover default, legacy decode and round-trip with
   failing tests.
2. Introduce an AppKit middle-mouse monitoring protocol and implementation next to its fake. It emits down/up values from global and local monitors only while enabled.
3. Add the monitor at the `AppEnvironment` composition root. In `AppModel`, keep one stream
   consumer, enable it from the persisted action, and route emitted values as existing `HotkeyEvent`s
   with the independent middle-mouse mode.
4. Add a narrow failing AppModel test proving a selected middle button action routes Dictate’s down/up path and that disabled settings stop the monitor.
5. Add the state-driven Hotkeys controls, documentation, changelog entry, and hardware smoke steps. Run focused tests, complete Swift/Node suites, build, generate and package.
