import Foundation
import SpeakerKit
import WhisperKit

enum JobStage: Equatable, Sendable {
    case waiting
    case downloadingSource
    case importing
    case downloadingModel
    case loadingModel
    case preparingAudio
    case transcribing
    case diarizing

    var title: String {
        switch self {
        case .waiting: "В очереди"
        case .downloadingSource: "Скачивание по ссылке"
        case .importing: "Импорт файла"
        case .downloadingModel: "Загрузка модели"
        case .loadingModel: "Подготовка модели"
        case .preparingAudio: "Подготовка звука"
        case .transcribing: "Расшифровка"
        case .diarizing: "Распознавание спикеров"
        }
    }
}

typealias StageReporter = @Sendable (JobStage, Double?) -> Void

struct EngineOutput: Sendable {
    let segments: [Segment]
    let speakers: [Speaker]
    let language: String?
}

/// Держит загруженные модели между задачами очереди, чтобы не грузить их на каждый файл.
actor TranscriptionEngine {
    private let modelsURL: URL
    private var whisper: WhisperKit?
    private var loadedVariant: String?
    private var speakerKit: SpeakerKit?

    init(modelsURL: URL) {
        self.modelsURL = modelsURL
    }

    func transcribe(
        samples: [Float],
        options: TranscriptionOptions,
        report: @escaping StageReporter
    ) async throws -> EngineOutput {
        let pipe = try await whisperKit(for: options.mode, report: report)
        try Task.checkCancellation()

        report(.transcribing, 0)
        let decoding = DecodingOptions(
            task: .transcribe,
            language: options.language,
            temperatureFallbackCount: options.mode.temperatureFallbackCount,
            usePrefillPrompt: true,
            detectLanguage: options.language == nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        // WhisperKit заполняет Progress только когда режет запись на окна; до этого процент неизвестен.
        let poller = Task.detached {
            while !Task.isCancelled {
                let progress = pipe.progress
                report(.transcribing, progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { poller.cancel() }

        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: decoding,
            callback: { _ in Task.isCancelled ? false : nil }
        )
        // Иначе опрос продолжит слать «Расшифровку» поверх следующего этапа.
        poller.cancel()
        try Task.checkCancellation()

        let whisperSegments = results.flatMap(\.segments).sorted { $0.start < $1.start }
        let words = whisperSegments
            .flatMap { $0.words ?? [] }
            .filter { !$0.word.hasPrefix("<|") }
            .map { Word(text: $0.word, start: Double($0.start), end: Double($0.end)) }

        let turns = options.recognizeSpeakers
            ? try await diarize(samples: samples, speakerCount: options.speakerCount, report: report)
            : []

        let segments = words.isEmpty
            ? SegmentBuilder.fallback(segments: whisperSegments.map {
                (start: Double($0.start), end: Double($0.end), text: Self.stripSpecialTokens($0.text))
            })
            : SegmentBuilder.build(words: words, turns: turns)
        let numbered = SegmentBuilder.numberSpeakers(segments)

        return EngineOutput(
            segments: numbered.segments,
            speakers: numbered.speakers,
            language: options.language ?? Self.dominantLanguage(results)
        )
    }

    private func whisperKit(for mode: TranscriptionMode, report: @escaping StageReporter) async throws -> WhisperKit {
        if let whisper, loadedVariant == mode.modelVariant {
            return whisper
        }
        if let whisper {
            await whisper.unloadModels()
        }
        whisper = nil
        loadedVariant = nil

        let folder = try await ModelLocations.ensureWhisper(mode.modelVariant, modelsURL: modelsURL) { fraction in
            report(.downloadingModel, fraction)
        }
        report(.loadingModel, nil)
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: ModelLocations.tokenizersFolder(modelsURL: modelsURL),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        let pipe = try await WhisperKit(config)
        whisper = pipe
        loadedVariant = mode.modelVariant
        return pipe
    }

    private func diarize(samples: [Float], speakerCount: Int?, report: @escaping StageReporter) async throws -> [SpeakerTurn] {
        report(.diarizing, nil)
        if speakerKit == nil {
            speakerKit = try await ModelLocations.loadSpeakerKit(modelsURL: modelsURL)
        }
        guard let speakerKit else { return [] }
        let result = try await speakerKit.diarize(
            audioArray: samples,
            options: PyannoteDiarizationOptions(numberOfSpeakers: speakerCount),
            progressCallback: { progress in report(.diarizing, progress.fractionCompleted) }
        )
        return result.segments.compactMap { segment in
            segment.speaker.speakerId.map {
                SpeakerTurn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: $0)
            }
        }
    }

    private static func dominantLanguage(_ results: [TranscriptionResult]) -> String? {
        let counts = results.reduce(into: [String: Int]()) { counts, result in
            counts[result.language, default: 0] += result.segments.count
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
    }
}

extension SegmentBuilder {
    /// Нумерует спикеров по порядку первого появления: 0, 1, 2…
    static func numberSpeakers(_ segments: [Segment]) -> (segments: [Segment], speakers: [Speaker]) {
        var mapping: [Int: Int] = [:]
        let renumbered = segments.map { segment -> Segment in
            guard let original = segment.speaker else { return segment }
            let number = mapping[original] ?? mapping.count
            mapping[original] = number
            var copy = segment
            copy.speaker = number
            return copy
        }
        let speakers = (0..<mapping.count).map { Speaker(id: $0, name: "Спикер \($0 + 1)") }
        return (renumbered, speakers)
    }
}
