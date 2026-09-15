import Foundation

struct TimedText: Sendable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
    let words: [Word]
}

struct SubtitleCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var lines: [String]
    var speaker: String?
}

/// Режет расшифровку на титры с ограничениями по длине строки, числу строк и длительности.
enum SubtitleBuilder {
    static let minimumCueDuration = 0.8
    private static let sentenceEndings: Set<Character> = [".", "!", "?", "…"]

    static func cues(
        from items: [TimedText],
        maxCharactersPerLine: Int,
        maxLines: Int,
        maxDuration: Double
    ) -> [SubtitleCue] {
        let lineLimit = max(10, maxCharactersPerLine)
        let capacity = lineLimit * max(1, maxLines)
        var cues: [SubtitleCue] = []

        for item in items {
            var pending: [Word] = []

            func flush() {
                guard let first = pending.first, let last = pending.last else { return }
                let text = joined(pending)
                if !text.isEmpty {
                    cues.append(SubtitleCue(
                        start: first.start,
                        end: max(last.end, first.start + minimumCueDuration),
                        lines: wrap(text, maxCharactersPerLine: lineLimit, maxLines: maxLines),
                        speaker: item.speaker
                    ))
                }
                pending.removeAll()
            }

            for word in tokens(for: item) {
                if let first = pending.first {
                    let tooLong = joined(pending + [word]).count > capacity
                    let tooSlow = word.end - first.start > maxDuration
                    if tooLong || tooSlow {
                        flush()
                    }
                }
                pending.append(word)
                let endsSentence = word.text.last.map { sentenceEndings.contains($0) } ?? false
                if endsSentence && joined(pending).count >= lineLimit {
                    flush()
                }
            }
            flush()
        }
        return resolveOverlaps(cues)
    }

    /// Слова с таймингами Whisper, если текст не правили; иначе — равномерная раскладка по символам.
    static func tokens(for item: TimedText) -> [Word] {
        let words = item.words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if !words.isEmpty, compact(words.map(\.text).joined()) == compact(item.text) {
            return words
        }
        return syntheticTokens(for: item)
    }

    static func syntheticTokens(for item: TimedText) -> [Word] {
        let parts = item.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let totalCharacters = max(1, parts.reduce(0) { $0 + $1.count })
        let span = max(0, item.end - item.start)
        var consumed = 0
        return parts.enumerated().map { index, part in
            let start = item.start + span * Double(consumed) / Double(totalCharacters)
            consumed += part.count
            let end = item.start + span * Double(consumed) / Double(totalCharacters)
            return Word(text: index == 0 ? part : " " + part, start: start, end: end)
        }
    }

    static func wrap(_ text: String, maxCharactersPerLine: Int, maxLines: Int) -> [String] {
        guard text.count > maxCharactersPerLine, maxLines > 1 else { return [text] }
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [text] }

        if maxLines >= 2 {
            let best = (1..<words.count)
                .map { index in
                    (words[..<index].joined(separator: " "), words[index...].joined(separator: " "))
                }
                .min { max($0.0.count, $0.1.count) < max($1.0.count, $1.1.count) }
            if let best, max(best.0.count, best.1.count) <= maxCharactersPerLine {
                return [best.0, best.1]
            }
        }

        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= maxCharactersPerLine {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private static func joined(_ words: [Word]) -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    private static func resolveOverlaps(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var result = cues
        for index in result.indices.dropLast() {
            let nextStart = result[index + 1].start
            if result[index].end > nextStart {
                result[index].end = max(result[index].start + 0.05, nextStart)
            }
        }
        return result
    }
}
