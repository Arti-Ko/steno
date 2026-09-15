import Foundation
import Observation
import os

/// Библиотека расшифровок: каждая лежит в своей папке с transcript.json и звуком.
@MainActor
@Observable
final class LibraryStore {
    private(set) var transcripts: [Transcript] = []
    private(set) var folders: [Folder] = []

    @ObservationIgnored let rootURL: URL
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "org.sleepycoffee.steno.library")
    @ObservationIgnored private let logger = Logger(subsystem: "org.sleepycoffee.steno", category: "library")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    nonisolated static var defaultRootURL: URL {
        URL.applicationSupportDirectory.appending(path: "Steno", directoryHint: .isDirectory)
    }

    init(rootURL: URL = LibraryStore.defaultRootURL) {
        self.rootURL = rootURL
        load()
    }

    var libraryURL: URL { rootURL.appending(path: "Library", directoryHint: .isDirectory) }
    var modelsURL: URL { rootURL.appending(path: "Models", directoryHint: .isDirectory) }
    private var foldersFileURL: URL { rootURL.appending(path: "folders.json") }

    func directory(for id: UUID) -> URL {
        libraryURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func transcript(id: UUID?) -> Transcript? {
        guard let id else { return nil }
        return transcripts.first { $0.id == id }
    }

    func mediaURL(for transcript: Transcript) -> URL? {
        guard let name = transcript.mediaFileName else { return nil }
        let url = directory(for: transcript.id).appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func videoURL(for transcript: Transcript) -> URL? {
        guard let path = transcript.videoPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path)
    }

    // MARK: Расшифровки

    func add(_ transcript: Transcript) {
        do {
            try FileManager.default.createDirectory(at: directory(for: transcript.id), withIntermediateDirectories: true)
        } catch {
            logger.error("Не создать папку расшифровки: \(error.localizedDescription)")
        }
        transcripts.insert(transcript, at: 0)
        persist(transcript)
    }

    func update(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let index = transcripts.firstIndex(where: { $0.id == id }) else { return }
        var copy = transcripts[index]
        change(&copy)
        guard copy != transcripts[index] else { return }
        transcripts[index] = copy
        persist(copy)
    }

    func delete(_ ids: Set<UUID>) {
        transcripts.removeAll { ids.contains($0.id) }
        let directories = ids.map(directory(for:))
        writeQueue.async { [logger] in
            for directory in directories {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    logger.error("Не удалить \(directory.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    func move(_ ids: Set<UUID>, to folderID: UUID?) {
        for id in ids {
            update(id) { $0.folderID = folderID }
        }
    }

    // MARK: Папки

    @discardableResult
    func createFolder() -> Folder {
        let base = "Новая папка"
        let names = Set(folders.map(\.name))
        var name = base
        var counter = 2
        while names.contains(name) {
            name = "\(base) \(counter)"
            counter += 1
        }
        let folder = Folder(name: name)
        folders.append(folder)
        persistFolders()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        persistFolders()
    }

    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        persistFolders()
        let contained = Set(transcripts.filter { $0.folderID == id }.map(\.id))
        move(contained, to: nil)
    }

    // MARK: Диск

    private func persist(_ transcript: Transcript) {
        let url = directory(for: transcript.id).appending(path: "transcript.json")
        do {
            let data = try Self.encoder.encode(transcript)
            writeQueue.async { [logger] in
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    logger.error("Не сохранить расшифровку: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Не закодировать расшифровку: \(error.localizedDescription)")
        }
    }

    private func persistFolders() {
        let url = foldersFileURL
        do {
            let data = try Self.encoder.encode(folders)
            writeQueue.async { [logger] in
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    logger.error("Не сохранить папки: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Не закодировать папки: \(error.localizedDescription)")
        }
    }

    private func load() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        } catch {
            logger.error("Не создать библиотеку: \(error.localizedDescription)")
        }

        if let data = try? Data(contentsOf: foldersFileURL) {
            do {
                folders = try Self.decoder.decode([Folder].self, from: data)
            } catch {
                logger.error("Повреждён folders.json: \(error.localizedDescription)")
            }
        }

        let entries = (try? fileManager.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Transcript] = []
        for entry in entries {
            let file = entry.appending(path: "transcript.json")
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                var transcript = try Self.decoder.decode(Transcript.self, from: data)
                // Приложение закрыли посреди обработки — вернём в очередь.
                if transcript.status == .processing {
                    transcript.status = .queued
                }
                loaded.append(transcript)
            } catch {
                logger.error("Повреждена расшифровка \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        transcripts = loaded.sorted { $0.createdAt > $1.createdAt }
    }
}
