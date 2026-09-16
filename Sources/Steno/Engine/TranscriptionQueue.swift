import AppKit
import Foundation
import Observation
import UserNotifications

struct JobProgress: Equatable, Sendable {
    var stage: JobStage
    var fraction: Double?
}

/// Последовательно обрабатывает расшифровки: импорт → звук → Whisper → спикеры.
@MainActor
@Observable
final class TranscriptionQueue {
    private(set) var progress: [UUID: JobProgress] = [:]
    private(set) var activeID: UUID?
    private(set) var pending: [UUID] = []

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let engine: TranscriptionEngine
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activeTask: Task<Void, Never>?

    private static let playbackFileName = "audio.m4a"
    private static let cancelledMessage = "Отменено"

    init(library: LibraryStore) {
        self.library = library
        engine = TranscriptionEngine(modelsURL: library.modelsURL)
        for transcript in library.transcripts.reversed() where transcript.status == .queued {
            enqueue(transcript.id)
        }
    }

    var count: Int {
        pending.count + (activeID == nil ? 0 : 1)
    }

    func enqueue(_ id: UUID) {
        guard !pending.contains(id), activeID != id else { return }
        pending.append(id)
        progress[id] = JobProgress(stage: .waiting)
        library.update(id) { $0.status = .queued }
        startWorkerIfNeeded()
        updateDockBadge()
    }

    func cancel(_ id: UUID) {
        if activeID == id {
            activeTask?.cancel()
            return
        }
        guard pending.contains(id) else { return }
        pending.removeAll { $0 == id }
        progress[id] = nil
        library.update(id) { $0.status = .failed(Self.cancelledMessage) }
        updateDockBadge()
    }

    // MARK: Исполнение

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Расшифровка аудио"
            )
            while !pending.isEmpty {
                let id = pending.removeFirst()
                await run(id)
            }
            ProcessInfo.processInfo.endActivity(activity)
            worker = nil
        }
    }

    private func run(_ id: UUID) async {
        guard let transcript = library.transcript(id: id) else {
            progress[id] = nil
            return
        }
        activeID = id
        library.update(id) { $0.status = .processing }
        let task = Task { await process(transcript) }
        activeTask = task
        await task.value
        activeTask = nil
        activeID = nil
        progress[id] = nil
        // Расшифровку удалили посреди обработки — подчищаем то, что утилиты успели записать.
        if library.transcript(id: id) == nil {
            try? FileManager.default.removeItem(at: library.directory(for: id))
        }
        updateDockBadge()
    }

    private func process(_ transcript: Transcript) async {
        let id = transcript.id
        let report: StageReporter = { [weak self] stage, fraction in
            Task { @MainActor in self?.setProgress(id, stage: stage, fraction: fraction) }
        }

        do {
            let directory = library.directory(for: id)
            let source = try await resolveSource(transcript, directory: directory, report: report)

            report(.importing, nil)
            let info = try await MediaTools.probe(source.url)
            guard info.hasAudio else { throw MediaError.noAudioTrack }

            let playbackURL = directory.appending(path: Self.playbackFileName)
            if source.url != playbackURL {
                try await MediaTools.makePlaybackAudio(from: source.url, to: playbackURL, duration: info.duration) {
                    report(.importing, $0)
                }
            }
            let playableVideo = info.hasVideo && transcript.source == .file
                ? await MediaTools.isPlayableVideo(source.url)
                : false
            library.update(id) { item in
                item.mediaFileName = Self.playbackFileName
                item.duration = info.duration
                if source.url != playbackURL {
                    item.videoPath = playableVideo ? source.url.path : nil
                }
                // Название из yt-dlp ставим, только если запись не успели переименовать: до этого её название — сама ссылка.
                if let title = source.title, !title.isEmpty, item.title == transcript.sourceReference {
                    item.title = title
                }
            }

            report(.preparingAudio, 0)
            let speechURL = FileManager.default.temporaryDirectory.appending(path: "steno-\(id.uuidString).f32")
            defer { try? FileManager.default.removeItem(at: speechURL) }
            try await MediaTools.makeSpeechAudio(
                from: source.url,
                to: speechURL,
                restore: transcript.options.restoreAudio,
                duration: info.duration
            ) { report(.preparingAudio, $0) }
            discardTemporarySource(source, transcript: transcript)

            let samples = try await Task.detached { try MediaTools.loadSamples(from: speechURL) }.value
            let output = try await engine.transcribe(samples: samples, options: transcript.options, report: report)
            try Task.checkCancellation()

            library.update(id) { item in
                item.segments = output.segments
                item.speakers = output.speakers
                item.language = output.language
                item.translations = []
                item.status = .done
            }
            notifyFinished(title: library.transcript(id: id)?.title ?? transcript.title, failed: false)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let message = cancelled ? Self.cancelledMessage : error.localizedDescription
            library.update(id) { $0.status = .failed(message) }
            if !cancelled {
                notifyFinished(title: transcript.title, failed: true)
            }
        }
    }

    private struct ResolvedSource {
        let url: URL
        let title: String?
        let isTemporary: Bool
    }

    /// Повторная расшифровка берёт уже сохранённый звук: исходник мог переехать или быть удалён.
    private func resolveSource(
        _ transcript: Transcript,
        directory: URL,
        report: @escaping StageReporter
    ) async throws -> ResolvedSource {
        if let existing = library.mediaURL(for: transcript) {
            return ResolvedSource(url: existing, title: nil, isTemporary: false)
        }
        switch transcript.source {
        case .file, .recording:
            let url = URL(filePath: transcript.sourceReference)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            return ResolvedSource(url: url, title: nil, isTemporary: transcript.source == .recording)
        case .link:
            guard let link = URL(string: transcript.sourceReference) else { throw MediaError.downloadFailed }
            report(.downloadingSource, 0)
            let download = try await LinkImporter.download(link, into: directory) { report(.downloadingSource, $0) }
            return ResolvedSource(url: download.fileURL, title: download.title, isTemporary: true)
        }
    }

    private func discardTemporarySource(_ source: ResolvedSource, transcript: Transcript) {
        guard source.isTemporary else { return }
        try? FileManager.default.removeItem(at: source.url)
    }

    private func setProgress(_ id: UUID, stage: JobStage, fraction: Double?) {
        guard activeID == id else { return }
        progress[id] = JobProgress(stage: stage, fraction: fraction)
    }

    // MARK: Системные сигналы

    private func updateDockBadge() {
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func notifyFinished(title: String, failed: Bool) {
        guard Bundle.main.bundleIdentifier != nil, NSApp?.isActive == false else { return }
        let content = UNMutableNotificationContent()
        content.title = failed ? "Не удалось расшифровать" : "Расшифровка готова"
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
