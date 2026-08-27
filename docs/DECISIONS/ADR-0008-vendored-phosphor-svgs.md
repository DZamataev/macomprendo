# ADR-0008: Phosphor icons are vendored as SVGs, not consumed as a Swift package

## Status

Accepted — 2026-08-23 (supersedes the packaging half of ADR-0005)

## Context

ADR-0005 chose Phosphor Icons for in-app iconography. The natural delivery mechanism,
`phosphor-icons/swift`, turned out to be unusable here: the package does not build under plain
`swift build`, which this project depends on for tests, per-architecture release builds, and CI.
Only the glyphs themselves are needed — a few dozen out of roughly 9,000 — so pulling in a whole
Swift package was disproportionate anyway.

## Decision

The icon source is the upstream asset package `@phosphor-icons/core`, added as an npm
**devDependency**. `scripts/sync-icons.mjs` copies the specific SVGs the UI uses into the app
target's resources, where `UI/Components/Icon.swift` renders them. The vendored SVGs are committed,
so neither a build nor CI ever needs npm to produce the app.

## Consequences

- `swift build` has no third-party icon dependency; the icon set is plain resource data.
- The icons ship inside `Macomprendo_Macomprendo.bundle`, SwiftPM's resource bundle for the app
  target, which `scripts/build-app.mjs` copies into `Contents/Resources`. If that bundle is missing
  from a build, the icons are missing from the app — the build script warns when it finds none.
- Adding a new icon is a two-step action: add its name to the sync list and run
  `npm run sync-icons`, then commit the SVG. This is documented in `AGENTS.md`.
- Vendored SVGs are committed assets, so `npm run audit` must not treat them as suspicious; they
  are excluded from the machine-path content scan like other binary assets.
- Only the delivery mechanism changes; ADR-0005's decisions — Phosphor for in-app icons, an SF
  Symbol template image for the menubar status item — stand.
