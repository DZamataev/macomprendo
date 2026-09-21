# ADR-0012: Vocabulary packs are plain-text files, enabled by a separate config

## Status

Accepted — 2026-09-14. Amended 2026-09-17: the enabled state moved out of the pack file into
`packs.json`, and user-created packs were added.

## Context

Dictation mangles developer jargon: `auto-till-dry` comes back as `Auto-Tilt-Dry`, `TextEditor`
as `текст-эдитор`. The fix needs a glossary, and the glossary has an unusual second audience:
the user's coding agent, which should be able to read the format, understand it without our
documentation, and write a pack for the project it is working on.

Storing the glossary inside `Settings` (one JSON document) makes an agent patch a large shared
file to add a word, risking the keys around it. TOML and YAML carry comments but have no parser
in Foundation, so either would add a third-party dependency plus a `LicenseRegistry` entry for a
file that holds a list of words — and neither preserves comments when the app writes the file
back after an edit. One combined file with section headers was considered and rejected: it makes
per-pack factory reseeding and per-pack reset impossible without editing inside another pack's
text.

The enabled state was first put inside each pack file as an `# enabled:` comment, so that
dropping a file in the directory would be a single step. That was rejected on review: it makes a
file both content and configuration, so the app must rewrite a user's file to flip a checkbox,
and there is no single place to see what is on. An agent capable of writing a pack is capable of
reading a README and adding one line to a config.

## Decision

One pack per file, in `~/Library/Application Support/Macomprendo/Vocabulary/*.txt`. The format is
line-based: one entry per line, `#` starts a comment, blank lines are ignored. The file name is
the pack name. A line may carry Cyrillic forms after `=`:

```
# pack: typescript
# Terms the recogniser gets wrong. One per line; `term = cyrillic, forms` adds replacements.

jq
nvm
TextEditor = текст-эдитор, текстэдитор
```

A bare term feeds normalisation and decode-time biasing. A term with an `=` also carries
replacement forms. Lines end with `\n`: a pack is a Unix text file, because stripping `\r`
would break the byte-identical round-trip the in-app editor depends on.

**Enabled state lives in `packs.json`, beside the packs**, and lists what is on:

```json
{ "enabled": ["typescript", "python"] }
```

A pack not named there is off, including a newly dropped file. The app rewrites only this file
when a checkbox changes; it never writes a pack file except on Reset or through the editor.

Packs are created by the user as well as shipped: a New pack button writes a named file with a
documenting header, Duplicate copies an existing one. A pack is **factory** when a file of the
same name exists in the bundle — that fact is derived, never stored. Factory packs get Reset and
cannot be deleted (only disabled, since seeding would bring them back); user packs get Delete and
no Reset.

A `README.md` is seeded into the directory alongside the packs, describing both file formats, so
an agent that opens the directory needs nothing else.

## Consequences

- The file format is a user-facing and agent-facing contract. Changing it later breaks packs
  that live in users' project repositories.
- Dropping a pack file is two steps: write the file, add its name to `packs.json`. This is
  deliberate — nothing the user did not ask for becomes active.
- Editing in-app is a plain `TextEditor` over the file's text, so comments and ordering survive a
  round-trip by construction.
- `packs.json` can name a pack that no longer exists; that entry is ignored, not an error, so
  deleting a file never requires editing the config.
- The directory is read at launch and when the Settings window opens, plus an explicit Reload
  button. A file changed while the app runs is not picked up until then.
- The bundled factory packs and the README are a new resource directory, so invariant 17 applies:
  declare them in `macos/Package.swift` *and* in `macos/project.yml`.
