import Foundation
import Testing
@testable import Steno

@Suite("SubtitleBuilder")
struct SubtitleBuilderTests {
    @Test("Короткий текст остаётся одной строкой")
    func shortTextStaysOnOneLine() {
        #expect(SubtitleBuilder.wrap("Привет, мир", maxCharactersPerLine: 42, maxLines: 2) == ["Привет, мир"])
    }

    @Test("Длинный текст делится на две сбалансированные строки")
    func longTextSplitsIntoBalancedLines() {
        let text = "один два три четыре пять шесть семь восемь"
        let lines = SubtitleBuilder.wrap(text, maxCharactersPerLine: 24, maxLines: 2)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count <= 24 })
        #expect(lines.joined(separator: " ") == text)
    }

    @Test("Титр не длиннее заданной длительности")
    func cueRespectsMaxDuration() {
        let words = (0..<20).map { Word(text: " слово\($0)", start: Double($0), end: Double($0) + 0.9) }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        let item = TimedText(start: 0, end: 20, text: text, speaker: nil, words: words)

        let cues = SubtitleBuilder.cues(from: [item], maxCharactersPerLine: 80, maxLines: 2, maxDuration: 5)

        #expect(cues.count > 1)
        #expect(cues.allSatisfy { $0.end - $0.start <= 5 + 1e-9 })
    }

    @Test("Отредактированный текст раскладывается по времени равномерно")
    func editedTextGetsSyntheticTiming() {
        let item = TimedText(start: 10, end: 20, text: "совсем другой текст", speaker: nil, words: [Word(text: " старый", start: 10, end: 20)])

        let tokens = SubtitleBuilder.tokens(for: item)

        #expect(tokens.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["совсем", "другой", "текст"])
        #expect(tokens.first?.start == 10)
        #expect(abs((tokens.last?.end ?? 0) - 20) < 1e-9)
    }

    @Test("Соседние титры не перекрываются даже при минимальной длительности")
    func neighbouringCuesDoNotOverlap() {
        let first = TimedText(start: 0, end: 0.2, text: "Да.", speaker: "А", words: [])
        let second = TimedText(start: 0.3, end: 2, text: "Нет, конечно.", speaker: "Б", words: [])

        let cues = SubtitleBuilder.cues(from: [first, second], maxCharactersPerLine: 42, maxLines: 2, maxDuration: 6)

        #expect(cues.count == 2)
        #expect(cues[0].end <= cues[1].start)
    }
}
