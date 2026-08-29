# Murmur

Push-to-talk dictation for macOS. Hold **fn**, speak, release: clean text appears in whichever app has focus. Everything runs on-device; audio and transcripts never leave the Mac. No accounts, no API keys, no network calls.

## How it works

1. A listen-only `CGEventTap` watches the fn key globally.
2. While fn is held, `AVAudioEngine` streams microphone audio into `SpeechAnalyzer`/`SpeechTranscriber`, the on-device speech recognition introduced in macOS 26.
3. The raw transcript goes through Apple's on-device Foundation Models LLM, which strips filler words, fixes punctuation, applies self-corrections ("meet at 3 no wait 4" becomes "meet at 4") and enforces personal dictionary spellings. If Apple Intelligence is unavailable the raw transcript is used instead.
4. The result is pasted into the focused app via the pasteboard and a synthesised ⌘V, then your previous clipboard is restored.

Also included: dictation history (last 100 entries, stored locally as JSON), a personal dictionary for names and jargon the recogniser fumbles, launch at login, and a menu bar toggle for the AI clean-up pass.

## Stack

Swift, AppKit and SwiftUI, built with SwiftPM. Zero third-party dependencies. Speech recognition: `Speech` framework (`SpeechAnalyzer`, macOS 26). Clean-up: `FoundationModels` framework.

## Requirements

- macOS 26 (Tahoe) on Apple silicon
- Xcode 26 (for the Swift 6.2 toolchain)
- Apple Intelligence enabled, only if you want the AI clean-up pass

## Build and run

```sh
./build.sh
open build/Murmur.app
```

Then, one-time setup:

1. Grant **Accessibility** when prompted (needed for the fn hotkey and the paste).
2. Grant **Microphone** on your first dictation.
3. In System Settings → Keyboard, set "Press 🌐 key to" to **Do Nothing** so macOS stays out of the way.

`build.sh` signs with your Apple Development certificate if one is in your keychain, otherwise ad-hoc (functional, but macOS forgets the permission grants on every rebuild).

## CLI test harness

The same binary doubles as a headless test tool, no permissions needed:

```sh
./build/Murmur.app/Contents/MacOS/Murmur --transcribe recording.aiff
./build/Murmur.app/Contents/MacOS/Murmur --clean "um so meet at 3 no wait 4"
./build/Murmur.app/Contents/MacOS/Murmur --diag
```
