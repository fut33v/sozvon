import Foundation

enum TranscriptKind: String, Codable {
    case live
    case whisper
}

struct RecordingSession: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    /// System-audio recording (the other side of the call). Kept as `audioFileName`
    /// for backwards compatibility with sessions recorded before dual capture.
    let audioFileName: String
    /// Microphone recording (your own voice). Absent for sessions recorded before dual capture.
    var micAudioFileName: String?
    var transcriptDirectoryName: String?
    var transcript: String
    var segments: [TranscriptSegment]?
    var whisperTranscript: String?
    var whisperSegments: [TranscriptSegment]?
    var preferredTranscriptKind: TranscriptKind?
    let sourceRawValue: String
    let languageRawValue: String
    var durationSeconds: TimeInterval

    var source: AudioSource {
        AudioSource(rawValue: sourceRawValue) ?? .callAudio
    }

    var language: SpeechLanguage {
        SpeechLanguage(rawValue: languageRawValue) ?? .russian
    }

    var hasWhisperTranscript: Bool {
        !(whisperTranscript ?? "").isEmpty
    }

    /// Transcript shown in the UI and written to `transcript.txt`.
    var displayTranscript: String {
        if preferredTranscriptKind == .whisper, let whisperTranscript, !whisperTranscript.isEmpty {
            return whisperTranscript
        }

        return transcript
    }
}
