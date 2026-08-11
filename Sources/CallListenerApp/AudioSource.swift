import Foundation

enum AudioSource: String, CaseIterable, Identifiable {
    case callAudio = "callAudio"
    case microphone = "microphone"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .callAudio:
            return "Звонок"
        case .microphone:
            return "Микрофон"
        }
    }

    var listeningStatus: String {
        switch self {
        case .callAudio:
            return "Слушаю звонок"
        case .microphone:
            return "Слушаю микрофон"
        }
    }
}
