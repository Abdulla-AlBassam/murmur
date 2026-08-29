import AppKit
import AVFoundation

/// Orchestrates the whole dictation loop:
/// fn down → record → fn up → finalise transcript → clean up → insert text.
@MainActor
final class DictationController {
    enum State: Equatable { case idle, starting, recording, processing }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?
    var onModelStatusChange: ((String) -> Void)?

    let cleaner = TranscriptCleaner()

    private let fnMonitor = FnKeyMonitor()
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let pill = RecordingPill()

    private var session: StreamingTranscriber?
    private var stopRequested = false
    private var recordingStartedAt: Date?

    func start() {
        promptForAccessibilityIfNeeded()

        fnMonitor.onFnDown = { [weak self] in self?.fnPressed() }
        fnMonitor.onFnUp = { [weak self] in self?.fnReleased() }
        fnMonitor.startWithRetry()

        Task { await prepareModel() }
    }

    // MARK: - Speech model assets

    private func prepareModel() async {
        onModelStatusChange?("Checking speech model…")
        do {
            let downloaded = try await StreamingTranscriber.ensureModel {
                self.onModelStatusChange?("Downloading speech model…")
            }
            onModelStatusChange?(downloaded ? "Speech model installed" : "Speech model ready")
        } catch {
            onModelStatusChange?("Speech model unavailable")
            Log.info("Murmur: speech model preparation failed: \(error)")
        }
    }

    // MARK: - Hotkey handling

    private func fnPressed() {
        guard state == .idle else { return }
        stopRequested = false
        state = .starting
        pill.show(.listening)
        Task { await beginSession() }
    }

    private func fnReleased() {
        switch state {
        case .starting:
            // Key released before the audio engine finished spinning up.
            stopRequested = true
        case .recording:
            Task { await finishSession() }
        default:
            break
        }
    }

    // MARK: - Session lifecycle

    private func beginSession() async {
        guard await AudioRecorder.requestPermission() else {
            state = .idle
            pill.hide()
            showMicrophoneAlert()
            return
        }
        do {
            let session = try await StreamingTranscriber()
            self.session = session
            recorder.onBuffer = { buffer in session.feed(buffer) }
            try recorder.start()
            recordingStartedAt = Date()
            if stopRequested {
                await finishSession()
            } else {
                state = .recording
            }
        } catch {
            Log.info("Murmur: could not start dictation: \(error)")
            session = nil
            state = .idle
            pill.hide()
        }
    }

    private func finishSession() async {
        guard let session else {
            state = .idle
            pill.hide()
            return
        }
        self.session = nil
        recorder.stop()

        // Treat a very quick tap as accidental rather than a dictation.
        let heldFor = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        state = .processing
        pill.show(.working)
        defer {
            state = .idle
            pill.hide()
        }

        do {
            let raw = try await session.finish()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard heldFor > 0.3, !trimmed.isEmpty else { return }
            let cleaned = await cleaner.clean(trimmed, dictionary: DictionaryStore.shared.terms)
            inserter.insert(cleaned)
            HistoryStore.shared.add(text: cleaned, raw: cleaned == trimmed ? nil : trimmed)
        } catch {
            Log.info("Murmur: transcription failed: \(error)")
        }
    }

    // MARK: - Permissions

    private func promptForAccessibilityIfNeeded() {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func showMicrophoneAlert() {
        let alert = NSAlert()
        alert.messageText = "Murmur needs microphone access"
        alert.informativeText = """
        Grant access in System Settings → Privacy & Security → Microphone, \
        then hold fn to dictate again.
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
