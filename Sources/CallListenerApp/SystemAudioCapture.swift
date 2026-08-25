import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
    case noDisplay
    case missingAudioFormat
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "Не найден экран для захвата системного звука"
        case .missingAudioFormat:
            return "Не удалось прочитать формат системного звука"
        case .unsupportedAudioFormat:
            return "Формат системного звука не поддерживается"
        }
    }
}

final class SystemAudioCapture: NSObject {
    static let speechFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private static let captureSampleRate = 48_000
    private static let captureChannelCount = 2

    private let outputQueue = DispatchQueue(label: "local.call-listener.system-audio")
    private let appendSpeechBuffer: (AVAudioPCMBuffer) -> Void
    private let appendRecordingBuffer: (AVAudioPCMBuffer) -> Void
    private let reportError: (String) -> Void
    private var stream: SCStream?
    private var audioConverter: AVAudioConverter?
    private let targetFormat = SystemAudioCapture.speechFormat

    init(
        appendSpeechBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        appendRecordingBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        reportError: @escaping (String) -> Void
    ) {
        self.appendSpeechBuffer = appendSpeechBuffer
        self.appendRecordingBuffer = appendRecordingBuffer
        self.reportError = reportError
    }

    func start() async throws {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter { $0.processID == currentPID }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = Self.captureSampleRate
        configuration.channelCount = Self.captureChannelCount
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)

        self.stream = stream

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil

        stream.stopCapture { _ in }
    }

    private func handle(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        do {
            let sourceBuffer = try makeSourceBuffer(from: sampleBuffer)
            if sourceBuffer.frameLength > 0 {
                appendRecordingBuffer(sourceBuffer)
            }

            let speechBuffer = try makeSpeechBuffer(from: sourceBuffer)
            if speechBuffer.frameLength > 0 {
                appendSpeechBuffer(speechBuffer)
            }
        } catch {
            reportError(error.localizedDescription)
        }
    }

    private func makeSourceBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = sampleBuffer.audioFormat else {
            throw SystemAudioCaptureError.missingAudioFormat
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw SystemAudioCaptureError.unsupportedAudioFormat
        }

        sourceBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )

        guard copyStatus == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(copyStatus),
                userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать аудиоданные"]
            )
        }

        return sourceBuffer
    }

    private func makeSpeechBuffer(from sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let sourceFormat = sourceBuffer.format

        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.commonFormat == targetFormat.commonFormat {
            return sourceBuffer
        }

        guard let converter = converter(from: sourceFormat) else {
            throw SystemAudioCaptureError.unsupportedAudioFormat
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let targetFrames = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 32
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrames) else {
            throw SystemAudioCaptureError.unsupportedAudioFormat
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error {
            throw conversionError ?? SystemAudioCaptureError.unsupportedAudioFormat
        }

        return targetBuffer
    }

    private func converter(from sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        if let audioConverter,
           audioConverter.inputFormat.sampleRate == sourceFormat.sampleRate,
           audioConverter.inputFormat.channelCount == sourceFormat.channelCount,
           audioConverter.inputFormat.commonFormat == sourceFormat.commonFormat {
            return audioConverter
        }

        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        audioConverter = converter
        return converter
    }
}

extension SystemAudioCapture: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        handle(sampleBuffer: sampleBuffer)
    }
}

extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        reportError(error.localizedDescription)
    }
}

private extension CMSampleBuffer {
    var audioFormat: AVAudioFormat? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        return AVAudioFormat(streamDescription: streamDescription)
    }
}
