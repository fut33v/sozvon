import Foundation

struct RecordingSession: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    let audioFileName: String
    var transcript: String
    let sourceRawValue: String
    let languageRawValue: String
    var durationSeconds: TimeInterval

    var source: AudioSource {
        AudioSource(rawValue: sourceRawValue) ?? .callAudio
    }

    var language: SpeechLanguage {
        SpeechLanguage(rawValue: languageRawValue) ?? .russian
    }
}
