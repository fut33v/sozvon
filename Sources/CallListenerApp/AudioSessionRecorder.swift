import AudioToolbox
import AVFoundation

final class AudioSessionRecorder {
    private let queue = DispatchQueue(label: "local.call-listener.audio-recorder")
    private let url: URL
    private var audioFile: AVAudioFile?
    private var isStopped = false
    private let reportError: (String) -> Void

    init(url: URL, format: AVAudioFormat? = nil, reportError: @escaping (String) -> Void) throws {
        self.url = url
        self.reportError = reportError

        if let format {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copiedBuffer = buffer.deepCopy() else { return }

        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }

            do {
                if self.audioFile == nil {
                    self.audioFile = try AVAudioFile(
                        forWriting: self.url,
                        settings: copiedBuffer.format.settings
                    )
                }

                guard let audioFile = self.audioFile else { return }
                try audioFile.write(from: copiedBuffer)
            } catch {
                self.reportError("Не удалось записать аудио")
            }
        }
    }

    func stop() {
        queue.sync {
            // Without this flag a late buffer would recreate the file and wipe the take.
            isStopped = true
            audioFile = nil
        }
    }
}

private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameLength
        ) else {
            return nil
        }

        copiedBuffer.frameLength = frameLength

        let mutableSourceAudioBufferList = UnsafeMutablePointer(mutating: audioBufferList)
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(mutableSourceAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)

        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else {
                continue
            }

            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copiedBuffer
    }
}
