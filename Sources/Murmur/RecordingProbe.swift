import Foundation

/// Headless check of the live audio path: opens the configured microphone
/// exactly as a dictation would, records for a few seconds, and transcribes
/// the result. Run with `Murmur --record-test [seconds]`. Because a bundle
/// launched with `open` cannot print, every line also goes to the log file.
enum RecordingProbe {
    static func run(seconds: Double) async -> String {
        var lines = [String]()
        func note(_ line: String) {
            lines.append(line)
            Log.info("Murmur: record-test: \(line)")
        }

        guard await AudioRecorder.requestPermission() else {
            note("microphone permission not granted")
            return lines.joined(separator: "\n")
        }
        let device = AudioDevices.resolveRecordingDevice()
        note("recording \(seconds) s from \(device?.name ?? "system default input")")

        let recorder = AudioRecorder()
        let relay = AudioRelay()
        recorder.onBuffer = { relay.push($0) }
        let clock = Launch.Stopwatch()
        do {
            try await recorder.start(device: device)
        } catch {
            note("could not open the microphone: \(error.localizedDescription)")
            return lines.joined(separator: "\n")
        }
        note("microphone open after \(clock.ms) ms")

        let session: StreamingTranscriber
        do {
            session = try await StreamingTranscriber(contextualStrings: DictionaryStore.currentTerms())
            try await session.begin()
        } catch {
            recorder.stop()
            note("speech recognition failed to start: \(error)")
            return lines.joined(separator: "\n")
        }
        relay.attach(session)

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        recorder.stop()
        do {
            let text = try await session.finish()
            note("transcript: \(text.isEmpty ? "(nothing recognised)" : text)")
        } catch {
            note("transcription failed: \(error)")
        }
        return lines.joined(separator: "\n")
    }
}
