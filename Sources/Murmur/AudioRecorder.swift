import AVFoundation

/// Captures microphone audio with AVAudioEngine and hands raw PCM buffers
/// to whoever set `onBuffer`. Buffers arrive on the audio render thread.
final class AudioRecorder {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()

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

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onBuffer = nil
    }
}
