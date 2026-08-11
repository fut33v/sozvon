import Foundation

final class RecordingStore {
    private let fileManager: FileManager
    private let rootURL: URL
    private let recordingsURL: URL
    private let indexURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser

        rootURL = appSupportURL.appendingPathComponent("SOZVON", isDirectory: true)
        recordingsURL = rootURL.appendingPathComponent("Recordings", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("sessions.json")

        try? fileManager.createDirectory(
            at: recordingsURL,
            withIntermediateDirectories: true
        )
    }

    func loadSessions() -> [RecordingSession] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let sessions = try? decoder.decode([RecordingSession].self, from: data) else {
            return []
        }

        return sessions.sorted { $0.createdAt > $1.createdAt }
    }

    func saveSessions(_ sessions: [RecordingSession]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func audioURL(for session: RecordingSession) -> URL {
        recordingsURL.appendingPathComponent(session.audioFileName)
    }

    func deleteAudio(for session: RecordingSession) {
        try? fileManager.removeItem(at: audioURL(for: session))
    }
}
