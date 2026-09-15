import Foundation
import Testing
@testable import Steno

/// Полный прогон ffmpeg → Whisper → SpeakerKit на настоящем файле, модели из библиотеки приложения.
/// Запуск: STENO_AUDIO=/путь/к/файлу.m4a [STENO_MODE=dolphin] swift test --filter EngineIntegration
@Suite("EngineIntegration", .enabled(if: ProcessInfo.processInfo.environment["STENO_AUDIO"] != nil))
struct EngineIntegrationTests {
    @Test("Расшифровка диалога со спикерами", .timeLimit(.minutes(30)))
    func transcribesDialogWithSpeakers() async throws {
        let environment = ProcessInfo.processInfo.environment
        let audio = URL(filePath: try #require(environment["STENO_AUDIO"]))
        let mode = environment["STENO_MODE"].flatMap(TranscriptionMode.init(rawValue:)) ?? .cheetah

        let info = try await MediaTools.probe(audio)
        let speechURL = FileManager.default.temporaryDirectory.appending(path: "steno-integration.f32")
        defer { try? FileManager.default.removeItem(at: speechURL) }
        try await MediaTools.makeSpeechAudio(from: audio, to: speechURL, restore: false, duration: info.duration) { _ in }
        let samples = try MediaTools.loadSamples(from: speechURL)

        var options = TranscriptionOptions()
        options.mode = mode
        options.recognizeSpeakers = true
        let engine = TranscriptionEngine(modelsURL: LibraryStore.defaultRootURL.appending(path: "Models", directoryHint: .isDirectory))
        let output = try await engine.transcribe(samples: samples, options: options) { stage, fraction in
            print("· \(stage.title) \(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "")")
        }

        for segment in output.segments {
            print("[\(TimeFormat.clock(segment.start))] \(segment.speaker.map { "S\($0 + 1)" } ?? "—"): \(segment.text)")
        }
        print("язык: \(output.language ?? "nil"), спикеров: \(output.speakers.count), длительность: \(info.duration)")

        #expect(!output.segments.isEmpty)
        #expect(output.language == "ru")
    }
}
