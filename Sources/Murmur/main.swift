import AppKit

// Murmur runs in two modes:
//  - No arguments: the menu bar app with its main window.
//  - "--transcribe <audio file>", "--clean <text>", "--clean-suite",
//    "--list-inputs" or "--diag": headless test harnesses so the pipeline
//    can be exercised from the terminal without granting any permissions.
//  - "--record-test [seconds]": records from the configured microphone and
//    transcribes it, to check the live audio path without the fn key.

Launch.milestone("main")
let arguments = CommandLine.arguments

private func runAndPrint(_ work: @escaping @Sendable () async -> String) -> Never {
    final class Box: @unchecked Sendable { var value = "" }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await work()
        semaphore.signal()
    }
    semaphore.wait()
    print(box.value)
    Log.flush()
    exit(0)
}

if let i = arguments.firstIndex(of: "--transcribe"), i + 1 < arguments.count {
    let path = arguments[i + 1]
    runAndPrint {
        do {
            return try await FileTranscriber.transcribe(url: URL(fileURLWithPath: path))
        } catch {
            return "Transcription failed: \(error)"
        }
    }
}

if arguments.contains("--diag") {
    runAndPrint { await StreamingTranscriber.diagnostics() }
}

if let i = arguments.firstIndex(of: "--record-test") {
    let seconds = i + 1 < arguments.count ? Double(arguments[i + 1]) ?? 4 : 4
    runAndPrint { await RecordingProbe.run(seconds: seconds) }
}

if arguments.contains("--list-inputs") {
    let recording = AudioDevices.resolveRecordingDevice()
    for device in AudioDevices.inputDevices() {
        let marker = device.id == recording?.id ? "  <- Murmur records from this" : ""
        print("\(device.name)\t[\(device.uid)] builtIn=\(device.isBuiltIn) bluetooth=\(device.isBluetooth)\(marker)")
    }
    exit(0)
}

if arguments.contains("--clean-suite") {
    runAndPrint { await CleanupSuite.run(dictionary: DictionaryStore.currentTerms()) }
}

if let i = arguments.firstIndex(of: "--clean"), i + 1 < arguments.count {
    let text = arguments[i + 1]
    runAndPrint {
        let outcome = await TranscriptCleaner().process(text, dictionary: DictionaryStore.currentTerms())
        var out = outcome.text
        if outcome.source != .model {
            out += "\n[\(outcome.source.rawValue)\(outcome.note.map { ": \($0)" } ?? "")]"
        }
        return out
    }
}

// One Murmur at a time. Two instances (say, a development build and an
// installed copy) both see the fn key, both open the microphone and both
// paste, so the second to arrive hands over to the first and quits. The
// post-grant relaunch is the exception: there the old instance is on its
// way out and the new one must stay.
if !arguments.contains(FnKeyMonitor.relaunchMarker) {
    let others = NSRunningApplication.runningApplications(
        withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.abdullaalbassam.murmur"
    ).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let other = others.first {
        Log.info("Murmur: already running as pid \(other.processIdentifier) at \(other.bundleURL?.path ?? "?"); quitting this instance")
        other.activate()
        Log.flush()
        exit(0)
    }
}

// Top-level code runs on the main thread, but Swift can't see that in
// language mode 5, so we assert it before touching main-actor AppKit state.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
