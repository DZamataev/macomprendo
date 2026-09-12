# ADR-0006: The Quick Panel appears at a fixed top-centre position

## Status

Accepted — 2026-08-23

## Context

The Quick Panel shows dictated/refined text and summaries. It could follow the text caret, follow
the mouse, or sit in a fixed place. Caret-following requires AX bounds that many apps report badly
or not at all; mouse-following makes the panel land somewhere different every time and fights the
user's reading position.

## Decision

The Quick Panel is a non-activating floating `NSPanel`, 680×420, pinned to the top-centre of the
screen that currently contains the mouse. Its frame is remembered per screen in
`Settings.quickPanelFrames`, keyed by screen identifier, so a user who drags it keeps that position.
Esc closes it; it stays open while streaming. The Recording HUD follows the same top-centre rule.

## Consequences

- The panel is where the user already looks, in the same place every time — the behaviour users know
  from MacWhisper and ChatGPT's quick chat.
- No dependence on per-app AX caret geometry, so behaviour is uniform across every application.
- Multi-display users get per-screen memory; the screen identifier must be stable across
  disconnect/reconnect, so `quickPanelFrames` keys are treated as best-effort with a top-centre
  fallback.
- The panel can overlap content the user is reading; Esc and the explicit close button are therefore
  always available and the panel never steals keyboard focus until clicked.
