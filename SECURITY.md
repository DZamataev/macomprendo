# Security policy

## Reporting a vulnerability

Report privately — never in a public issue.

1. **Preferred:** [GitHub private vulnerability reporting](https://github.com/DZamataev/macomprendo/security/advisories/new).
   The report stays inside GitHub and only the maintainer can read it.
2. **Fallback:** email **dz_app_support** at **icloud.com**.

Include the app version (About Macomprendo…), your macOS version, and the steps that reproduce
the problem. Do not include real API keys or private dictation text; a description of where
they leak is enough.

## Scope

In scope is the app built from this repository and the release ZIPs published on
[GitHub Releases](https://github.com/DZamataev/macomprendo/releases), in particular:

- reading the selected text of other applications through Accessibility, and the simulated
  ⌘C/⌘V used to copy and paste it, including restoring the clipboard afterwards;
- API keys, which must stay in the Keychain and never reach settings, logs, exports or error
  text;
- dictation history, saved recordings and glossary files stored under
  `~/Library/Application Support/Macomprendo/`;
- any network request other than the endpoints you configured and the model downloads you
  started;
- verification of downloaded models against their pinned checksums;
- the signing and notarization of release builds.

Out of scope: the third-party services you connect the app to (Ollama, OpenAI-compatible
endpoints), the downloadable models themselves, and attacks that already require running code
under your macOS account — the app is not sandboxed and does not defend against that
(`docs/adr/0003-not-sandboxed.md`).

## What to expect

Macomprendo is maintained by one person in their own time. Every report is read and answered,
but no response or fix time is promised. A confirmed vulnerability is fixed in a new release.
