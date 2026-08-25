import Foundation

final class RecordingStore {
    private let fileManager: FileManager
    private let rootURL: URL
    private let recordingsURL: URL
    private let indexURL: URL
    private let liveTranscriptsURL: URL
    private let liveTranscriptSessionsURL: URL
    private let currentTranscriptURL: URL
    private let currentSessionMetadataURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser

        rootURL = appSupportURL.appendingPathComponent("SOZVON", isDirectory: true)
        recordingsURL = rootURL.appendingPathComponent("Recordings", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("sessions.json")
        liveTranscriptsURL = Self.defaultLiveTranscriptsURL(fileManager: fileManager)
        liveTranscriptSessionsURL = liveTranscriptsURL.appendingPathComponent("sessions", isDirectory: true)
        currentTranscriptURL = liveTranscriptsURL.appendingPathComponent("current-transcript.txt")
        currentSessionMetadataURL = liveTranscriptsURL.appendingPathComponent("current-session.json")

        try? fileManager.createDirectory(
            at: recordingsURL,
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: liveTranscriptSessionsURL,
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

    func saveSessions(
        _ sessions: [RecordingSession],
        activeSessionID: RecordingSession.ID? = nil,
        currentSessionID: RecordingSession.ID? = nil
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: indexURL, options: .atomic)

        writeLiveTranscriptFiles(
            for: sessions,
            activeSessionID: activeSessionID,
            currentSessionID: currentSessionID
        )
    }

    func audioURL(for session: RecordingSession) -> URL {
        recordingsURL.appendingPathComponent(session.audioFileName)
    }

    func transcriptURL(for session: RecordingSession) -> URL {
        transcriptDirectoryURL(for: session).appendingPathComponent("transcript.txt")
    }

    func makeTranscriptDirectoryName(
        title: String,
        createdAt: Date,
        id: UUID
    ) -> String {
        let datePrefix = Self.transcriptDirectoryDateFormatter.string(from: createdAt)
        let titlePart = Self.safeFileComponent(title.isEmpty ? "session" : title)
        let idPart = id.uuidString.prefix(8)

        return "\(datePrefix)_\(titlePart)_\(idPart)"
    }

    func deleteAudio(for session: RecordingSession) {
        try? fileManager.removeItem(at: audioURL(for: session))
    }

    func deleteTranscriptFiles(for session: RecordingSession) {
        try? fileManager.removeItem(at: transcriptDirectoryURL(for: session))
    }

    private func transcriptDirectoryURL(for session: RecordingSession) -> URL {
        let directoryName = session.transcriptDirectoryName
            ?? makeTranscriptDirectoryName(
                title: session.title,
                createdAt: session.createdAt,
                id: session.id
            )

        return liveTranscriptSessionsURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    private func writeLiveTranscriptFiles(
        for sessions: [RecordingSession],
        activeSessionID: RecordingSession.ID?,
        currentSessionID: RecordingSession.ID?
    ) {
        for session in sessions {
            writeSessionTranscriptFiles(
                for: session,
                isActive: session.id == activeSessionID
            )
        }

        guard let currentSessionID,
              let currentSession = sessions.first(where: { $0.id == currentSessionID }) else {
            try? fileManager.removeItem(at: currentTranscriptURL)
            try? fileManager.removeItem(at: currentSessionMetadataURL)
            return
        }

        writeString(currentSession.transcript, to: currentTranscriptURL)
        writeMetadata(
            for: currentSession,
            isActive: currentSession.id == activeSessionID,
            to: currentSessionMetadataURL
        )
    }

    private func writeSessionTranscriptFiles(
        for session: RecordingSession,
        isActive: Bool
    ) {
        let directoryURL = transcriptDirectoryURL(for: session)

        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        writeString(session.transcript, to: transcriptURL(for: session))
        writeMetadata(
            for: session,
            isActive: isActive,
            to: directoryURL.appendingPathComponent("session.json")
        )
    }

    private func writeMetadata(
        for session: RecordingSession,
        isActive: Bool,
        to url: URL
    ) {
        let metadata = TranscriptSessionMetadata(
            id: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            source: session.sourceRawValue,
            language: session.languageRawValue,
            isActive: isActive,
            durationSeconds: session.durationSeconds,
            audioPath: audioURL(for: session).path,
            transcriptPath: transcriptURL(for: session).path
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func writeString(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }

        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func defaultLiveTranscriptsURL(fileManager: FileManager) -> URL {
        let bundleURL = Bundle.main.bundleURL

        if bundleURL.pathExtension == "app" {
            let parentURL = bundleURL.deletingLastPathComponent()
            if parentURL.lastPathComponent == "dist" {
                return parentURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("LiveTranscripts", isDirectory: true)
            }
        }

        let currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let packageURL = currentDirectoryURL.appendingPathComponent("Package.swift")

        if fileManager.fileExists(atPath: packageURL.path) {
            return currentDirectoryURL.appendingPathComponent("LiveTranscripts", isDirectory: true)
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("СОЗВОН", isDirectory: true)
            .appendingPathComponent("LiveTranscripts", isDirectory: true)
    }

    private static func safeFileComponent(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var previousWasSeparator = false

        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.append(Character(scalar))
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }

            if result.count >= 48 {
                break
            }
        }

        let safeResult = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return safeResult.isEmpty ? "session" : safeResult
    }

    private static let transcriptDirectoryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()
}

private struct TranscriptSessionMetadata: Encodable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let source: String
    let language: String
    let isActive: Bool
    let durationSeconds: TimeInterval
    let audioPath: String
    let transcriptPath: String
}
