# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`AGENTS.md`** at the repo root: this repo's vocabulary and invariants live there, not in a
  separate `CONTEXT.md`. It is the source of truth for agent instructions; `CLAUDE.md` is a
  symlink to it, and it is a protected file — propose edits, never write it unattended.
- **`CONTEXT.md`** at the repo root, if one is ever created for pure glossary terms.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in. Files are named
  `NNNN-<slug>.md` (zero-padded, e.g. `0011-saved-dictation-audio.md`), and their headings
  still read `# ADR-00NN: …`.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

This repo is **single-context**:

```
/
├── AGENTS.md                          ← vocabulary, invariants, definition of done
├── docs/
│   ├── adr/
│   │   ├── 0001-llm-through-endpoints.md
│   │   └── 0011-saved-dictation-audio.md
│   └── superpowers/{specs,plans}/     ← specs and implementation plans
└── macos/Sources/Macomprendo/
```

Specs live in `docs/superpowers/specs/YYYY-MM-DD-<name>.md` and plans in
`docs/superpowers/plans/YYYY-MM-DD-NN-<name>.md`. Write the spec, then the plan, then the
code, and update the spec rather than letting the code drift away from it.

A multi-context layout (`CONTEXT-MAP.md` + per-context `CONTEXT.md`) does not apply here:
this is a single Swift app with one Node tooling directory.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `AGENTS.md` (its project map, invariants, and the feature specs it points at). Don't drift to synonyms the project explicitly avoids.

If the concept you need isn't named anywhere yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0003 (not sandboxed), but worth reopening because…_
