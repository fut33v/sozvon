import Foundation

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case russian = "ru-RU"
    case englishUS = "en-US"
    case englishUK = "en-GB"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .russian:
            return "Русский"
        case .englishUS:
            return "English US"
        case .englishUK:
            return "English UK"
        }
    }

    /// ISO-639-1 code understood by whisper.cpp `--language`.
    var whisperCode: String {
        switch self {
        case .russian:
            return "ru"
        case .englishUS, .englishUK:
            return "en"
        }
    }
}
