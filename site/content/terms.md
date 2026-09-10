---
title: Terms of Use
description: The terms under which Macomprendo is provided, and the three things the MIT licence does not cover.
output: terms/index.html
---

# Terms of Use

Macomprendo is provided by Denis Zamataev, an individual, free of charge.

## The licence

Macomprendo's own source code is licensed under the **MIT License**, whose full text is in the
[repository](https://github.com/DZamataev/macomprendo/blob/main/LICENSE). That licence grants
you the right to use, copy, modify, merge, publish, distribute, sublicense and sell copies of
the software, and it disclaims all warranties and liability.

**The application you download is under GPL-3.0, not MIT.** It bundles
`SherpaOnnxC.framework`, which has **espeak-ng statically linked into it**, and espeak-ng is
GPL-3.0. Those terms extend to the combined work.

This is disclosure rather than a change of intent, and the corresponding source for the whole
combined work is public: this app at
[github.com/DZamataev/macomprendo](https://github.com/DZamataev/macomprendo), the framework at
[github.com/k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), and espeak-ng at
[github.com/espeak-ng/espeak-ng](https://github.com/espeak-ng/espeak-ng). espeak-ng is the
phonemiser behind offline speech; choosing a different voice does not change anything, because
every offline voice runs through the same framework.

Upstream is removing that dependency in a future release precisely because it conflicts with
sherpa-onnx's own Apache-2.0 licence. When that lands and this app adopts it, the distributed
build returns to MIT terms. The full component list, with every licence and how it reaches
you, is in
[NOTICE](https://github.com/DZamataev/macomprendo/blob/main/NOTICE) and in the app's About
window.

The rest of this page covers three things no licence describes, because they are about how the
app behaves rather than what you may do with it.

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
