# Microphone selection and dead-device fallback

Status: **implemented 2026-09-28** (`1408265`). Written after the code, from the code, the
changelog and `docs/SMOKE_TEST.md` § Microphone picker — the feature shipped without a spec.

## Problem

Dictation always recorded from whatever macOS had as the default input. Two failures followed:

- A wireless headset whose dongle is plugged in while the headset is off becomes the default
  input and delivers digital zeros. The recording ran for its full length on a dead device.
- Switching the input device during a recording crashed the app on the next dictation:
  after a configuration change `AVAudioEngine` stops itself but keeps its tap, and installing a
  second tap raises an Objective-C exception.

Whole-recording silence is a separate problem with its own spec
(`2026-09-21-silent-capture-detection.md`); this one is about *which device* records.

## Behaviour

**Choice.** Settings ▸ General ▸ Microphone lists **System default (<device>)** — naming the
device it currently means — followed by every connected input device. The list follows devices
being plugged in and removed while the tab is open. The choice is stored as a Core Audio device
UID (`Settings.preferredInputDeviceUID`, stable across reboots and reconnections) plus its last
known name (`preferredInputDeviceName`), so a disconnected choice can still be shown by name.
`nil` follows the system default.

**Disconnected choice.** A chosen device that is not connected stays selected and is listed as
**<name> — not connected**, with a caption naming the system default that records instead. When
it comes back, the next dictation uses it. Silently resetting the choice was rejected: a
switched-off headset is expected to return.

**Binding.** The recorder always binds the input node to a device explicitly — the chosen one if
connected, else the system default — so both cases share one code path. A change of choice, or of
the system default while following it, applies at once, including to a recording in progress;
audio captured before the switch is kept.

**Dead device.** A device delivering nothing below −100 dBFS for two seconds
(`AVAudioEngineRecorder.deadDeviceSeconds`) is excluded for the rest of that recording. The next
device is, in order: the chosen device (if not excluded), the system default, the built-in
microphone, any other input. −100 dBFS is far below a working microphone's noise floor
(about −66 dBFS between words), so a quiet room never trips it. Two seconds is shorter than the
HUD's three-second "Not hearing anything" warning, so the fallback usually lands first. The
exclusion lasts one recording: the next one tries the chosen device again.

**Telling the user.** Each fallback is published as an `InputFallback` (device names, not ids).
Dictate shows it in the HUD above the still-moving level meter; Dictate & Refine shows the same
wording as a notice. `InputFallback.message` holds the wording so the two cannot diverge.

## Structure

- `AudioInputDeviceListing` (`Services/AudioInputDevices.swift`) — input devices, the default,
  and a payload-free change stream, over the Core Audio HAL. Fake: `FakeAudioInputDevices`.
- `AudioInputEngine` (`Services/AudioRecorder.swift`) — the input side of `AVAudioEngine` the
  recorder drives. Fake: `FakeAudioInputEngine`, which is what makes device switching and the
  dead-device path unit-testable.
- `AVAudioEngineRecorder` tracks whether it has a tap itself rather than reading
  `engine.isRunning`, and serialises engine calls on one lock never taken by the tap block.
- `MicrophonePickerModel` (`UI/Settings`) — options, selection and caption; observes changes
  only while the tab is visible.
- `AppModel` forwards the choice to `recorder.setPreferredInputDevice(uid:)` at launch and on
  every change.

## Verification

Unit tests: `AudioRecorderTests`, `MicrophonePickerModelTests`, `DictationControllerTests`,
`RefineControllerTests`, `HUDViewTests`, `SettingsTests`, `AppModelTests`. Hardware behaviour:
`docs/SMOKE_TEST.md` § Microphone picker.
