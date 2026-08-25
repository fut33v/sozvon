import AppKit
import AVFoundation
import Speech
import SwiftUI

final class SpeechTranscriber: NSObject, ObservableObject, @unchecked Sendable {
    @Published var selectedAudioSource: AudioSource = .callAudio
    @Published var selectedLanguage: SpeechLanguage = .russian
    @Published var selectedSessionID: RecordingSession.ID? {
        didSet {
            guard oldValue != selectedSessionID else { return }

            Task { @MainActor in
                if playbackSessionID != selectedSessionID {
                    stopPlayback(resetPosition: true)
                }
            }
        }
    }
    @Published private(set) var sessions: [RecordingSession] = []
    @Published private(set) var activeSessionID: RecordingSession.ID?
    @Published private(set) var statusText = "Проверяю доступ"
    @Published private(set) var canStart = false
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var copyButtonTitle = "Скопировать"
    @Published private(set) var playbackSessionID: RecordingSession.ID?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackCurrentTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0

    private let store = RecordingStore()
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var systemAudioCapture: SystemAudioCapture?
    private var audioRecorder: AudioSessionRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var copyResetWorkItem: DispatchWorkItem?
    private var sharedCurrentSessionID: RecordingSession.ID?

    override init() {
        super.init()

        sessions = store.loadSessions()
        migrateTranscriptDirectoriesIfNeeded()
        selectedSessionID = sessions.first?.id
        sharedCurrentSessionID = sessions.first?.id

        if !sessions.isEmpty {
            store.saveSessions(
                sessions,
                activeSessionID: activeSessionID,
                currentSessionID: sharedCurrentSessionID
            )
        }
    }

    var isActive: Bool {
        isListening || isStarting
    }

    var selectedSession: RecordingSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var transcript: String {
        selectedSession?.transcript ?? ""
    }

    var selectedAudioURL: URL? {
        guard let selectedSession else { return nil }
        return store.audioURL(for: selectedSession)
    }

    var selectedTranscriptURL: URL? {
        guard let selectedSession else { return nil }
        return store.transcriptURL(for: selectedSession)
    }

    var selectedTranscriptPath: String {
        selectedTranscriptURL?.path ?? ""
    }

    var canPlaySelectedAudio: Bool {
        guard let selectedSession,
              selectedSession.id != activeSessionID else {
            return false
        }

        return FileManager.default.fileExists(atPath: store.audioURL(for: selectedSession).path)
    }

    var statusColor: Color {
        if isActive {
            return .red
        }
        return canStart ? .secondary : .orange
    }

    var wordCountText: String {
        let words = transcript
            .split { $0.isWhitespace || $0.isNewline }
            .count

        switch words {
        case 0:
            return "0 слов"
        case 1:
            return "1 слово"
        case 2...4:
            return "\(words) слова"
        default:
            return "\(words) слов"
        }
    }

    @MainActor
    func refreshPermissionStatus() async {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch (speechStatus, microphoneStatus) {
        case (.authorized, .authorized):
            statusText = "Готов к прослушиванию"
            canStart = true
        case (.authorized, .notDetermined), (.notDetermined, .authorized), (.notDetermined, .notDetermined):
            statusText = "Готов к прослушиванию"
            canStart = true
        case (_, .denied), (_, .restricted):
            statusText = "Нет доступа к микрофону"
            canStart = false
        case (.denied, _), (.restricted, _):
            statusText = "Нет доступа к распознаванию речи"
            canStart = false
        @unknown default:
            statusText = "Не удалось проверить доступ"
            canStart = false
        }
    }

    @MainActor
    func requestPermissions() async -> Bool {
        let speechStatus = await requestSpeechAuthorizationIfNeeded()
        let microphoneAllowed = await requestMicrophoneAuthorizationIfNeeded()

        switch (speechStatus, microphoneAllowed) {
        case (.authorized, true):
            statusText = "Готов к прослушиванию"
            canStart = true
            return true
        case (.authorized, false):
            statusText = "Нет доступа к микрофону"
            canStart = false
            return false
        case (.denied, _), (.restricted, _):
            statusText = "Нет доступа к распознаванию речи"
            canStart = false
            return false
        case (.notDetermined, _):
            statusText = "Доступ к распознаванию речи не выбран"
            canStart = false
            return false
        @unknown default:
            statusText = "Не удалось проверить доступ"
            canStart = false
            return false
        }
    }

    @MainActor
    func toggleListening() {
        if isActive {
            stopListening()
        } else {
            Task {
                await startListening()
            }
        }
    }

    @MainActor
    func startListening() async {
        guard canStart else {
            _ = await requestPermissions()
            return
        }

        guard await requestPermissions() else { return }

        stopPlayback(resetPosition: true)
        stopCurrentRecognition(finalizeSession: true)
        isStarting = true
        statusText = selectedAudioSource == .callAudio ? "Подключаю звук звонка" : "Подключаю микрофон"

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage.rawValue)) else {
            statusText = "Этот язык не поддерживается"
            canStart = false
            isStarting = false
            return
        }

        guard recognizer.isAvailable else {
            statusText = "Распознавание речи сейчас недоступно"
            isStarting = false
            return
        }

        let session = createSession()

        speechRecognizer = recognizer
        speechRecognizer?.delegate = self

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                DispatchQueue.main.async {
                    self.updateActiveTranscript(result.bestTranscription.formattedString)
                }
            }

            if let error {
                DispatchQueue.main.async {
                    guard self.activeSessionID != nil || self.isActive else { return }
                    self.statusText = error.localizedDescription
                    self.stopCurrentRecognition(finalizeSession: true)
                }
            } else if result?.isFinal == true {
                DispatchQueue.main.async {
                    self.stopCurrentRecognition(finalizeSession: true)
                    self.statusText = "Готов к прослушиванию"
                }
            }
        }

        do {
            switch selectedAudioSource {
            case .callAudio:
                try await startSystemAudioCapture(for: session, request: request)
            case .microphone:
                try startMicrophoneCapture(for: session, request: request)
            }

            isStarting = false
            isListening = true
            statusText = selectedAudioSource.listeningStatus
        } catch {
            let failedSessionID = session.id
            stopCurrentRecognition(finalizeSession: false)
            discardSession(withID: failedSessionID)
            statusText = friendlyCaptureError(error)
        }
    }

    @MainActor
    func stopListening() {
        stopCurrentRecognition(finalizeSession: true)
        statusText = canStart ? "Готов к прослушиванию" : statusText
    }

    @MainActor
    func clearTranscript() {
        guard let selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else {
            return
        }

        sessions[index].transcript = ""
        sessions[index].updatedAt = Date()
        persistSessions()
    }

    @MainActor
    func copyTranscript() {
        guard !transcript.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)

        copyResetWorkItem?.cancel()
        copyButtonTitle = "Скопировано"

        let item = DispatchWorkItem { [weak self] in
            self?.copyButtonTitle = "Скопировать"
        }
        copyResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    @MainActor
    func renameSelectedSession(to title: String) {
        guard let selectedSessionID else { return }
        renameSession(withID: selectedSessionID, to: title)
    }

    @MainActor
    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            playSelectedAudio()
        }
    }

    @MainActor
    func playSelectedAudio() {
        guard let selectedSession,
              selectedSession.id != activeSessionID else {
            return
        }

        do {
            if playbackSessionID != selectedSession.id {
                try loadPlayer(for: selectedSession)
            }

            audioPlayer?.play()
            isPlaying = true
            startPlaybackTimer()
        } catch {
            statusText = "Не удалось открыть запись"
            stopPlayback(resetPosition: true)
        }
    }

    @MainActor
    func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
        stopPlaybackTimer()
        updatePlaybackTime()
    }

    @MainActor
    func seekPlayback(to time: TimeInterval) {
        guard let selectedSession,
              selectedSession.id != activeSessionID else {
            return
        }

        do {
            if playbackSessionID != selectedSession.id {
                try loadPlayer(for: selectedSession)
            }
        } catch {
            statusText = "Не удалось открыть запись"
            stopPlayback(resetPosition: true)
            return
        }

        guard let audioPlayer else { return }

        audioPlayer.currentTime = min(max(0, time), audioPlayer.duration)
        updatePlaybackTime()
    }

    @MainActor
    func openSelectedAudio() {
        guard let selectedAudioURL else { return }
        NSWorkspace.shared.open(selectedAudioURL)
    }

    @MainActor
    func revealSelectedAudioInFinder() {
        guard let selectedAudioURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedAudioURL])
    }

    @MainActor
    func copySelectedAudioPath() {
        guard let selectedAudioURL else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedAudioURL.path, forType: .string)
        statusText = "Путь к записи скопирован"
    }

    @MainActor
    func copySelectedTranscriptPath() {
        guard let selectedTranscriptURL else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedTranscriptURL.path, forType: .string)
        statusText = "Путь к txt скопирован"
    }

    @MainActor
    func audioURL(for session: RecordingSession) -> URL {
        store.audioURL(for: session)
    }

    private func startMicrophoneCapture(
        for session: RecordingSession,
        request: SFSpeechAudioBufferRecognitionRequest
    ) throws {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.channelCount > 0 else {
            throw NSError(
                domain: "CallListener",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Микрофон не найден"]
            )
        }

        let recorder = try makeRecorder(for: session, format: recordingFormat)
        audioRecorder = recorder

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
            recorder.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startSystemAudioCapture(
        for session: RecordingSession,
        request: SFSpeechAudioBufferRecognitionRequest
    ) async throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(
                domain: "CallListener",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Для захвата звука звонка нужна macOS 13 или новее"]
            )
        }

        let recorder = try makeRecorder(for: session, format: nil)
        audioRecorder = recorder

        let capture = SystemAudioCapture { buffer in
            request.append(buffer)
        } appendRecordingBuffer: { buffer in
            recorder.append(buffer)
        } reportError: { [weak self] message in
            DispatchQueue.main.async {
                self?.statusText = message
            }
        }

        systemAudioCapture = capture
        try await capture.start(includeMicrophone: false)
    }

    private func makeRecorder(
        for session: RecordingSession,
        format: AVAudioFormat?
    ) throws -> AudioSessionRecorder {
        try AudioSessionRecorder(
            url: store.audioURL(for: session),
            format: format
        ) { [weak self] message in
            DispatchQueue.main.async {
                self?.statusText = message
            }
        }
    }

    @MainActor
    private func createSession() -> RecordingSession {
        let now = Date()
        let id = UUID()
        let title = Self.defaultSessionTitle(for: now)
        let session = RecordingSession(
            id: id,
            title: title,
            createdAt: now,
            updatedAt: now,
            audioFileName: "\(id.uuidString).caf",
            transcriptDirectoryName: store.makeTranscriptDirectoryName(
                title: title,
                createdAt: now,
                id: id
            ),
            transcript: "",
            sourceRawValue: selectedAudioSource.rawValue,
            languageRawValue: selectedLanguage.rawValue,
            durationSeconds: 0
        )

        sessions.insert(session, at: 0)
        selectedSessionID = id
        activeSessionID = id
        sharedCurrentSessionID = id
        persistSessions()

        return session
    }

    @MainActor
    private func updateActiveTranscript(_ transcript: String) {
        guard let activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else {
            return
        }

        sessions[index].transcript = transcript
        sessions[index].updatedAt = Date()
        persistSessions()
    }

    @MainActor
    private func renameSession(withID id: RecordingSession.ID, to title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        sessions[index].title = title
        sessions[index].updatedAt = Date()
        persistSessions()
    }

    @MainActor
    private func discardSession(withID id: RecordingSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        let session = sessions.remove(at: index)
        store.deleteAudio(for: session)
        store.deleteTranscriptFiles(for: session)

        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }

        if activeSessionID == id {
            activeSessionID = nil
        }

        if sharedCurrentSessionID == id {
            sharedCurrentSessionID = sessions.first?.id
        }

        persistSessions()
    }

    @MainActor
    private func finishActiveSession() {
        guard let activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else {
            return
        }

        let now = Date()
        sessions[index].durationSeconds = max(0, now.timeIntervalSince(sessions[index].createdAt))
        sessions[index].updatedAt = now
    }

    @MainActor
    private func persistSessions() {
        store.saveSessions(
            sessions,
            activeSessionID: activeSessionID,
            currentSessionID: sharedCurrentSessionID
        )
    }

    private func friendlyCaptureError(_ error: Error) -> String {
        let message = error.localizedDescription

        if selectedAudioSource == .callAudio {
            return message == "The user declined the application." || message.contains("declined")
                ? "Нет доступа к записи экрана или системному звуку"
                : message
        }

        return message
    }

    @MainActor
    private func loadPlayer(for session: RecordingSession) throws {
        stopPlayback(resetPosition: true)

        let player = try AVAudioPlayer(contentsOf: store.audioURL(for: session))
        player.delegate = self
        player.prepareToPlay()

        audioPlayer = player
        playbackSessionID = session.id
        playbackCurrentTime = 0
        playbackDuration = player.duration
    }

    @MainActor
    private func stopPlayback(resetPosition: Bool) {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playbackSessionID = nil
        playbackDuration = 0
        if resetPosition {
            playbackCurrentTime = 0
        }
        stopPlaybackTimer()
    }

    @MainActor
    private func startPlaybackTimer() {
        stopPlaybackTimer()

        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePlaybackTime()
            }
        }
    }

    @MainActor
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    @MainActor
    private func updatePlaybackTime() {
        guard let audioPlayer else {
            playbackCurrentTime = 0
            playbackDuration = 0
            return
        }

        playbackCurrentTime = audioPlayer.currentTime
        playbackDuration = audioPlayer.duration
        isPlaying = audioPlayer.isPlaying
    }

    @MainActor
    private func stopCurrentRecognition(finalizeSession: Bool) {
        let hadActiveSession = activeSessionID != nil

        systemAudioCapture?.stop()
        systemAudioCapture = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        audioRecorder?.stop()
        audioRecorder = nil

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if finalizeSession {
            finishActiveSession()
        }

        activeSessionID = nil
        isListening = false
        isStarting = false

        if finalizeSession && hadActiveSession {
            persistSessions()
        }
    }

    private func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentStatus == .notDetermined else { return currentStatus }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorizationIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            break
        @unknown default:
            return false
        }

        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private static func defaultSessionTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM HH:mm"
        return "Сеанс \(formatter.string(from: date))"
    }

    private func migrateTranscriptDirectoriesIfNeeded() {
        var didChange = false

        for index in sessions.indices where sessions[index].transcriptDirectoryName == nil {
            sessions[index].transcriptDirectoryName = store.makeTranscriptDirectoryName(
                title: sessions[index].title,
                createdAt: sessions[index].createdAt,
                id: sessions[index].id
            )
            didChange = true
        }

        if didChange {
            store.saveSessions(sessions, currentSessionID: sessions.first?.id)
        }
    }
}

extension SpeechTranscriber: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async {
            self.canStart = available
            if !available && self.isListening {
                self.stopCurrentRecognition(finalizeSession: true)
            }
            self.statusText = available ? "Готов к прослушиванию" : "Распознавание речи сейчас недоступно"
        }
    }
}

extension SpeechTranscriber: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            player.currentTime = 0
            self.isPlaying = false
            self.playbackCurrentTime = 0
            self.stopPlaybackTimer()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            self.statusText = "Не удалось воспроизвести запись"
            self.stopPlayback(resetPosition: true)
        }
    }
}
