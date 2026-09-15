import Foundation
import Testing
@testable import Steno

@MainActor
@Suite("Exporter")
struct ExporterTests {
    private func sample() -> Transcript {
        var transcript = Transcript(title: "Интервью", source: .file, sourceReference: "/tmp/a.m4a", options: TranscriptionOptions())
        transcript.duration = 75
        transcript.status = .done
        transcript.speakers = [Speaker(id: 0, name: "Анна"), Speaker(id: 1, name: "Борис")]
        transcript.segments = [
            Segment(start: 1.2, end: 3.5, text: "Добрый день.", speaker: 0),
            Segment(start: 3.6, end: 6, text: "Начнём, пожалуй.", speaker: 0),
            Segment(start: 62, end: 65.25, text: "Здравствуйте, \"коллеги\", рад видеть.", speaker: 1),
        ]
        return transcript
    }

    @Test("TXT объединяет подряд идущие реплики одного спикера")
    func plainTextMergesSpeakerTurns() {
        let text = Exporter.plainText(sample(), options: ExportOptions())
        #expect(text == "[00:01] Анна\nДобрый день. Начнём, пожалуй.\n\n[01:02] Борис\nЗдравствуйте, \"коллеги\", рад видеть.\n")
    }

    @Test("SRT нумерует титры и ставит запятую в отметках времени")
    func srtUsesNumberingAndCommaTimestamps() {
        var options = ExportOptions()
        options.includeSpeakers = false

        let srt = Exporter.srt(sample(), options: options)

        #expect(srt.hasPrefix("1\n00:00:01,200 --> 00:00:03,500\nДобрый день."))
        #expect(srt.contains("3\n00:01:02,000 --> 00:01:05,250\nЗдравствуйте"))
    }

    @Test("VTT начинается с заголовка и помечает голоса")
    func vttHasHeaderAndVoices() {
        let vtt = Exporter.vtt(sample(), options: ExportOptions())
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.200 --> 00:00:03.500\n<v Анна>Добрый день."))
    }

    @Test("CSV экранирует кавычки и запятые")
    func csvEscapesQuotes() {
        let csv = Exporter.csv(sample(), options: ExportOptions())
        #expect(csv.hasPrefix("Начало,Конец,Спикер,Текст\r\n00:00:01.200,00:00:03.500,Анна,Добрый день.\r\n"))
        #expect(csv.contains("\"Здравствуйте, \"\"коллеги\"\", рад видеть.\""))
    }

    @Test("Перевод подменяет текст там, где он есть")
    func translationReplacesText() {
        var transcript = sample()
        transcript.translations = [TranscriptTranslation(language: "en", texts: [transcript.segments[0].id.uuidString: "Good afternoon."])]
        var options = ExportOptions()
        options.language = "en"
        options.includeTimestamps = false
        options.includeSpeakers = false

        let text = Exporter.plainText(transcript, options: options)

        #expect(text.hasPrefix("Good afternoon.\n\nНачнём, пожалуй."))
    }

    @Test("DOCX и PDF собираются в валидные контейнеры")
    func binaryFormatsRender() throws {
        let docx = try Exporter.data(for: sample(), format: .docx, options: ExportOptions())
        #expect(docx.starts(with: [0x50, 0x4B]))

        let pdf = try Exporter.data(for: sample(), format: .pdf, options: ExportOptions())
        #expect(pdf.starts(with: Array("%PDF".utf8)))
    }

    @Test("Пустая расшифровка не экспортируется")
    func emptyTranscriptThrows() {
        var transcript = sample()
        transcript.segments = []
        #expect(throws: ExportError.self) {
            try Exporter.data(for: transcript, format: .txt, options: ExportOptions())
        }
    }
}

@Suite("Форматы времени и склонения")
struct FormattingTests {
    @Test("Часы появляются только когда нужны")
    func clockFormat() {
        #expect(TimeFormat.clock(65) == "01:05")
        #expect(TimeFormat.clock(3725) == "1:02:05")
        #expect(TimeFormat.clock(5, forceHours: true) == "0:00:05")
    }

    @Test("Отметки субтитров с миллисекундами")
    func subtitleStamps() {
        #expect(TimeFormat.srt(3723.456) == "01:02:03,456")
        #expect(TimeFormat.vtt(0.0005) == "00:00:00.001")
    }

    @Test("Склонение числа спикеров", arguments: [(1, "1 спикер"), (3, "3 спикера"), (5, "5 спикеров"), (11, "11 спикеров"), (22, "22 спикера")])
    func speakerPlural(count: Int, expected: String) {
        #expect(RussianPlural.speakers(count) == expected)
    }
}
