# Dictation trailing space

## Goal

Let the user choose whether direct dictated text is followed by one space when inserted into the target application.

## Behaviour

- Settings ▸ General shows `Add a space after dictated text`.
- It defaults to off; older settings documents also decode it as off.
- When enabled, direct Dictate and the original-text insertion from Dictate & Refine append exactly one ASCII space after the accepted transcript.
- Stored history transcripts and refined text remain unchanged.

## Acceptance

- The setting survives a Settings JSON round-trip and old documents use the off default.
- A Dictate or original Dictate & Refine insertion ends in a single space only when the setting is enabled.
- The General tab exposes the state-driven toggle.
