# Murmur

Push-to-talk dictation for macOS. Hold **fn**, speak, release: clean text appears in whichever app has focus. Simple as that. Wispr Flow open sourced version, if you will. Everything runs on-device. Audio and transcripts never leave the Mac, and there are no accounts, API keys or network calls.

Murmur is an early build. It works well enough for daily use, but expect rough edges, and please report what breaks.

## Requirements

- Apple silicon Mac running macOS 26 (Tahoe) or later
- Apple Intelligence enabled
- Xcode 26, to build from source

## Install

There is no packaged download yet, so build it yourself:

```sh
git clone https://github.com/Abdulla-AlBassam/murmur.git
cd murmur
./build.sh
open build/Murmur.app
```

`build.sh` signs with an Apple Development certificate if one is in your keychain, otherwise ad-hoc. Ad-hoc builds work, but macOS forgets the permission grants every time you rebuild. If you want Murmur in Applications, move `build/Murmur.app` there and keep only that copy: two copies on disk show up twice in Spotlight and Accessibility settings.

## First run

1. Open Murmur. The main window lists every setup step and whether it is done.
2. Grant **Accessibility** when prompted. Murmur needs it to see the fn key and to paste. It relaunches itself once after the grant so macOS honours it.
3. Grant **Microphone** on your first dictation, or from the Status pane.
4. In System Settings → Keyboard, set "Press 🌐 key to" to **Do Nothing**, so macOS does not open the emoji picker or switch input sources when you hold fn.

Then hold fn, speak, and let go. Closing the window leaves Murmur running in the menu bar; open it again from Spotlight, Launchpad or the Dock to bring the window back. **Quit Murmur** (menu bar or ⌘Q) stops everything.

Only one Murmur runs at a time. Launching a second copy brings the running one forward and quits.

## Using it

**Polishing.** The raw transcript goes through Apple's on-device model: filler sounds go, spoken corrections are applied ("at 4pm, wait no, at 3pm" becomes "at 3pm"), punctuation and capitalisation are added, and obvious emails and lists are laid out. The output is checked against what you said. If the model invents words, drops too much, or answers instead of editing, the plain transcript is inserted instead. Switch polishing off in Settings if you would rather have the transcript as recognised.

**Microphone.** Murmur records from the built-in microphone by default and never changes the system default input or output. You can pick another microphone in Settings, but think twice about Bluetooth headsets: the moment any app opens a headset's microphone, macOS drops it to the low-bandwidth hands-free profile, so music sounds dull while you dictate and recognition accuracy falls to telephone quality. Murmur only holds a microphone while fn is down. If the chosen microphone cannot be opened or delivers no audio, Murmur falls back to the built-in microphone for that dictation and says so in the Status pane.

**History and dictionary.** The History pane keeps the last 100 dictations locally as JSON, handy when a paste lands in the wrong place. The Dictionary pane takes names and jargon the recogniser gets wrong, one per line; they are passed to the recogniser as hints and their spelling is enforced on the result.

**Launch at login** is a toggle in Settings.

## Troubleshooting

- **Nothing happens when I release fn.** Open the main window. The Status pane shows which step is missing and any problem from the last dictation. Check `~/Library/Logs/Murmur.log`, which records every dictation with timings.
- **The fn key does something else.** Set "Press 🌐 key to" to Do Nothing in Keyboard settings.
- **Text lands in the wrong app.** Murmur pastes into whatever has keyboard focus when you release fn. The dictation is also in History.
- **Accuracy is poor.** Use the built-in microphone, speak at a normal pace, and add recurring names to the Dictionary.

## How it works

1. A listen-only `CGEventTap` watches the fn key.
2. While fn is held, `AVCaptureSession` captures the microphone as mono 16 kHz audio and streams it into `SpeechAnalyzer`/`SpeechTranscriber`, the on-device speech recognition in macOS 26. A transcriber is kept warm while idle and audio is queued from the first millisecond, so the start of a sentence is not lost.
3. The transcript is polished by the Foundation Models system model, shown worked examples and constrained by guardrails that compare its output with the input.
4. The result is placed on the pasteboard, ⌘V is synthesised, and your previous clipboard is restored.

Every call into the audio system runs off the main thread under a deadline, so a misbehaving device can fail a dictation but cannot freeze the app.

## Testing from the terminal

The same binary doubles as a headless test tool:

```sh
./build/Murmur.app/Contents/MacOS/Murmur --transcribe recording.aiff
./build/Murmur.app/Contents/MacOS/Murmur --clean "um so meet at 3 no wait 4"
./build/Murmur.app/Contents/MacOS/Murmur --clean-suite   # 30 realistic dictations, pass/fail
./build/Murmur.app/Contents/MacOS/Murmur --list-inputs
./build/Murmur.app/Contents/MacOS/Murmur --diag
open build/Murmur.app --args --record-test 5             # live mic to transcript, in the log
```

`--clean-suite` covers emails, lists, questions, commands, names, numbers, corrections and prompt-injection-shaped speech, and reports whether each result came from the model or from the guarded fallback. `--record-test` records from the microphone chosen in Settings for the given number of seconds and transcribes it; launch it through `open` so the app's own microphone permission applies, and read the `record-test:` lines in `~/Library/Logs/Murmur.log`.

Automated tests:

```sh
swift test                                          # unit tests + speech pipeline, ~15 s
MURMUR_E2E=1 swift test --filter CleanupModelTests  # polishing model suite, ~2 min
```

The unit tests cover the guardrails and the deterministic pre-pass. The speech pipeline test synthesises sentences with `say`, runs them through the same transcriber the app uses and checks the word error rate; it skips itself if the speech model is not installed. The model suite needs Apple Intelligence.

## Releasing

`release.sh` builds, signs with a Developer ID Application certificate, notarises, staples and writes `dist/Murmur-<version>.dmg`. It needs that certificate in the login keychain and notarisation credentials stored with `xcrun notarytool store-credentials`; the header of the script explains the setup. Set the version in `Resources/Info.plist` first. `./release.sh --skip-notarize` runs the pipeline without the Apple round trip.

## Privacy

Murmur never sends anything anywhere. Recognition and polishing run on the Mac, history and the dictionary are plain files under `~/Library/Application Support/Murmur`, and the log under `~/Library/Logs` contains timings and diagnostics (at most a few words, when a polish is rejected), never whole transcripts.
