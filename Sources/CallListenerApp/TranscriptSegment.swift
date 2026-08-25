import Foundation

enum TranscriptSpeaker: String, Codable, Hashable, Sendable {
    case me
    case them

    var title: String {
        switch self {
        case .me:
            return "Я"
        case .them:
            return "Собеседник"
        }
    }
}

struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(speaker.rawValue)-\(startSeconds)-\(text.hashValue)" }

    let speaker: TranscriptSpeaker
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
}

extension Array where Element == TranscriptSegment {
    /// Merges per-channel segments into one chronological transcript.
    func mergedTranscript() -> String {
        sorted { $0.startSeconds < $1.startSeconds }
            .map { "[\(TranscriptSegment.timecode(for: $0.startSeconds))] \($0.speaker.title): \($0.text)" }
            .joined(separator: "\n")
    }
}

extension TranscriptSegment {
    static func timecode(for seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }

        return String(format: "%02d:%02d", minutes, secs)
    }

    /// Groups raw recognizer segments into utterances, splitting on pauses and sentence endings.
    static func utterances(
        from segments: [RecognizedWord],
        speaker: TranscriptSpeaker,
        pauseThreshold: TimeInterval = 1.0
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var currentWords: [String] = []
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        var previousEnd: TimeInterval?

        func flush() {
            guard !currentWords.isEmpty else { return }

            let text = currentWords
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                result.append(
                    TranscriptSegment(
                        speaker: speaker,
                        startSeconds: currentStart,
                        endSeconds: currentEnd,
                        text: text
                    )
                )
            }

            currentWords = []
        }

        for segment in segments {
            let word = segment.substring.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }

            let gap = previousEnd.map { segment.timestamp - $0 } ?? 0

            if currentWords.isEmpty {
                currentStart = segment.timestamp
            } else if gap >= pauseThreshold {
                flush()
                currentStart = segment.timestamp
            }

            currentWords.append(word)
            currentEnd = segment.timestamp + segment.duration
            previousEnd = currentEnd

            if let last = word.unicodeScalars.last,
               CharacterSet(charactersIn: ".!?…").contains(last) {
                flush()
            }
        }

        flush()

        return result
    }
}

/// One recognized word with its timing, decoupled from `SFTranscriptionSegment`.
struct RecognizedWord {
    let substring: String
    let timestamp: TimeInterval
    let duration: TimeInterval
}
