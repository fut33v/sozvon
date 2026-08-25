import Foundation

enum AudioSource: String, CaseIterable, Identifiable {
    case callAndMicrophone = "callAndMicrophone"
    case callAudio = "callAudio"
    case microphone = "microphone"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .callAndMicrophone:
            return "Оба"
        case .callAudio:
            return "Звонок"
        case .microphone:
            return "Микрофон"
        }
    }

    var listeningStatus: String {
        switch self {
        case .callAndMicrophone:
            return "Слушаю звонок и микрофон"
        case .callAudio:
            return "Слушаю звонок"
        case .microphone:
            return "Слушаю микрофон"
        }
    }

    var connectingStatus: String {
        switch self {
        case .callAndMicrophone:
            return "Подключаю звонок и микрофон"
        case .callAudio:
            return "Подключаю звук звонка"
        case .microphone:
            return "Подключаю микрофон"
        }
    }

    var capturesSystemAudio: Bool {
        self == .callAndMicrophone || self == .callAudio
    }

    var capturesMicrophone: Bool {
        self == .callAndMicrophone || self == .microphone
    }

    /// Speaker labels are only meaningful when both channels are recorded separately.
    var labelsSpeakers: Bool {
        self == .callAndMicrophone
    }
}
