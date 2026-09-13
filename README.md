# Murmur

Push-to-talk dictation for macOS. Hold **fn**, speak, release: clean text appears. Simple as that. Wispr Flow open sourced version, if you will. Everything runs on-device; audio and transcripts never leave the Mac. No accounts, no API keys, no network calls.

## How it works

1. A listen-only `CGEventTap` watches the fn key globally.
2. While fn is held, `AVCaptureSession` captures the microphone and streams it into `SpeechAnalyzer`/`SpeechTranscriber`, the on-device speech recognition introduced in macOS 26. A transcriber is kept warm while idle, and audio is queued from the first millisecond, so nothing at the start of a sentence is lost. The personal dictionary is passed to the recogniser as vocabulary hints (`AnalysisContext.contextualStrings`); in testing with synthesised speech this made no measurable difference, so the deterministic casing pass after polishing remains the reliable part.
3. The raw transcript is polished by Apple's on-device Foundation Models LLM: fillers go, spoken corrections are applied ("at 4pm, wait no, at 3pm" becomes "at 3pm"), punctuation and capitalisation are added, and obvious emails and lists are laid out. The model is shown worked examples and its output is checked against the input; if it invents words, drops too much, or replies instead of editing, the plain transcript is inserted instead. Polishing can be switched off in Settings.
4. The result is pasted into the focused app via the pasteboard and a synthesised ⌘V, then your previous clipboard is restored.

Also included: a main window with setup status, settings, dictation history (last 100 entries, stored locally as JSON) and a personal dictionary for names and jargon the recogniser fumbles; launch at login; a menu bar item.

## Microphone and headphones

Murmur records from the **built-in microphone** by default and never touches the system default input or output. This matters for Bluetooth headphones: the moment any app opens a headset's microphone, macOS drops the headset from its high-quality music profile to the low-bandwidth hands-free profile, which is why playback sounds washed out. Murmur only opens a microphone while fn is held, tears the audio engine down as soon as you release it (and on cancel, error and quit), and does not use the headset mic unless you pick it in Settings → Microphone.

The hands-free profile also records at telephone quality, so recognition accuracy is noticeably worse through a Bluetooth headset than through the built-in microphone. Prefer the built-in microphone unless you have to use the headset.

Every CoreAudio call runs off the main thread under a deadline. If the chosen microphone cannot be opened, or the engine runs for 1.5 s without delivering any audio (typical while a headset switches profiles), Murmur retries once and then falls back to the built-in microphone for that dictation. Whatever happened is shown in the Status pane.

## Requirements

- Apple silicon Mac running macOS 26 (Tahoe) or later
- Apple Intelligence enabled.
- Xcode 26 (Swift 6.2 toolchain), to build from source

## First run

1. Open Murmur. The main window shows every setup step and its state.
2. Grant **Accessibility** when prompted (needed for the fn hotkey and the paste). Murmur relaunches itself once after the grant so macOS honours it.
3. Grant **Microphone** on your first dictation, or from the Status pane.
4. In System Settings → Keyboard, set "Press 🌐 key to" to **Do Nothing** so macOS stays out of the way.

Closing the window leaves Murmur running in the menu bar; opening it again from Spotlight, Launchpad or the Dock brings the window back. **Quit Murmur** (menu bar or ⌘Q) stops everything.

Only one Murmur runs at a time. Launching a second copy (for example a fresh development build while an installed copy is running) brings the running one forward and quits; otherwise both would react to fn and both would paste.

## Build and run

```sh
./build.sh
open build/Murmur.app
```

`build.sh` signs with your Apple Development certificate if one is in your keychain, otherwise ad-hoc (functional, but macOS forgets the permission grants on every rebuild). Either way the bundle gets the hardened runtime and the entitlements in `Resources/Murmur.entitlements`, so a development build behaves like the release.

Keep a single copy of `Murmur.app` on disk. LaunchServices registers every bundle it sees, so a second copy shows up twice in Spotlight and Accessibility settings and can end up running alongside the first.

Launch and readiness timings are written to `~/Library/Logs/Murmur.log` (`launch milestone …`), along with per-dictation timings such as how long after fn-down the microphone opened.

## Release (signed, notarised DMG)

One-time setup, as the Apple Developer team K465H4V2A2 account holder:

1. Create a **Developer ID Application** certificate: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application. It lands in the login keychain.
2. Store notarisation credentials (app-specific password from appleid.apple.com):

   ```sh
   xcrun notarytool store-credentials murmur-notary --apple-id you@example.com --team-id K465H4V2A2
   ```

Then:

```sh
./release.sh                  # build, sign, notarise, staple, DMG in dist/
./release.sh --skip-notarize  # same pipeline without the Apple round trip
```

The script bumps nothing on its own: set the version in `Resources/Info.plist` first. It writes `dist/Murmur-<version>.dmg` and a SHA-256 alongside it, and removes the intermediate `dist/Murmur.app` so the DMG is the only copy. Users drag Murmur to Applications and follow the first-run steps above.

## CLI test harness

The same binary doubles as a headless test tool, no permissions needed:

```sh
./build/Murmur.app/Contents/MacOS/Murmur --transcribe recording.aiff
./build/Murmur.app/Contents/MacOS/Murmur --clean "um so meet at 3 no wait 4"
./build/Murmur.app/Contents/MacOS/Murmur --clean-suite   # 30 realistic dictations, pass/fail
./build/Murmur.app/Contents/MacOS/Murmur --list-inputs
./build/Murmur.app/Contents/MacOS/Murmur --diag
open build/Murmur.app --args --record-test 5             # live mic → transcript, in the log
```

`--clean-suite` covers emails, lists, questions, commands, names, numbers, corrections and prompt-injection-shaped speech, and reports whether each result came from the model or from the guarded fallback.

`--record-test` opens the microphone chosen in Settings exactly as a dictation would, records for the given number of seconds and transcribes it. Launch it through `open` so the bundle's own microphone permission applies; the result is written to `~/Library/Logs/Murmur.log` as `record-test:` lines.

## Tests

```sh
swift test                                          # unit tests + speech pipeline, ~15 s
MURMUR_E2E=1 swift test --filter CleanupModelTests  # polishing model suite, ~2 min
```

The unit tests cover the guardrails (including real answer-shaped outputs the model produced before the guardrails existed) and the deterministic pre-pass. The speech pipeline test synthesises sentences with `say`, runs them through the same transcriber the app uses and checks the word error rate; it skips itself if the speech model is not installed. The model suite is the `--clean-suite` cases as a test and needs Apple Intelligence.
