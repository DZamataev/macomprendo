# Middle mouse action

## Goal

Let a user bind the middle mouse button to one of Macomprendo’s five existing actions without assigning an additional keyboard shortcut.

## Behaviour

- Settings ▸ Hotkeys splits keyboard and mouse controls. The Mouse section has the toggle and an
  action picker with Dictate, Dictate & Refine, Speak selection, Summarize selection, and Refine
  selection. Keyboard and middle mouse each retain their own persisted Hold/Toggle setting.
- The default is disabled. Enabling selects Dictate; disabling clears the selected action. The mouse
  mode defaults to Hold, including for existing settings documents.
- The selected action is persisted in `Settings`; older settings documents decode with the feature disabled.
- A global/local AppKit mouse monitor emits middle-button down and up events while enabled. AppModel maps them to the existing hotkey routing path and reads the selected action at event time.
- Dictate and Dictate & Refine keep their established mode semantics: hold records while the button is held; toggle starts/stops on consecutive presses. The three selection actions run on button down and ignore button up.
- The monitor is an OS-facing protocol with a fake; no new permissions or network traffic are introduced.

## Acceptance

- A persisted action survives relaunch; a legacy document leaves it off.
- An enabled fake monitor routes middle-button down/up to the selected existing action; changing the setting immediately enables/disables the monitor.
- The Hotkeys UI displays the toggle and all five action choices.
- Manual smoke coverage verifies the live monitor with Dictate in Hold and Toggle modes and a selection action.
