import AppKit

// Murmur runs in two modes:
//  - No arguments: the menu bar app.
//  - "--transcribe <audio file>" or "--clean <text>": headless test harnesses
//    so the transcription and clean-up pipelines can be exercised from the
//    terminal without granting any permissions.

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

if let i = arguments.firstIndex(of: "--clean"), i + 1 < arguments.count {
    let text = arguments[i + 1]
    runAndPrint {
        await TranscriptCleaner().clean(text, dictionary: DictionaryStore.currentTerms())
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
