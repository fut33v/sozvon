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

    @Published var vocabulary: String = ""
    @Published private(set) var whisperStatus = ""
    @Published private(set) var isWhisperRunning = false
    @Published private(set) var isWhisperConfigured = WhisperTranscriber.isConfigured

    private let store = RecordingStore()
    private let audioEngine = AVAudioEngine()
    private var channels: [TranscriptSpeaker: ChannelPipeline] = [:]
    private var systemAudioCapture: SystemAudioCapture?
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
        selectedSession?.displayTranscript ?? ""
    }

    var selectedMicAudioURL: URL? {
        guard let selectedSession else { return nil }
        return store.micAudioURL(for: selectedSession)
    }

    /// Contextual words the recognizer should expect: names, jargon, project titles.
    var vocabularyTerms: [String] {
        vocabulary
            .split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
        statusText = selectedAudioSource.connectingStatus

        let locale = Locale(identifier: selectedLanguage.rawValue)

        guard let probe = SFSpeechRecognizer(locale: locale) else {
            statusText = "Этот язык не поддерживается"
            canStart = false
            isStarting = false
            return
        }

        guard probe.isAvailable else {
            statusText = "Распознавание речи сейчас недоступно"
            isStarting = false
            return
        }

        let source = selectedAudioSource
        let session = createSession()

        do {
            if source.capturesSystemAudio {
                let pipeline = try makePipeline(
                    speaker: .them,
                    locale: locale,
                    audioURL: store.audioURL(for: session),
                    format: nil
                )
                channels[.them] = pipeline
                try await startSystemAudioCapture(pipeline: pipeline)
            }

            if source.capturesMicrophone {
                let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)

                guard inputFormat.channelCount > 0 else {
                    throw NSError(
                        domain: "CallListener",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Микрофон не найден"]
                    )
                }

                // Mic-only sessions keep writing to the primary audio file so older
                // recordings and the player keep working unchanged.
                let micURL = source.labelsSpeakers
                    ? (store.micAudioURL(for: session) ?? store.audioURL(for: session))
                    : store.audioURL(for: session)

                let pipeline = try makePipeline(
                    speaker: .me,
                    locale: locale,
                    audioURL: micURL,
                    format: inputFormat
                )
                channels[.me] = pipeline
                try startMicrophoneCapture(pipeline: pipeline, format: inputFormat)
            }

            isStarting = false
            isListening = true
            statusText = source.listeningStatus
        } catch {
            let failedSessionID = session.id
            stopCurrentRecognition(finalizeSession: false)
            discardSession(withID: failedSessionID)
            statusText = friendlyCaptureError(error)
        }
    }

    @MainActor
    private func makePipeline(
        speaker: TranscriptSpeaker,
        locale: Locale,
        audioURL: URL,
        format: AVAudioFormat?
    ) throws -> ChannelPipeline {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw NSError(
                domain: "CallListener",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Этот язык не поддерживается"]
            )
        }

        recognizer.delegate = self

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Names, jargon and project titles are where the recognizer slips most.
        request.contextualStrings = vocabularyTerms

        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let recorder = try AudioSessionRecorder(url: audioURL, format: format) { [weak self] message in
            DispatchQueue.main.async {
                self?.statusText = message
            }
        }

        let pipeline = ChannelPipeline(
            speaker: speaker,
            recognizer: recognizer,
            request: request,
            recorder: recorder
        )

        pipeline.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let rawSegments = result.bestTranscription.segments.map {
                    RecognizedWord(
                        substring: $0.substring,
                        timestamp: $0.timestamp,
                        duration: $0.duration
                    )
                }
                let formatted = result.bestTranscription.formattedString

                DispatchQueue.main.async {
                    self.updateChannel(speaker: speaker, rawSegments: rawSegments, formatted: formatted)
                }
            }

            if error != nil || result?.isFinal == true {
                DispatchQueue.main.async {
                    self.channelDidFinish(speaker: speaker, error: error)
                }
            }
        }

        return pipeline
    }

    @MainActor
    private func updateChannel(
        speaker: TranscriptSpeaker,
        rawSegments: [RecognizedWord],
        formatted: String
    ) {
        guard let pipeline = channels[speaker] else { return }

        pipeline.segments = TranscriptSegment.utterances(from: rawSegments, speaker: speaker)
        pipeline.formattedString = formatted

        updateActiveTranscript()
    }

    /// One channel failing must not discard the other channel's transcript, so the
    /// session is only finalized once every channel has stopped.
    @MainActor
    private func channelDidFinish(speaker: TranscriptSpeaker, error: Error?) {
        guard let pipeline = channels[speaker] else { return }

        channels[speaker] = nil
        pipeline.stop()

        // Stop feeding a dead pipeline.
        switch speaker {
        case .me:
            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
        case .them:
            systemAudioCapture?.stop()
            systemAudioCapture = nil
        }

        guard channels.isEmpty else {
            if error != nil {
                statusText = "\(speaker.title): канал остановлен, продолжаю"
            }
            return
        }

        stopCurrentRecognition(finalizeSession: true)
        statusText = error?.localizedDescription ?? "Готов к прослушиванию"
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
        sessions[index].segments = []
        sessions[index].whisperTranscript = nil
        sessions[index].whisperSegments = nil
        sessions[index].preferredTranscriptKind = .live
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

    var canRunWhisper: Bool {
        guard let selectedSession, selectedSession.id != activeSessionID else { return false }
        guard isWhisperConfigured, !isWhisperRunning else { return false }
        return FileManager.default.fileExists(atPath: store.audioURL(for: selectedSession).path)
    }

    var selectedTranscriptKind: TranscriptKind {
        selectedSession?.preferredTranscriptKind ?? .live
    }

    @MainActor
    func refreshWhisperAvailability() {
        isWhisperConfigured = WhisperTranscriber.isConfigured
    }

    /// Re-runs the finished recording through whisper.cpp. The live Apple Speech pass
    /// stays untouched so both versions remain available.
    @MainActor
    func runWhisperOnSelectedSession() {
        guard let session = selectedSession,
              session.id != activeSessionID,
              !isWhisperRunning else {
            return
        }

        let inputs = whisperInputs(for: session)

        guard !inputs.isEmpty else {
            whisperStatus = "Нет аудиофайла для распознавания"
            return
        }

        isWhisperRunning = true
        whisperStatus = "Whisper: запускаю"

        let language = session.language
        let terms = vocabularyTerms
        let labelSpeakers = session.source.labelsSpeakers
        let sessionID = session.id

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                let segments = try WhisperTranscriber.transcribe(
                    inputs: inputs,
                    language: language,
                    vocabulary: terms
                ) { message in
                    Task { @MainActor in
                        self.whisperStatus = message
                    }
                }

                await MainActor.run {
                    self.applyWhisperResult(segments, to: sessionID, labelSpeakers: labelSpeakers)
                }
            } catch {
                await MainActor.run {
                    self.isWhisperRunning = false
                    self.whisperStatus = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    func toggleTranscriptKind() {
        guard let selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              sessions[index].hasWhisperTranscript else {
            return
        }

        sessions[index].preferredTranscriptKind =
            sessions[index].preferredTranscriptKind == .whisper ? .live : .whisper
        sessions[index].updatedAt = Date()
        persistSessions()
    }

    private func whisperInputs(for session: RecordingSession) -> [WhisperTranscriber.Input] {
        var inputs: [WhisperTranscriber.Input] = []

        // Without a separate mic file the single recording belongs to whichever
        // side that session actually captured.
        let primarySpeaker: TranscriptSpeaker = session.source.capturesSystemAudio ? .them : .me
        inputs.append(
            WhisperTranscriber.Input(audioURL: store.audioURL(for: session), speaker: primarySpeaker)
        )

        if let micURL = store.micAudioURL(for: session) {
            inputs.append(WhisperTranscriber.Input(audioURL: micURL, speaker: .me))
        }

        return inputs.filter { FileManager.default.fileExists(atPath: $0.audioURL.path) }
    }

    @MainActor
    private func applyWhisperResult(
        _ segments: [TranscriptSegment],
        to id: RecordingSession.ID,
        labelSpeakers: Bool
    ) {
        isWhisperRunning = false

        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            whisperStatus = "Сеанс больше не существует"
            return
        }

        sessions[index].whisperSegments = segments
        sessions[index].whisperTranscript = labelSpeakers
            ? segments.mergedTranscript()
            : segments.map(\.text).joined(separator: " ")
        sessions[index].preferredTranscriptKind = .whisper
        sessions[index].updatedAt = Date()
        persistSessions()

        whisperStatus = "Whisper: готово"
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

    private func startMicrophoneCapture(pipeline: ChannelPipeline, format: AVAudioFormat) throws {
        let inputNode = audioEngine.inputNode

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            pipeline.request.append(buffer)
            pipeline.recorder.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startSystemAudioCapture(pipeline: ChannelPipeline) async throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(
                domain: "CallListener",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Для захвата звука звонка нужна macOS 13 или новее"]
            )
        }

        let capture = SystemAudioCapture { buffer in
            pipeline.request.append(buffer)
        } appendRecordingBuffer: { buffer in
            pipeline.recorder.append(buffer)
        } reportError: { [weak self] message in
            DispatchQueue.main.async {
                self?.statusText = message
            }
        }

        systemAudioCapture = capture
        try await capture.start()
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
            micAudioFileName: selectedAudioSource.labelsSpeakers
                ? "\(id.uuidString)-mic.caf"
                : nil,
            transcriptDirectoryName: store.makeTranscriptDirectoryName(
                title: title,
                createdAt: now,
                id: id
            ),
            transcript: "",
            segments: [],
            whisperTranscript: nil,
            whisperSegments: nil,
            preferredTranscriptKind: .live,
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
    private func updateActiveTranscript() {
        guard let activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else {
            return
        }

        let allSegments = channels.values
            .flatMap { $0.segments }
            .sorted { $0.startSeconds < $1.startSeconds }

        sessions[index].segments = allSegments

        if sessions[index].source.labelsSpeakers {
            sessions[index].transcript = allSegments.mergedTranscript()
        } else {
            // Single channel: the recognizer's own formatting beats re-joining words.
            sessions[index].transcript = channels.values.first?.formattedString ?? ""
        }

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

        if selectedAudioSource.capturesSystemAudio {
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

        // Clear first: stopping a pipeline re-enters channelDidFinish.
        let activePipelines = channels
        channels.removeAll()
        activePipelines.values.forEach { $0.stop() }

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

/// One capture channel: its own recorder, recognizer and running transcript.
private final class ChannelPipeline {
    let speaker: TranscriptSpeaker
    let recognizer: SFSpeechRecognizer
    let request: SFSpeechAudioBufferRecognitionRequest
    let recorder: AudioSessionRecorder
    var task: SFSpeechRecognitionTask?
    var segments: [TranscriptSegment] = []
    var formattedString = ""

    init(
        speaker: TranscriptSpeaker,
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        recorder: AudioSessionRecorder
    ) {
        self.speaker = speaker
        self.recognizer = recognizer
        self.request = request
        self.recorder = recorder
    }

    func stop() {
        request.endAudio()
        task?.cancel()
        task = nil
        recorder.stop()
    }
}
