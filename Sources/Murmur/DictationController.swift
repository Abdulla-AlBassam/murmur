import AppKit
import AVFoundation

/// Orchestrates the whole dictation loop:
/// fn down → record → fn up → finalise transcript → clean up → insert text.
///
/// Readiness: a transcriber is kept warm while idle so that fn-down only
/// has to open the microphone. Audio starts flowing before the analyzer is
/// asked to run, queued in `AudioRelay`, so the first syllables are kept.
@MainActor
final class DictationController {
    enum State: Equatable { case idle, starting, recording, processing }

    private(set) var state: State = .idle {
        didSet {
            appState.dictationState = state
            onStateChange?(state)
        }
    }
    var onStateChange: ((State) -> Void)?

    let cleaner = TranscriptCleaner()
    let appState: AppState

    private let fnMonitor = FnKeyMonitor()
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let pill = RecordingPill()

    private var session: StreamingTranscriber?
    private var warm: StreamingTranscriber?
    private var warming = false
    private var stopRequested = false
    private var recordingStartedAt: Date?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        promptForAccessibilityIfNeeded()

        fnMonitor.onFnDown = { [weak self] in self?.fnPressed() }
        fnMonitor.onFnUp = { [weak self] in self?.fnReleased() }
        fnMonitor.onReady = { [weak self] in
            Launch.milestone("hotkey ready")
            self?.appState.hotkeyReady = true
            self?.noteReadiness()
        }
        fnMonitor.startWithRetry()

        recorder.onNotice = { [weak self] notice in self?.appState.lastProblem = notice }

        Task { await prepareModel() }
    }

    /// Releases the microphone and any speech session. Called on quit.
    func shutdown() {
        recorder.stop()
        let session = self.session
        let warm = self.warm
        self.session = nil
        self.warm = nil
        Task.detached {
            await session?.cancel()
            await warm?.cancel()
        }
        fnMonitor.stop()
        pill.hide()
        state = .idle
    }

    // MARK: - Speech model assets

    private func prepareModel() async {
        appState.modelStatus = .checking
        do {
            let downloaded = try await StreamingTranscriber.ensureModel {
                Task { @MainActor in self.appState.modelStatus = .downloading }
            }
            appState.modelStatus = .ready
            Launch.milestone(downloaded ? "speech model ready (assets were fetched)" : "speech model ready")
            noteReadiness()
            await warmUp()
        } catch {
            appState.modelStatus = .unavailable(error.localizedDescription)
            Log.info("Murmur: speech model preparation failed: \(error)")
        }
    }

    private func noteReadiness() {
        guard appState.readyAfterMs == nil, appState.isReadyToDictate else { return }
        appState.readyAfterMs = Launch.millisecondsSinceStart()
        Launch.milestone("ready to dictate")
    }

    /// Prepares the next transcriber in the background.
    private func warmUp() async {
        guard warm == nil, !warming, appState.modelStatus.isReady else { return }
        warming = true
        defer { warming = false }
        do {
            let session = try await StreamingTranscriber(contextualStrings: DictionaryStore.shared.terms)
            if warm == nil { warm = session } else { await session.cancel() }
            Launch.milestone("transcriber warm")
        } catch {
            Log.info("Murmur: could not pre-warm transcriber: \(error)")
        }
    }

    // MARK: - Hotkey handling

    private func fnPressed() {
        guard state == .idle else { return }
        stopRequested = false
        appState.lastProblem = nil
        state = .starting
        pill.show(.listening)
        Task { await beginSession() }
    }

    private func fnReleased() {
        switch state {
        case .starting:
            // Key released before the pipeline finished spinning up.
            stopRequested = true
        case .recording:
            Task { await finishSession() }
        default:
            break
        }
    }

    // MARK: - Session lifecycle

    private func beginSession() async {
        let clock = Launch.Stopwatch()
        guard await AudioRecorder.requestPermission() else {
            state = .idle
            pill.hide()
            appState.microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            showMicrophoneAlert()
            return
        }

        let relay = AudioRelay()
        recorder.onBuffer = { relay.push($0) }
        do {
            try await recorder.start(device: AudioDevices.resolveRecordingDevice())
        } catch {
            fail("Could not open the microphone: \(error.localizedDescription)")
            return
        }
        recordingStartedAt = Date()
        Log.info("Murmur: microphone open \(clock.ms) ms after fn down")

        do {
            let session = try await obtainTranscriber()
            relay.attach(session)
            self.session = session
            Log.info("Murmur: analyzer running \(clock.ms) ms after fn down")
        } catch {
            recorder.stop()
            fail("Could not start speech recognition: \(error.localizedDescription)")
            return
        }

        if stopRequested {
            await finishSession()
        } else {
            state = .recording
        }
    }

    /// Uses the warm transcriber if there is one, otherwise builds a fresh
    /// one. A warm one that refuses to start is replaced.
    private func obtainTranscriber() async throws -> StreamingTranscriber {
        if let warm {
            self.warm = nil
            do {
                try await warm.begin()
                return warm
            } catch {
                Log.info("Murmur: warm transcriber failed to start, creating a new one: \(error)")
                await warm.cancel()
            }
        }
        let fresh = try await StreamingTranscriber(contextualStrings: DictionaryStore.shared.terms)
        try await fresh.begin()
        return fresh
    }

    private func finishSession() async {
        guard let session else {
            state = .idle
            pill.hide()
            return
        }
        self.session = nil
        recorder.stop()  // release the microphone before anything else

        let heldFor = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        // Treat a very quick tap as accidental rather than a dictation.
        guard heldFor > 0.3 else {
            await session.cancel()
            state = .idle
            pill.hide()
            Task { await warmUp() }
            return
        }

        state = .processing
        pill.show(.working)
        defer {
            state = .idle
            pill.hide()
            Task { await warmUp() }
        }

        do {
            let clock = Launch.Stopwatch()
            let raw = try await session.finish()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.info("Murmur: empty transcript after \(String(format: "%.1f", heldFor)) s, nothing inserted")
                return
            }
            let cleaned = await cleaner.clean(trimmed, dictionary: DictionaryStore.shared.terms)
            inserter.insert(cleaned)
            HistoryStore.shared.add(text: cleaned, raw: cleaned == trimmed ? nil : trimmed)
            Log.info("Murmur: text inserted \(clock.ms) ms after fn up")
        } catch {
            fail("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        Log.info("Murmur: \(message)")
        appState.lastProblem = message
        recorder.stop()
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }
        state = .idle
        pill.hide()
        Task { await warmUp() }
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

/// Queues audio buffers until a transcriber is attached, then forwards
/// everything, in order, on the audio thread. Serialised with a lock so the
/// transcriber's converter is never touched from two threads at once.
final class AudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [AVAudioPCMBuffer] = []
    private var target: StreamingTranscriber?

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let target {
            target.feed(buffer)
        } else {
            queued.append(buffer)
        }
    }

    func attach(_ transcriber: StreamingTranscriber) {
        lock.lock()
        defer { lock.unlock() }
        for buffer in queued { transcriber.feed(buffer) }
        Log.info("Murmur: \(queued.count) buffers queued before the analyzer was ready")
        queued.removeAll()
        target = transcriber
    }
}
