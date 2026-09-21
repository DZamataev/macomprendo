# Vocabulary

This directory is Macomprendo's glossary. Every `.txt` file here is a **pack**: a list of
terms in the spelling you want pasted. After a dictation, Macomprendo rewrites any term it
recognises into that spelling — `NVM` becomes `nvm`, `Xcode build` becomes `xcodebuild`,
`Safe Area View` becomes `SafeAreaView`.

Two files decide what happens: the pack files, and `packs.json`.

**The one thing that surprises everybody: a pack is OFF until its name is listed in
`packs.json`.** Dropping a new `.txt` file into this directory does nothing on its own. If
you are an agent writing a pack for someone, write the file *and* add its name to
`packs.json`, or your work has no effect.

## Pack files

One pack per file. The file name without `.txt` is the pack name, so `go.txt` is the pack
`go`.

```
# pack: go
# Go tooling the recogniser gets wrong.

gofmt
golangci-lint
go mod tidy
go.mod
TextEditor = текст-эдитор, текстэдитор
```

The rules, in full:

- **One term per line**, written the way you want it pasted. That spelling is the
  *canonical* one: `auto-till-dry`, not `Auto-Till-Dry`.
- **`#` starts a comment.** A line whose first non-space character is `#` is ignored. Use
  comments to say what the pack is for — the next reader may be a person or an agent.
- **Blank lines are ignored.**
- **Surrounding whitespace is trimmed, interior whitespace is not.** `  go.mod  ` is the
  term `go.mod`; `git rebase` is one two-word term, not two terms.
- **`term = форма, форма` adds Cyrillic forms** for the same term, comma-separated. The
  app parses and stores them today; rewriting from them is a later feature, so listing
  them costs nothing and prepares for it.
- **A duplicate term keeps its first occurrence.** The second line is dropped silently.
- **A malformed line is skipped, not fatal.** A line with an `=` and an empty side —
  `= текст` or `TextEditor =` — is dropped and counted; the rest of the pack still works.
  Settings shows the skipped count, so a pack that is not doing what you think is visible.
- **Lines end with `\n`.** These are Unix text files. A CRLF file leaves a carriage return
  on the end of every term, and the term then never matches anything. If you generate a
  pack, generate it with `\n`.

A pack file you edit is written back **byte for byte** — comments, blank lines, order and
odd spacing all survive. The app only ever rewrites a pack file when you save it in the
editor or press Reset on a factory pack.

### What belongs in a pack

Only terms the recogniser plausibly gets **wrong**. The factory packs were filtered that
way, and they are short on purpose:

- worth listing: short commands that come back capitalised (`nvm`, `tsc`, `uv`, `rg`),
  compound names that come back split (`xcodebuild`, `SafeAreaView`, `MainMenu.tscn`),
  hyphenated names that come back title-cased (`auto-till-dry`).
- not worth listing: anything the model already writes correctly — `TypeScript`, `React`,
  `SwiftUI`, `UIKit`, `git rebase`. Listing them changes no output.
- not worth listing: identifiers nobody says out loud, such as `golang.org/x/crypto` or
  `Input.parse_input_event`.

Matching ignores case, spaces, hyphens, underscores and dots, and looks at windows of one
to four words — so a term longer than four words can never match anything.

## `packs.json`

Beside the packs, `packs.json` names which packs are on:

```json
{ "enabled": ["typescript", "react-native"] }
```

- A pack **not** named there is off, including a file you just dropped in.
- **Order matters.** When two packs hold terms that differ only in case or separators
  (`react-native` and `React Native`), the one from the pack listed first wins; the loser
  is counted and reported in Settings. The list is never sorted for you.
- A name with **no matching file is ignored**, not an error. Deleting a pack never
  requires editing this file, and putting the pack back re-enables it.
- A **missing** `packs.json` means nothing is enabled. That is the state of a fresh
  install, and it is not a problem.
- An **empty or malformed** `packs.json` also means nothing is enabled, and Settings says
  so. Dictation keeps working either way.

Unlike a pack file, `packs.json` does **not** survive byte for byte. When the app rewrites
it — ticking a checkbox does — it is reformatted. A hand-compacted one-line config will
come back expanded. Nothing is lost, because JSON has no comments, but do not expect your
layout to stay.

## Factory packs and your own

The `.txt` files that arrived with the app are **factory** packs: `typescript`,
`react-native`, `python`, `go`, `ruby`, `godot`. They are copied here once, on first run,
and never overwritten afterwards — edit them freely. Reset in Settings puts one back to
the shipped text, and that is the only way new factory terms ever reach you.

A pack you create is a **user** pack, and can be deleted. A factory pack cannot: deleting
it would just bring it back at the next launch, so turn it off in `packs.json` instead.

Seeding enables nothing. A fresh install has every pack present and none of them on.
