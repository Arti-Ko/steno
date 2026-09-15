import Foundation
import Observation
import SpeakerKit
import WhisperKit

/// Где лежат модели и как понять, что они скачаны целиком.
enum ModelLocations {
    static let whisperRepo = "argmaxinc/whisperkit-coreml"
    static let speakerRepo = "argmaxinc/speakerkit-coreml"
    private static let completionMarker = ".steno-complete"

    static func whisperFolder(_ variant: String, modelsURL: URL) -> URL {
        modelsURL.appending(path: "models/\(whisperRepo)/\(variant)", directoryHint: .isDirectory)
    }

    static func speakerFolder(modelsURL: URL) -> URL {
        modelsURL.appending(path: "models/\(speakerRepo)", directoryHint: .isDirectory)
    }

    static func tokenizersFolder(modelsURL: URL) -> URL {
        modelsURL.appending(path: "tokenizers", directoryHint: .isDirectory)
    }

    static func isComplete(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: completionMarker).path)
    }

    static func ensureWhisper(
        _ variant: String,
        modelsURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let expected = whisperFolder(variant, modelsURL: modelsURL)
        if isComplete(expected) {
            return expected
        }
        let downloaded = try await WhisperKit.download(
            variant: variant,
            downloadBase: modelsURL,
            from: whisperRepo,
            progressCallback: { progress($0.fractionCompleted) }
        )
        try Data().write(to: downloaded.appending(path: completionMarker))
        return downloaded
    }

    static func loadSpeakerKit(modelsURL: URL) async throws -> SpeakerKit {
        let folder = speakerFolder(modelsURL: modelsURL)
        let installed = isComplete(folder)
        let config = PyannoteConfig(
            downloadBase: modelsURL.path,
            download: !installed,
            verbose: false,
            logLevel: .error
        )
        let kit = try await SpeakerKit(config)
        if !installed {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appending(path: completionMarker))
        }
        return kit
    }
}

/// Состояние моделей для настроек: что скачано, что качается, удаление.
@MainActor
@Observable
final class ModelStore {
    enum Item: Hashable, Identifiable {
        case whisper(TranscriptionMode)
        case speakers

        var id: String {
            switch self {
            case .whisper(let mode): mode.modelVariant
            case .speakers: "speakers"
            }
        }

        var title: String {
            switch self {
            case .whisper(let mode): "\(mode.title) — Whisper"
            case .speakers: "Распознавание спикеров"
            }
        }

        var approximateSize: String {
            switch self {
            case .whisper(.cheetah): "486 МБ"
            case .whisper(.dolphin): "1,6 ГБ"
            case .whisper(.whale): "3,1 ГБ"
            case .speakers: "33 МБ"
            }
        }

        static let all: [Item] = TranscriptionMode.allCases.map(Item.whisper) + [.speakers]
    }

    private(set) var installed: Set<Item> = []
    /// Прогресс загрузки; nil внутри словаря — прогресс неизвестен.
    private(set) var downloads: [Item: Double?] = [:]
    var errorMessage: String?

    @ObservationIgnored private let modelsURL: URL
    @ObservationIgnored private var tasks: [Item: Task<Void, Never>] = [:]

    init(modelsURL: URL) {
        self.modelsURL = modelsURL
        refresh()
    }

    func refresh() {
        installed = Set(Item.all.filter { ModelLocations.isComplete(folder(for: $0)) })
    }

    func isInstalled(_ mode: TranscriptionMode) -> Bool {
        installed.contains(.whisper(mode))
    }

    func download(_ item: Item) {
        guard tasks[item] == nil else { return }
        downloads[item] = .some(nil)
        let modelsURL = modelsURL
        tasks[item] = Task { [weak self] in
            do {
                switch item {
                case .whisper(let mode):
                    _ = try await ModelLocations.ensureWhisper(mode.modelVariant, modelsURL: modelsURL) { fraction in
                        Task { @MainActor in self?.downloads[item] = fraction }
                    }
                case .speakers:
                    _ = try await ModelLocations.loadSpeakerKit(modelsURL: modelsURL)
                }
            } catch is CancellationError {
                // Пользователь отменил загрузку.
            } catch {
                self?.errorMessage = "Не удалось скачать модель: \(error.localizedDescription)"
            }
            self?.tasks[item] = nil
            self?.downloads[item] = nil
            self?.refresh()
        }
    }

    func cancel(_ item: Item) {
        tasks[item]?.cancel()
    }

    func delete(_ item: Item) {
        do {
            try FileManager.default.removeItem(at: folder(for: item))
        } catch {
            errorMessage = "Не удалось удалить модель: \(error.localizedDescription)"
        }
        refresh()
    }

    private func folder(for item: Item) -> URL {
        switch item {
        case .whisper(let mode): ModelLocations.whisperFolder(mode.modelVariant, modelsURL: modelsURL)
        case .speakers: ModelLocations.speakerFolder(modelsURL: modelsURL)
        }
    }
}
