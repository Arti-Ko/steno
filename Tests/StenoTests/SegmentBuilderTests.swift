import Foundation
import Testing
@testable import Steno

@Suite("SegmentBuilder")
struct SegmentBuilderTests {
    private func words(_ spec: [(String, Double, Double)]) -> [Word] {
        spec.map { Word(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test("Смена спикера начинает новый абзац")
    func speakerChangeStartsNewParagraph() {
        let input = words([(" Привет.", 0, 0.5), (" Как", 0.6, 0.8), (" дела?", 0.8, 1.2), (" Хорошо.", 1.5, 2.0)])
        let turns = [SpeakerTurn(start: 0, end: 1.3, speaker: 7), SpeakerTurn(start: 1.4, end: 2.2, speaker: 3)]

        let segments = SegmentBuilder.build(words: input, turns: turns)

        #expect(segments.map(\.text) == ["Привет. Как дела?", "Хорошо."])
        #expect(segments.map(\.speaker) == [7, 3])
    }

    @Test("Короткое вкрапление чужого спикера сглаживается")
    func shortFlickerIsSmoothed() {
        let input = words([(" раз", 0, 1), (" два", 1, 1.3), (" три", 1.3, 2.5)])
        let turns = [
            SpeakerTurn(start: 0, end: 1, speaker: 0),
            SpeakerTurn(start: 1, end: 1.3, speaker: 1),
            SpeakerTurn(start: 1.3, end: 3, speaker: 0),
        ]

        let segments = SegmentBuilder.build(words: input, turns: turns)

        #expect(segments.count == 1)
        #expect(segments.first?.speaker == 0)
    }

    @Test("Слово без пересечений достаётся ближайшему спикеру")
    func wordOutsideTurnsGetsNearestSpeaker() {
        let turns = [SpeakerTurn(start: 0, end: 1, speaker: 0), SpeakerTurn(start: 5, end: 6, speaker: 1)]
        #expect(SegmentBuilder.speaker(for: Word(text: " эхо", start: 4, end: 4.5), turns: turns) == 1)
    }

    @Test("Без диаризации пауза после предложения делит текст")
    func pauseAfterSentenceSplitsWithoutDiarization() {
        let input = words([(" Первое.", 0, 1), (" Второе.", 3, 4)])

        let segments = SegmentBuilder.build(words: input, turns: [])

        #expect(segments.map(\.text) == ["Первое.", "Второе."])
        #expect(segments.allSatisfy { $0.speaker == nil })
    }

    @Test("Спикеры нумеруются по порядку появления")
    func speakersAreNumberedByAppearance() {
        let segments = [
            Segment(start: 0, end: 1, text: "а", speaker: 5),
            Segment(start: 1, end: 2, text: "б", speaker: 2),
            Segment(start: 2, end: 3, text: "в", speaker: 5),
        ]

        let result = SegmentBuilder.numberSpeakers(segments)

        #expect(result.segments.map(\.speaker) == [0, 1, 0])
        #expect(result.speakers.map(\.name) == ["Спикер 1", "Спикер 2"])
    }
}
