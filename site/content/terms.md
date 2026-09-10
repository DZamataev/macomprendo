---
title: Terms of Use
description: The terms under which Macomprendo is provided, and the three things the MIT licence does not cover.
output: terms/index.html
---

# Terms of Use

Macomprendo is provided by Denis Zamataev, an individual, free of charge.

## The licence

The app and its source code are licensed under the **MIT License**, whose full text is in the
[repository](https://github.com/DZamataev/macomprendo/blob/main/LICENSE). That licence already
grants you the right to use, copy, modify, merge, publish, distribute, sublicense and sell
copies of the software, and it disclaims all warranties and liability. Nothing on this page
takes any of that away.

The rest of this page covers three things the licence does not describe, because they are
about how the app behaves rather than what you may do with it.

## You own the endpoint relationship

Macomprendo sends audio and text only to destinations you configure yourself. That may be
OpenAI, a self-hosted server, a third-party proxy, or Ollama running on your own machine.

Whatever you choose, that service is **your relationship, not ours**. Its terms, its pricing,
its privacy practices, its retention of what you send it, and its jurisdiction are between you
and that provider. We do not operate any service, hold any account on your behalf, or see
anything you send. If you send confidential material to a third-party endpoint, that
consequence is yours.

## Downloaded models are third-party

The app can download speech-recognition and speech-synthesis models at your request. Those
models are **not part of Macomprendo** and are not ours. Each one is published by its own
authors under its own licence, and some of those licences are more restrictive than MIT — at
least one bundled voice was trained on a dataset licensed for **non-commercial use only**, and
another has no declared licence at all.

You are responsible for observing the licence of any model you download and for deciding
whether it fits your use. Model licences are linked from the source each entry points at.

## The app reads your selection and simulates keystrokes

To do what it does, Macomprendo needs macOS Accessibility permission, which you grant
explicitly. With it, the app:

- reads the **selected text of the frontmost application**, so it can speak, summarize or
  refine it;
- **synthesises ⌘C and ⌘V** to copy that selection and to paste results back;
- **snapshots and restores your clipboard** around those keystrokes, and skips the restore if
  you copied something else in the meantime.

This is how the features work. If you would rather not grant that permission, dictation still
functions and results are copied for you to paste by hand.

## No warranty

The app is provided "as is", without warranty of any kind, and its author is not liable for
any claim, damage or other liability arising from its use — the same disclaimer the MIT
licence makes, restated here so it is not missed.

## Changes

These terms may change when the app does. The current version is always the one published
here, and the history of every change is in the repository.
