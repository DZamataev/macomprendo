---
title: Terms of use
description: Macomprendo licences, third-party services and models, permissions and warranty terms.
output: terms/index.html
---

# Terms of use

Denis Zamataev provides Macomprendo free of charge as an individual developer.

## Licences

Macomprendo's own source code uses the [MIT License](https://github.com/DZamataev/macomprendo/blob/main/LICENSE). It permits use, copying, modification, merging, publication, distribution, sublicensing and sale. It disclaims warranties and liability.

The distributed application is GPL-3.0. It bundles `SherpaOnnxC.framework`, which statically links espeak-ng, a GPL-3.0 component. The GPL terms apply to the combined work. All offline voices use that framework, so changing voices does not change the licence.

The corresponding source is public in the [Macomprendo](https://github.com/DZamataev/macomprendo), [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and [espeak-ng](https://github.com/espeak-ng/espeak-ng) repositories. The app's About window and [NOTICE](https://github.com/DZamataev/macomprendo/blob/main/NOTICE) list the components and their licences.

Upstream plans to remove espeak-ng because its GPL terms conflict with sherpa-onnx's Apache-2.0 licence. Macomprendo's distributed build can return to MIT terms after it adopts a framework without that dependency.

## Providers and downloaded models

Macomprendo sends audio and text only to endpoints you configure. These may include OpenAI, a self-hosted server, a proxy or local Ollama. The provider's terms, prices, privacy practices, retention rules and jurisdiction apply to your use. We do not operate a service, manage an account for you or receive your requests. You are responsible for deciding whether a provider is suitable for confidential material.

Speech models download only at your request. Their authors publish them under separate licences. Some restrict commercial use, and some do not declare a licence. At least one available voice uses training data licensed for non-commercial use only. Check the licence at each model's linked source before using it. You are responsible for complying with those terms.

## Permissions

With your Accessibility permission, Macomprendo reads selected text in the frontmost app and simulates ⌘C and ⌘V to copy selections and paste results. It snapshots and restores the clipboard around those keystrokes. If you copy something else in the meantime, it skips the restore.

Without Accessibility permission, you can still dictate and paste the copied result by hand.

## Warranty and changes

The app is provided "as is", without warranty of any kind. Its author is not liable for claims, damages or other liability arising from its use, as stated in the MIT licence.

These terms may change with the app. This page contains the current version, and the repository records previous versions.
