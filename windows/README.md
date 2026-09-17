# Murmur for Windows

Push-to-talk dictation for Windows 11. Hold **Right Ctrl**, speak, let go: clean text appears in whichever window has focus. Everything runs on the PC. Audio and transcripts never leave it, and there are no accounts, API keys or network calls once the models are downloaded.

This is a separate program from the macOS version in the parent directory, not a cross-compile of it. Swift on Windows has no SwiftUI, no AppKit and none of the Apple frameworks Murmur is built on, so the platform layer is rewritten in Python. The parts that are not platform-specific, the filler-stripping pre-pass and the guardrails that decide whether the polishing model behaved, are ported line for line, and both builds run the same test corpus.

## For the person installing it

1. Double-click **MurmurSetup-0.1.0.exe** and click Install. It does not ask for an administrator password.
2. Windows may show a blue **"Windows protected your PC"** box, because the installer is not signed by a company Microsoft recognises. Click **More info**, then **Run anyway**. This is expected for software that is not sold in a shop.
3. Murmur opens and downloads the two models it runs on, about 3 GB. This happens once, and takes as long as the connection takes. After that it never needs the internet again.
4. When it says **Ready**, hold **Right Ctrl**, say something, and let go. The text appears wherever the cursor is.

Closing the window leaves Murmur running in the notification area, next to the clock. Click the icon there to open it again, or to quit.

Windows may ask once whether Murmur can use the microphone. It needs it. If it was refused, turn it back on in Settings → Privacy & security → Microphone, with "Let desktop apps access your microphone" on.

## Using it

**The key.** The Mac version uses fn. Windows keyboards handle fn in the keyboard's own firmware and never report it to software, so there is nothing to listen for. Right Ctrl is the closest equivalent: every keyboard has one, it does nothing on its own, and it falls under the right hand. Right Shift, Right Alt, Caps Lock, Scroll Lock, F9 and F10 are the alternatives in Settings.

**Polishing.** The transcript goes through a small language model running inside Murmur. Filler sounds go, spoken corrections are applied ("at 4pm, wait no, at 3pm" becomes "at 3pm"), and obvious emails are laid out as emails. The output is then checked against what was actually said. If the model invents words, drops too much, or answers the dictation instead of editing it, the plain transcript is inserted instead and the Status pane says so. That check is the same one the Mac build uses, and the same real failures are in the test suite.

**Speed.** Expect two to five seconds between letting go of the key and the text appearing, most of it the polishing model. It is slower than the Mac, which has hardware dedicated to this. If it is too slow, Settings → Polishing model → *Qwen2.5 1.5B (fastest)* roughly halves it, at some cost in how often the guardrails have to reject an answer.

**History and dictionary.** The History pane keeps the last 100 dictations, which is useful when a paste lands somewhere unexpected. The Dictionary pane takes names and jargon the recogniser fumbles, one per line; they are given to the recogniser as hints and their spelling is enforced on the result.

**The clipboard.** Murmur pastes by putting the text on the clipboard, sending Ctrl+V, and putting back what was there before. Unlike the Mac build, only text is restored: an image or a spreadsheet range on the clipboard is lost. Windows clipboard formats belong to the application that created them and cannot be copied back faithfully without re-rendering them.

## What it is built on

| | |
|---|---|
| Push-to-talk key | A low-level keyboard hook, `SetWindowsHookEx(WH_KEYBOARD_LL)` |
| Microphone | WASAPI through PortAudio, mono, resampled to 16 kHz |
| Speech recognition | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) `small.en`, int8 on the CPU |
| Polishing | [Qwen3-4B-Instruct-2507](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507) at Q4\_K\_M, through llama.cpp, in-process |
| Interface | Tkinter, with a `pystray` notification-area icon |

Whisper was the obvious substitute for Apple's `SpeechTranscriber`, and it brings a bonus: it returns punctuated, capitalised text, where the Apple recogniser returns neither. That is a large part of what Apple Intelligence was doing on the Mac, so the polishing model here is left with the harder and more interesting half of the job.

Qwen3-4B was chosen over the more obvious Llama and Qwen2.5 3B candidates on licence as much as quality. It is Apache 2.0, where Qwen2.5-3B is released under a research licence that forbids commercial use and Llama's licence carries attribution conditions. For a program that is given away, a model that can be given away with it matters. On a PC with fewer than four physical cores or less than 16 GB of memory, Murmur drops to Qwen2.5 1.5B by itself, which is Apache 2.0 too.

Both models are downloaded on first run to `%LOCALAPPDATA%\Murmur\models` and never re-fetched.

## Where things are kept

```
%APPDATA%\Murmur\settings.json      settings
%APPDATA%\Murmur\history.json       the last 100 dictations
%APPDATA%\Murmur\dictionary.txt     the personal dictionary
%LOCALAPPDATA%\Murmur\models\       the two models
%LOCALAPPDATA%\Murmur\Logs\         the log
```

Uninstalling removes the program and the models and leaves the first three alone.

## When something is wrong

Open Murmur from the notification area. The Status pane names the step that is missing and anything that went wrong with the last dictation. Failing that, the same binary answers the diagnostic flags the macOS build does, and prints to the terminal that launched it:

```
Murmur.exe --diag            what is installed, which models, which microphone
Murmur.exe --list-inputs     every microphone, and which one Murmur will use
Murmur.exe --record-test 5   record five seconds and show every stage
Murmur.exe --clean "um so meet at 3 no wait 4"
Murmur.exe --clean-suite     30 realistic dictations, pass or fail
```

`--record-test` is the quickest way to tell a microphone problem from a recognition problem: it prints how loud the recording was, what was recognised, and what the polishing did to it.

- **Nothing happens when I let go of Right Ctrl.** Check the Status pane first. If it says Ready, the likely cause is that the window being dictated into is running as administrator: a normal program cannot see keystrokes sent to an elevated one. Running Murmur as administrator too fixes it.
- **Text lands in the wrong window.** Murmur pastes wherever keyboard focus is when the key comes up. The dictation is also in History.
- **"Nothing was recognised."** Run `Murmur.exe --record-test 5`. If the loudness is near zero, Windows is sending silence: check the microphone in Settings, and that it is not muted or disabled in Windows' own sound settings.
- **Accuracy is poor.** Add recurring names to the Dictionary, speak at a normal pace, and try the Medium speech model in Settings.

## Building it

On a Windows 11 PC with [Python 3.12](https://www.python.org/downloads/) ("Add python.exe to PATH" ticked) and [Inno Setup 6](https://jrsoftware.org/isdl.php):

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

That creates a virtual environment, installs everything, runs the tests, freezes the app with PyInstaller and produces `dist\MurmurSetup-0.1.0.exe`. That one file is the whole program; nothing else needs to be sent with it.

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1 -IncludeModels
```

does the same but bakes the models into the installer. The installer goes from roughly 400 MB to roughly 3.5 GB, and in exchange the PC it is installed on never downloads anything. Worth it when the connection at the other end is poor.

`llama-cpp-python` is installed from its own wheel index, which publishes a prebuilt `py3-none-win_amd64` wheel, so no compiler is involved. The build fails loudly if any of the three native dependencies cannot be imported, rather than producing an installer that is broken in a way only the recipient discovers.

### Tests

```powershell
.venv\Scripts\python -m pytest tests -q
```

Thirty-three tests, and none of them need a model or a Windows machine. They cover the pre-pass and the guardrails, which are ported from the Swift versions with their cases intact; the pipeline around the model, meaning that a good answer is passed through, that an answered question or a dead model falls back to the transcript rather than raising, that the dictionary is applied on both paths, and that the prompt prefix is byte-identical between dictations, which is what lets llama.cpp reuse its cache instead of re-reading a thousand tokens of examples every time; and the window itself, built for real and driven through each state it can be in. The window tests skip themselves where there is no display.

What the model itself does is not a unit test, because it depends on the machine. `Murmur.exe --clean-suite` measures that where it matters, on the PC it will run on, and prints how many of the thirty cases passed and how often the guardrails had to step in.

## Privacy

Murmur sends nothing anywhere. The models are downloaded once from Hugging Face and everything after that is local: recognition, polishing, history and the dictionary are all files on the PC. The log holds timings and diagnostics, and at most a few words when a polish is rejected, never whole transcripts.
