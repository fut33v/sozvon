import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var transcriber: SpeechTranscriber

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HStack(spacing: 0) {
                sessionsSidebar

                Divider()

                detailPane
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("СОЗВОН")
                    .font(.system(size: 22, weight: .semibold))
                Text(transcriber.statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(transcriber.statusColor)
                    .lineLimit(1)
            }

            Spacer()

            Picker("Источник", selection: $transcriber.selectedAudioSource) {
                ForEach(AudioSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .disabled(transcriber.isActive)

            Picker("Язык", selection: $transcriber.selectedLanguage) {
                ForEach(SpeechLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 168)
            .disabled(transcriber.isActive)

            Button {
                transcriber.toggleListening()
            } label: {
                Label(
                    transcriber.isActive ? "Остановить" : "Слушать",
                    systemImage: transcriber.isActive ? "stop.fill" : "waveform"
                )
                .frame(minWidth: 112)
            }
            .keyboardShortcut(.space, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(!transcriber.canStart && !transcriber.isActive)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var sessionsSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Сеансы")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Text("\(transcriber.sessions.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if transcriber.sessions.isEmpty {
                Spacer()

                Text("Нет сеансов")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Spacer()
            } else {
                List(selection: $transcriber.selectedSessionID) {
                    ForEach(transcriber.sessions) { session in
                        SessionRow(
                            session: session,
                            isActive: session.id == transcriber.activeSessionID
                        )
                        .tag(session.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 292)
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            selectedSessionHeader

            Divider()

            audioPlayerBar

            Divider()

            transcriptArea

            Divider()

            footer
        }
    }

    private var selectedSessionHeader: some View {
        HStack(spacing: 12) {
            if let session = transcriber.selectedSession {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        "Название",
                        text: Binding(
                            get: { transcriber.selectedSession?.title ?? "" },
                            set: { transcriber.renameSelectedSession(to: $0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))

                    HStack(spacing: 8) {
                        Text(session.source.title)
                        Text(session.language.title)
                        Text(Self.shortDateFormatter.string(from: session.createdAt))
                        Text(Self.durationText(for: session, isActive: session.id == transcriber.activeSessionID))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if session.id == transcriber.activeSessionID {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Запись")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                }
            } else {
                Text("Нет выбранного сеанса")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var audioPlayerBar: some View {
        HStack(spacing: 12) {
            Button {
                transcriber.togglePlayback()
            } label: {
                Image(systemName: selectedSessionIsPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .help(selectedSessionIsPlaying ? "Пауза" : "Воспроизвести")
            .disabled(!transcriber.canPlaySelectedAudio)

            Text(Self.durationText(for: transcriber.playbackCurrentTime))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { selectedSessionMatchesPlayback ? transcriber.playbackCurrentTime : 0 },
                    set: { transcriber.seekPlayback(to: $0) }
                ),
                in: 0...max(selectedSessionMatchesPlayback ? transcriber.playbackDuration : selectedSessionDuration, 0.1)
            )
            .disabled(!transcriber.canPlaySelectedAudio)

            Text(Self.durationText(for: selectedSessionMatchesPlayback ? transcriber.playbackDuration : selectedSessionDuration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Button {
                transcriber.openSelectedAudio()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .help("Открыть файл")
            .disabled(transcriber.selectedSession == nil)

            Button {
                transcriber.revealSelectedAudioInFinder()
            } label: {
                Image(systemName: "folder")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .help("Показать в Finder")
            .disabled(transcriber.selectedSession == nil)

            Button {
                transcriber.copySelectedAudioPath()
            } label: {
                Image(systemName: "link")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .help("Скопировать путь")
            .disabled(transcriber.selectedSession == nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var transcriptArea: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                Text(transcriber.transcript.isEmpty ? "Текст появится здесь" : transcriber.transcript)
                    .font(.system(size: 17, design: .rounded))
                    .foregroundStyle(transcriber.transcript.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(24)
            }

            if transcriber.isActive && transcriber.selectedSessionID == transcriber.activeSessionID {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Live")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                transcriber.clearTranscript()
            } label: {
                Label("Очистить", systemImage: "trash")
            }
            .disabled(transcriber.transcript.isEmpty)

            Spacer()

            Text(transcriber.wordCountText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Button {
                transcriber.copyTranscript()
            } label: {
                Label(transcriber.copyButtonTitle, systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(transcriber.transcript.isEmpty)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var selectedSessionIsPlaying: Bool {
        selectedSessionMatchesPlayback && transcriber.isPlaying
    }

    private var selectedSessionMatchesPlayback: Bool {
        transcriber.playbackSessionID == transcriber.selectedSessionID
    }

    private var selectedSessionDuration: TimeInterval {
        transcriber.selectedSession?.durationSeconds ?? 0
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter
    }()

    private static func durationText(for session: RecordingSession, isActive: Bool) -> String {
        if isActive {
            return "идет запись"
        }

        return durationText(for: session.durationSeconds)
    }

    private static func durationText(for seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

private struct SessionRow: View {
    let session: RecordingSession
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(session.title.isEmpty ? "Без названия" : session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                if isActive {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                }
            }

            Text("\(Self.rowDateFormatter.string(from: session.createdAt)) · \(session.source.title) · \(durationText)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(session.transcript.isEmpty ? "Пока нет текста" : session.transcript)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 5)
    }

    private var durationText: String {
        if isActive {
            return "запись"
        }

        let totalSeconds = max(0, Int(session.durationSeconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()
}
