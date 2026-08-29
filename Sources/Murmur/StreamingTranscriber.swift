import AVFoundation
import Foundation
import Speech

/// One dictation's worth of on-device speech-to-text, built on macOS 26's
/// SpeechAnalyzer/SpeechTranscriber. Buffers are fed in as they arrive from
/// the microphone; `finish()` flushes the analyzer and returns the final text.
final class StreamingTranscriber {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private let collector: Task<String, Error>
    private var converter: AVAudioConverter?

    init() async throws {
        let locale = await Self.pickLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],  // finalised results only; no live preview needed
            attributeOptions: [])
        self.transcriber = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation

        collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Thread-safe entry point; called from the audio render thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, analyzerFormat != buffer.format else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        do {
            let converted = try convert(buffer, to: analyzerFormat)
            input.yield(AnalyzerInput(buffer: converted))
        } catch {
            Log.info("Murmur: audio conversion failed: \(error)")
        }
    }

    func finish() async throws -> String {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    // MARK: - Locale and model assets

    static func pickLocale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if supported.contains(where: {
            $0.identifier(.bcp47) == current.identifier(.bcp47)
        }) {
            return current
        }
        return Locale(identifier: "en_US")
    }

    /// Downloads the on-device speech model if it is not installed yet.
    /// Returns true when a download was actually needed.
    static func ensureModel(onDownloadStart: @escaping () -> Void) async throws -> Bool {
        let locale = await pickLocale()
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard
            let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
        else { return false }
        onDownloadStart()
        try await request.downloadAndInstall()
        return true
    }

    // MARK: - Diagnostics

    static func diagnostics() async -> String {
        var lines = [String]()
        let current = Locale.current
        lines.append("Current locale: \(current.identifier) (bcp47: \(current.identifier(.bcp47)))")

        let supported = await SpeechTranscriber.supportedLocales
        lines.append("Supported locales (\(supported.count)): \(supported.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", "))")

        let installed = await SpeechTranscriber.installedLocales
        lines.append("Installed locales: \(installed.map { $0.identifier(.bcp47) }.joined(separator: ", "))")

        let picked = await pickLocale()
        lines.append("Picked locale: \(picked.identifier(.bcp47))")

        let reservedLocales = await AssetInventory.reservedLocales
        lines.append("Reserved locales: \(reservedLocales.map { $0.identifier(.bcp47) }.joined(separator: ", ")) (max \(AssetInventory.maximumReservedLocales))")

        let transcriber = SpeechTranscriber(
            locale: picked, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let status = await AssetInventory.status(forModules: [transcriber])
        lines.append("Asset status: \(status)")

        do {
            let reserved = try await AssetInventory.reserve(locale: picked)
            lines.append("Reserve returned: \(reserved)")
        } catch {
            lines.append("Reserve threw: \(error)")
        }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
            {
                lines.append("Installation request obtained; downloading…")
                try await request.downloadAndInstall()
                lines.append("Download and install: OK")
            } else {
                lines.append("Installation request: nil (nothing to install)")
            }
        } catch {
            lines.append("Installation threw: \(String(reflecting: error))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Format conversion

    private func convert(
        _ buffer: AVAudioPCMBuffer, to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else {
            throw NSError(
                domain: "Murmur", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No audio converter available"])
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NSError(
                domain: "Murmur", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate conversion buffer"])
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return output
    }
}
