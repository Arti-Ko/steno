import Foundation

/// Реплика из диаризации: кто говорил в этом интервале.
struct SpeakerTurn: Equatable, Sendable {
    let start: Double
    let end: Double
    let speaker: Int
}

/// Собирает абзацы из слов Whisper и назначает им спикеров.
enum SegmentBuilder {
    /// Пауза, после которой законченное предложение начинает новый абзац.
    static let sentencePause = 1.5
    /// Пауза, после которой новый абзац начинается в любом случае.
    static let hardPause = 4.0
    static let softCharacterLimit = 280
    static let hardCharacterLimit = 700
    /// Реплики короче этого считаем «дребезгом» диаризации и отдаём соседнему спикеру.
    static let flickerDuration = 0.7

    private static let sentenceEndings: Set<Character> = [".", "!", "?", "…"]

    static func build(words: [Word], turns: [SpeakerTurn]) -> [Segment] {
        let orderedWords = words.sorted { $0.start < $1.start }
        let orderedTurns = turns.sorted { $0.start < $1.start }
        let speakers = orderedTurns.isEmpty
            ? Array(repeating: nil, count: orderedWords.count)
            : smooth(orderedWords.map { speaker(for: $0, turns: orderedTurns) }, words: orderedWords)

        var segments: [Segment] = []
        var current: [Word] = []
        var currentSpeaker: Int?
        var currentLength = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(Segment(start: first.start, end: last.end, text: text, speaker: currentSpeaker, words: current))
            }
            current.removeAll()
            currentLength = 0
        }

        for (word, speaker) in zip(orderedWords, speakers) {
            if let previous = current.last {
                let pause = word.start - previous.end
                let endsSentence = previous.text.trimmingCharacters(in: .whitespaces).last.map { sentenceEndings.contains($0) } ?? false
                let shouldBreak = speaker != currentSpeaker
                    || pause >= hardPause
                    || (endsSentence && pause >= sentencePause)
                    || (endsSentence && currentLength >= softCharacterLimit)
                    || currentLength >= hardCharacterLimit
                if shouldBreak {
                    flush()
                }
            }
            if current.isEmpty {
                currentSpeaker = speaker
            }
            current.append(word)
            currentLength += word.text.count
        }
        flush()
        return segments
    }

    /// Спикер с наибольшим пересечением по времени; если пересечений нет — ближайший.
    static func speaker(for word: Word, turns: [SpeakerTurn]) -> Int? {
        var best: (speaker: Int, overlap: Double)?
        for turn in turns {
            if turn.start >= word.end { break }
            let overlap = min(turn.end, word.end) - max(turn.start, word.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (turn.speaker, overlap)
            }
        }
        if let best {
            return best.speaker
        }
        let middle = (word.start + word.end) / 2
        return turns.min { distance(middle, $0) < distance(middle, $1) }?.speaker
    }

    /// Убирает короткие вкрапления другого спикера посреди чужой реплики.
    static func smooth(_ speakers: [Int?], words: [Word]) -> [Int?] {
        var result = speakers
        var index = 0
        while index < result.count {
            var runEnd = index
            while runEnd + 1 < result.count, result[runEnd + 1] == result[index] {
                runEnd += 1
            }
            let before = index > 0 ? result[index - 1] : nil
            let after = runEnd + 1 < result.count ? result[runEnd + 1] : nil
            let duration = words[runEnd].end - words[index].start
            if let before, before == after, duration < flickerDuration {
                for position in index...runEnd {
                    result[position] = before
                }
            }
            index = runEnd + 1
        }
        return result
    }

    /// Если текст пустой (Whisper не выдал слов), используем его сегменты как есть.
    static func fallback(segments: [(start: Double, end: Double, text: String)]) -> [Segment] {
        segments.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Segment(start: item.start, end: item.end, text: text)
        }
    }

    private static func distance(_ time: Double, _ turn: SpeakerTurn) -> Double {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }
}
