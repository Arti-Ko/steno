import Foundation

/// Режимы расшифровки по образцу TurboScribe: скорость против точности.
enum TranscriptionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cheetah
    case dolphin
    case whale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cheetah: "Гепард"
        case .dolphin: "Дельфин"
        case .whale: "Кит"
        }
    }

    var summary: String {
        switch self {
        case .cheetah: "Быстрее всего, подходит для чистой речи"
        case .dolphin: "Баланс скорости и точности"
        case .whale: "Максимальная точность, работает дольше"
        }
    }

    var symbol: String {
        switch self {
        case .cheetah: "hare"
        case .dolphin: "fish"
        case .whale: "scope"
        }
    }

    /// Вариант модели в репозитории argmaxinc/whisperkit-coreml.
    var modelVariant: String {
        switch self {
        case .cheetah: "openai_whisper-small"
        case .dolphin: "openai_whisper-large-v3-v20240930_turbo"
        case .whale: "openai_whisper-large-v3"
        }
    }

    /// Сколько раз повторять декодирование с повышенной температурой, если результат сомнительный.
    var temperatureFallbackCount: Int {
        switch self {
        case .cheetah: 1
        case .dolphin: 3
        case .whale: 5
        }
    }
}

struct TranscriptionOptions: Codable, Hashable, Sendable {
    var mode: TranscriptionMode = .dolphin
    /// Код языка Whisper; nil — определить автоматически.
    var language: String?
    var recognizeSpeakers = false
    /// Точное число спикеров; nil — определить автоматически.
    var speakerCount: Int?
    var restoreAudio = false
}

enum SourceKind: String, Codable, Sendable {
    case file
    case link
    case recording
}

enum TranscriptStatus: Codable, Hashable, Sendable {
    case queued
    case processing
    case done
    case failed(String)
}

struct Word: Codable, Hashable, Sendable {
    /// Текст слова как его выдал Whisper — с ведущим пробелом, если он был.
    var text: String
    var start: Double
    var end: Double
}

struct Segment: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var speaker: Int?
    var words: [Word] = []
}

struct Speaker: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
}

struct TranscriptTranslation: Codable, Hashable, Sendable {
    /// Идентификатор языка BCP-47.
    var language: String
    /// Переводы по идентификатору сегмента.
    var texts: [String: String]
}

struct Folder: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var createdAt = Date()
}

struct Transcript: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var folderID: UUID?
    var source: SourceKind
    /// Путь к исходному файлу или ссылка.
    var sourceReference: String
    /// Аудио для воспроизведения внутри папки расшифровки.
    var mediaFileName: String?
    /// Исходное видео, если его умеет играть AVFoundation.
    var videoPath: String?
    var duration: Double = 0
    var options: TranscriptionOptions
    var status: TranscriptStatus = .queued
    var language: String?
    var segments: [Segment] = []
    var speakers: [Speaker] = []
    var translations: [TranscriptTranslation] = []
}

extension Transcript {
    var isPending: Bool {
        status == .queued || status == .processing
    }

    var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    func speakerName(for id: Int?) -> String? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }?.name ?? "Спикер \(id + 1)"
    }

    func translation(for language: String?) -> TranscriptTranslation? {
        guard let language else { return nil }
        return translations.first { $0.language == language }
    }

    func text(of segment: Segment, language: String?) -> String {
        translation(for: language)?.texts[segment.id.uuidString] ?? segment.text
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }
}
