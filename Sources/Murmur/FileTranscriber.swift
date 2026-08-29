import AVFoundation
import Foundation

/// Headless test harness: runs an audio file through the same
/// StreamingTranscriber the live app uses. Lets us verify the speech
/// pipeline from the terminal with no microphone or permissions involved.
enum FileTranscriber {
    static func transcribe(url: URL) async throws -> String {
        func log(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
        do {
            _ = try await StreamingTranscriber.ensureModel { log("Downloading speech model…") }
        } catch {
            throw Labelled("ensureModel", error)
        }
        log("Model ready")

        let session: StreamingTranscriber
        do {
            session = try await StreamingTranscriber()
        } catch {
            throw Labelled("session init", error)
        }
        log("Session started")

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        // AVAudioFile.read(into:) can throw a bogus error at end-of-file,
        // so stop by frame position instead of reading until it complains.
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                break
            }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            session.feed(buffer)
        }
        log("Audio fed")

        do {
            return try await session.finish()
        } catch {
            throw Labelled("finish", error)
        }
    }

    private static func Labelled(_ stage: String, _ error: Error) -> NSError {
        NSError(
            domain: "Murmur.FileTranscriber", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "stage '\(stage)': \(String(reflecting: error))"
            ])
    }
}
