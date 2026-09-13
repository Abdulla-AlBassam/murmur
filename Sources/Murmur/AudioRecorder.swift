import AVFoundation

/// Captures microphone audio and hands PCM buffers to whoever set
/// `onBuffer`. Buffers arrive on a private serial queue, already converted
/// to mono 16 kHz Float32, which is what speech recognition wants.
///
/// Capture uses AVCaptureSession rather than AVAudioEngine. The engine's
/// input node caches the device format it saw when it was created; select
/// another device, or let a Bluetooth headset switch to its hands-free
/// profile after the microphone opens (which halves its sample rate), and
/// the engine either stops silently, delivers audio at the wrong rate, or
/// trips its own "format.sampleRate == hwFormat.sampleRate" assertion. All
/// three were reproduced with AirPods Pro. AVCaptureSession owns the device,
/// follows format changes and resamples to the requested output itself.
///
/// The session only exists between `start()` and `stop()`, so Murmur holds
/// no microphone while idle. Every call into the capture stack runs on a
/// throwaway worker thread with a deadline: CoreAudio has been seen to spin
/// indefinitely while a headset changes profile, freezing the main actor for
/// twenty minutes. A start that overruns the deadline fails with a message
/// and the stuck thread is abandoned. When the chosen microphone fails or
/// delivers nothing, capture falls back to the built-in microphone and the
/// user is told.
final class AudioRecorder: NSObject, @unchecked Sendable {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// One-line notices worth surfacing in the UI (fallbacks, stalls).
    /// Called on the main queue.
    var onNotice: ((String) -> Void)?

    /// How long a capture call may take before the attempt is abandoned.
    static let deadline: TimeInterval = 4
    /// How long a running session may go without delivering audio before
    /// the device is considered stalled.
    static let stallTimeout: TimeInterval = 1.5
    /// What every buffer is delivered as, whatever the device produces.
    static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// All state below is owned by `control`.
    private let control = DispatchQueue(label: "com.abdullaalbassam.murmur.audio")
    private let samples = DispatchQueue(label: "com.abdullaalbassam.murmur.audio.samples")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var device: AudioInputDevice?
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private var errorObserver: NSObjectProtocol?
    private var stallCheck: DispatchWorkItem?
    /// Fresh sessions opened on the current device after it went quiet; each
    /// device gets its own budget.
    private var retries = 0
    private static let maxRetries = 1

    private let stats = Stats()

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Starts capturing from `device`, or from the system default input when
    /// nil. If `device` cannot be opened, the built-in microphone is tried
    /// before giving up.
    func start(device: AudioInputDevice?) async throws {
        let handler = onBuffer
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    try self.startLocked(preferred: device, handler: handler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops capture and releases the device. Safe to call repeatedly; the
    /// release happens in the background so a wedged device can never stall
    /// the caller.
    func stop() {
        control.async { self.tearDownLocked() }
    }

    // MARK: - Control queue

    private func startLocked(preferred: AudioInputDevice?, handler: ((AVAudioPCMBuffer) -> Void)?) throws {
        tearDownLocked()
        self.handler = handler
        do {
            try openLocked(preferred)
        } catch {
            guard let preferred, !preferred.isBuiltIn, let builtIn = Self.builtInMicrophone() else {
                throw error
            }
            Log.info("Murmur: \(preferred.name) failed (\(error.localizedDescription)); falling back to \(builtIn.name)")
            try openLocked(builtIn)
            notify("\(preferred.name) could not be opened (\(error.localizedDescription)). Recorded from \(builtIn.name) instead.")
        }
    }

    /// Builds and starts a session on `device` under the deadline. On
    /// success it becomes the current session.
    private func openLocked(_ device: AudioInputDevice?) throws {
        let name = device?.name ?? "system default input"
        stats.reset()

        let (session, output) = try Self.withDeadline(describing: "opening \(name)") {
            () throws -> (AVCaptureSession, AVCaptureAudioDataOutput) in
            let captureDevice: AVCaptureDevice?
            if let device {
                captureDevice = AVCaptureDevice(uniqueID: device.uid)
            } else {
                captureDevice = AVCaptureDevice.default(for: .audio)
            }
            guard let captureDevice else {
                throw Failure(errorDescription: "\(name) is not available for capture")
            }
            let session = AVCaptureSession()
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: captureDevice)
            guard session.canAddInput(input) else {
                throw Failure(errorDescription: "\(name) cannot be used as an input")
            }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = Self.outputSettings
            output.setSampleBufferDelegate(self, queue: self.samples)
            guard session.canAddOutput(output) else {
                throw Failure(errorDescription: "Audio output could not be added for \(name)")
            }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
            guard session.isRunning else {
                throw Failure(errorDescription: "\(name) did not start")
            }
            Log.info("Murmur: recording from \(captureDevice.localizedName)")
            return (session, output)
        }

        self.session = session
        self.output = output
        self.device = device
        errorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.control.async {
                self?.recoverLocked(from: session, reason: "capture error: \(error?.localizedDescription ?? "unknown")")
            }
        }
        scheduleStallCheck(for: session)
    }

    private func scheduleStallCheck(for session: AVCaptureSession) {
        stallCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.session === session, self.stats.bufferCount == 0 else { return }
            self.recoverLocked(from: session, reason: "no audio after \(Self.stallTimeout) s")
        }
        stallCheck = check
        control.asyncAfter(deadline: .now() + Self.stallTimeout, execute: check)
    }

    /// The session stopped delivering audio (headset changing profile,
    /// device unplugged, capture error). Open a fresh session on the same
    /// device once; after that, or if it fails, move to the built-in
    /// microphone, which gets one retry of its own before giving up.
    private func recoverLocked(from failed: AVCaptureSession, reason: String) {
        guard session === failed else { return }
        let current = device
        let name = current?.name ?? "system default input"
        let retriesSoFar = retries
        Log.info("Murmur: \(name): \(reason)")
        tearDownLocked()

        if retriesSoFar < Self.maxRetries {
            do {
                try openLocked(current)
                retries = retriesSoFar + 1
                Log.info("Murmur: \(name) reopened")
                return
            } catch {
                Log.info("Murmur: \(name) did not reopen: \(error.localizedDescription)")
            }
        }

        guard let builtIn = Self.builtInMicrophone(), current?.id != builtIn.id else {
            notify("No audio is arriving from \(name). Try another microphone in Settings.")
            return
        }
        do {
            try openLocked(builtIn)
            retries = 0
            notify("No audio arrived from \(name). Switched to \(builtIn.name) for this dictation.")
        } catch {
            notify("No audio arrived from \(name), and \(builtIn.name) could not be opened either.")
        }
    }

    private func tearDownLocked() {
        stallCheck?.cancel()
        stallCheck = nil
        if let errorObserver {
            NotificationCenter.default.removeObserver(errorObserver)
            self.errorObserver = nil
        }
        guard let session else { return }
        let name = device?.name ?? "system default input"
        output?.setSampleBufferDelegate(nil, queue: nil)
        self.session = nil
        self.output = nil
        self.device = nil
        retries = 0
        Log.info("Murmur: captured \(stats.summary)")
        _ = try? Self.withDeadline(describing: "releasing \(name)") {
            session.stopRunning()
        }
    }

    private func notify(_ message: String) {
        Log.info("Murmur: \(message)")
        DispatchQueue.main.async { self.onNotice?(message) }
    }

    // MARK: - Helpers

    /// Runs `work` on a fresh thread and waits at most `deadline` for it.
    /// A call that never returns is left behind on that thread rather than
    /// taking the caller down with it.
    private static func withDeadline<T>(describing what: String, _ work: @escaping () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let worker = DispatchQueue(label: "com.abdullaalbassam.murmur.audio.worker")
        worker.async {
            box.result = Result { try work() }
            done.signal()
        }
        guard done.wait(timeout: .now() + deadline) == .success, let result = box.result else {
            Log.info("Murmur: the audio system did not respond within \(Int(deadline)) s while \(what); abandoning that attempt")
            throw Failure(errorDescription: "The audio system did not respond while \(what)")
        }
        return try result.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private static func builtInMicrophone() -> AudioInputDevice? {
        AudioDevices.inputDevices().first { $0.isBuiltIn }
    }

    /// Buffer statistics, written on the sample queue and read on `control`.
    private final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers = 0
        private var frames: AVAudioFrameCount = 0
        private var peakValue: Float = 0
        private var rate: Double = 0
        private var startedAt = Date()

        var bufferCount: Int { lock.withLock { buffers } }

        func reset() {
            lock.withLock {
                buffers = 0
                frames = 0
                peakValue = 0
                rate = 0
                startedAt = Date()
            }
        }

        func record(_ buffer: AVAudioPCMBuffer) {
            var peak: Float = 0
            if let data = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
            }
            lock.withLock {
                buffers += 1
                frames += buffer.frameLength
                peakValue = max(peakValue, peak)
                if rate == 0 { rate = buffer.format.sampleRate }
            }
        }

        var summary: String {
            lock.withLock {
                let seconds = rate > 0 ? Double(frames) / rate : 0
                let wall = Date().timeIntervalSince(startedAt)
                return "\(buffers) buffers, \(String(format: "%.2f", seconds)) s at \(Int(rate)) Hz in \(String(format: "%.2f", wall)) s, peak \(String(format: "%.3f", peakValue))"
            }
        }
    }
}

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let description = sampleBuffer.formatDescription,
            var streamDescription = description.audioStreamBasicDescription
        else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
            let format = AVAudioFormat(streamDescription: &streamDescription),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        stats.record(buffer)
        handler?(buffer)
    }
}
