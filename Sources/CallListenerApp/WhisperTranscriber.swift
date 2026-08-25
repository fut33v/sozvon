import AVFoundation
import Foundation

enum WhisperError: LocalizedError {
    case binaryMissing(URL)
    case modelMissing(URL)
    case conversionFailed(String)
    case processFailed(Int32, String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let url):
            return "Whisper не настроен: нет \(url.path). Запустите Scripts/setup_whisper.sh"
        case .modelMissing(let url):
            return "Нет модели Whisper в \(url.path). Запустите Scripts/setup_whisper.sh"
        case .conversionFailed(let message):
            return "Не удалось подготовить аудио для Whisper: \(message)"
        case .processFailed(let code, let message):
            let tail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty
                ? "Whisper завершился с кодом \(code)"
                : "Whisper завершился с кодом \(code): \(tail)"
        case .emptyResult:
            return "Whisper не вернул текст"
        }
    }
}

/// Runs whisper.cpp over finished recordings to produce a higher-quality transcript
/// than the live Apple Speech pass.
struct WhisperTranscriber {
    struct Input: Sendable {
        let audioURL: URL
        let speaker: TranscriptSpeaker
    }

    static var rootURL: URL {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return appSupportURL
            .appendingPathComponent("SOZVON", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
    }

    static var binaryURL: URL {
        if let override = ProcessInfo.processInfo.environment["SOZVON_WHISPER_CLI"] {
            return URL(fileURLWithPath: override)
        }

        return rootURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("whisper-cli")
    }

    static var modelsURL: URL {
        rootURL.appendingPathComponent("models", isDirectory: true)
    }

    static var vadModelURL: URL? {
        let url = modelsURL.appendingPathComponent("ggml-silero-v5.1.2.bin")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func resolvedModelURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["SOZVON_WHISPER_MODEL"] {
            return URL(fileURLWithPath: override)
        }

        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: modelsURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        // Prefer the largest non-VAD model available: quality tracks size closely enough.
        let models = candidates
            .filter { $0.pathExtension == "bin" && !$0.lastPathComponent.contains("silero") }
            .sorted { lhs, rhs in
                let lhsSize = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let rhsSize = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return lhsSize > rhsSize
            }

        guard let model = models.first else {
            throw WhisperError.modelMissing(modelsURL)
        }

        return model
    }

    static var isConfigured: Bool {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else { return false }
        return (try? resolvedModelURL()) != nil
    }

    /// Transcribes each channel separately, then merges by timestamp so speaker
    /// labels survive into the final text.
    static func transcribe(
        inputs: [Input],
        language: SpeechLanguage,
        vocabulary: [String],
        progress: @escaping (String) -> Void
    ) throws -> [TranscriptSegment] {
        let binary = binaryURL

        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw WhisperError.binaryMissing(binary)
        }

        let model = try resolvedModelURL()
        let workURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sozvon-whisper-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workURL) }

        var segments: [TranscriptSegment] = []

        for input in inputs {
            guard FileManager.default.fileExists(atPath: input.audioURL.path) else { continue }

            progress("Whisper: готовлю аудио (\(input.speaker.title))")

            let wavURL = workURL.appendingPathComponent("\(input.speaker.rawValue).wav")
            try convertToWhisperWAV(source: input.audioURL, destination: wavURL)

            progress("Whisper: распознаю (\(input.speaker.title))")

            let outputBase = workURL.appendingPathComponent(input.speaker.rawValue)
            try run(
                binary: binary,
                model: model,
                wavURL: wavURL,
                outputBase: outputBase,
                language: language,
                vocabulary: vocabulary
            )

            let jsonURL = URL(fileURLWithPath: outputBase.path + ".json")
            segments.append(
                contentsOf: try parseSegments(jsonURL: jsonURL, speaker: input.speaker)
            )
        }

        guard !segments.isEmpty else { throw WhisperError.emptyResult }

        return segments.sorted { $0.startSeconds < $1.startSeconds }
    }

    private static func run(
        binary: URL,
        model: URL,
        wavURL: URL,
        outputBase: URL,
        language: SpeechLanguage,
        vocabulary: [String]
    ) throws {
        var arguments = [
            "--model", model.path,
            "--file", wavURL.path,
            "--language", language.whisperCode,
            "--output-json",
            "--output-file", outputBase.path,
            "--no-prints",
            "--threads", String(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        ]

        // Silence between utterances is where Whisper likes to hallucinate;
        // VAD trims it out before decoding.
        if let vadModelURL {
            arguments.append(contentsOf: ["--vad", "--vad-model", vadModelURL.path])
        }

        let prompt = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        if !prompt.isEmpty {
            arguments.append(contentsOf: ["--prompt", prompt])
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw WhisperError.processFailed(
                process.terminationStatus,
                String(data: errorData, encoding: .utf8) ?? ""
            )
        }
    }

    private static func parseSegments(
        jsonURL: URL,
        speaker: TranscriptSpeaker
    ) throws -> [TranscriptSegment] {
        let data = try Data(contentsOf: jsonURL)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcription = root["transcription"] as? [[String: Any]] else {
            return []
        }

        return transcription.compactMap { entry in
            guard let text = (entry["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }

            let offsets = entry["offsets"] as? [String: Any]
            let fromMS = (offsets?["from"] as? NSNumber)?.doubleValue ?? 0
            let toMS = (offsets?["to"] as? NSNumber)?.doubleValue ?? fromMS

            return TranscriptSegment(
                speaker: speaker,
                startSeconds: fromMS / 1000,
                endSeconds: toMS / 1000,
                text: text
            )
        }
    }

    /// whisper.cpp only accepts 16 kHz mono PCM WAV.
    private static func convertToWhisperWAV(source: URL, destination: URL) throws {
        let sourceFile = try AVAudioFile(forReading: source)
        let sourceFormat = sourceFile.processingFormat

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperError.conversionFailed("не удалось создать формат 16 кГц моно")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WhisperError.conversionFailed("не удалось создать конвертер")
        }

        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let chunkFrames: AVAudioFrameCount = 16_384

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: chunkFrames
        ) else {
            throw WhisperError.conversionFailed("не удалось выделить буфер")
        }

        var reachedEnd = false

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: chunkFrames
            ) else {
                throw WhisperError.conversionFailed("не удалось выделить буфер")
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try sourceFile.read(into: inputBuffer)
                } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw WhisperError.conversionFailed(conversionError.localizedDescription)
            }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }

            if status == .endOfStream || status == .error {
                break
            }
        }
    }
}
