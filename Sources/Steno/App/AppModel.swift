import AppKit
import Observation
import UniformTypeIdentifiers
import UserNotifications

enum SidebarItem: Hashable {
    case all
    case recent
    case queue
    case folder(UUID)
}

enum ImportSource: String, CaseIterable, Identifiable {
    case files
    case link
    case recording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Файлы"
        case .link: "Ссылка"
        case .recording: "Запись"
        }
    }
}

struct ImportDraft {
    var source: ImportSource = .files
    var files: [URL] = []
    var links = ""
    var recordingURL: URL?
    var options: TranscriptionOptions
    var folderID: UUID?

    var parsedLinks: [URL] {
        links
            .split(whereSeparator: \.isNewline)
            .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.scheme == "http" || $0.scheme == "https" }
    }

    var canSubmit: Bool {
        switch source {
        case .files: !files.isEmpty
        case .link: !parsedLinks.isEmpty
        case .recording: recordingURL != nil
        }
    }
}

enum SheetRoute: Identifiable {
    case importer(ImportDraft)
    case export([UUID])
    case translate(UUID)
    case speakers(UUID)
    case update(ReleaseInfo)

    var id: String {
        switch self {
        case .importer: "importer"
        case .export(let ids): "export-" + ids.map(\.uuidString).joined()
        case .translate(let id): "translate-\(id)"
        case .speakers(let id): "speakers-\(id)"
        case .update(let release): "update-\(release.id)"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let library: LibraryStore
    let models: ModelStore
    let queue: TranscriptionQueue
    let player = PlayerModel()
    let updater = Updater()

    var sidebarSelection: SidebarItem? = .all
    var selection: Set<UUID> = []
    var searchText = ""
    var sheet: SheetRoute?
    var isEditing = false
    var isFindVisible = false
    /// Язык, в котором показывается расшифровка; nil — оригинал.
    var displayLanguage: String?
    var errorMessage: String?
    /// Файлы, брошенные на окно или Dock, пока лист импорта уже открыт.
    var incomingFiles: [URL] = []
    /// Запись, название которой сейчас редактируется в списке.
    var renamingTranscriptID: UUID?

    @ObservationIgnored private var keyMonitor: Any?
    private static let optionsKey = "defaultTranscriptionOptions"
    private static let selectionKey = "lastSelectedTranscript"
    private static let recentInterval: TimeInterval = 7 * 24 * 3600

    init() {
        let library = LibraryStore()
        self.library = library
        models = ModelStore(modelsURL: library.modelsURL)
        queue = TranscriptionQueue(library: library)
        if let saved = UserDefaults.standard.string(forKey: Self.selectionKey).flatMap(UUID.init(uuidString:)),
           library.transcript(id: saved) != nil {
            selection = [saved]
        }
        installSpaceBarShortcut()
        updater.onUpdateFound = { [weak self] release in
            self?.presentUpdate(release)
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: Выборка

    var visibleTranscripts: [Transcript] {
        let scoped: [Transcript] = switch sidebarSelection ?? .all {
        case .all: library.transcripts
        case .recent: library.transcripts.filter { $0.createdAt > Date.now.addingTimeInterval(-Self.recentInterval) }
        case .queue: library.transcripts.filter(\.isPending)
        case .folder(let id): library.transcripts.filter { $0.folderID == id }
        }
        return scoped.filter { $0.matches(searchText) }
    }

    var selectedTranscript: Transcript? {
        guard selection.count == 1 else { return nil }
        return library.transcript(id: selection.first)
    }

    /// Не перебиваем открытый лист: новая версия останется видна в сайдбаре и настройках.
    func presentUpdate(_ release: ReleaseInfo) {
        guard sheet == nil else { return }
        sheet = .update(release)
    }

    /// Открытая расшифровка восстанавливается при следующем запуске, как в системных приложениях.
    func rememberSelection() {
        let value = selection.count == 1 ? selection.first?.uuidString : nil
        UserDefaults.standard.set(value, forKey: Self.selectionKey)
    }

    private var currentFolderID: UUID? {
        if case .folder(let id) = sidebarSelection { return id }
        return nil
    }

    var defaultOptions: TranscriptionOptions {
        get {
            UserDefaults.standard.data(forKey: Self.optionsKey)
                .flatMap { try? JSONDecoder().decode(TranscriptionOptions.self, from: $0) }
                ?? TranscriptionOptions()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.optionsKey)
            }
        }
    }

    // MARK: Импорт

    func newTranscription(source: ImportSource = .files, files: [URL] = []) {
        // Лист импорта уже открыт: новые файлы дописываем в него, а не теряем.
        if case .importer = sheet {
            incomingFiles += files
            return
        }
        var draft = ImportDraft(options: defaultOptions, folderID: currentFolderID)
        draft.source = source
        draft.files = files
        sheet = .importer(draft)
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent]
        panel.message = "Выберите аудио или видео для расшифровки"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        newTranscription(files: panel.urls)
    }

    func submit(_ draft: ImportDraft) {
        defaultOptions = draft.options
        var created: [UUID] = []
        switch draft.source {
        case .files:
            for url in draft.files {
                created.append(enqueueTranscript(title: url.deletingPathExtension().lastPathComponent, source: .file, reference: url.path, draft: draft))
            }
        case .link:
            for link in draft.parsedLinks {
                created.append(enqueueTranscript(title: link.absoluteString, source: .link, reference: link.absoluteString, draft: draft))
            }
        case .recording:
            if let url = draft.recordingURL {
                created.append(enqueueTranscript(title: url.deletingPathExtension().lastPathComponent, source: .recording, reference: url.path, draft: draft))
            }
        }
        sheet = nil
        if let first = created.first {
            selection = [first]
        }
    }

    private func enqueueTranscript(title: String, source: SourceKind, reference: String, draft: ImportDraft) -> UUID {
        let transcript = Transcript(
            title: title,
            folderID: draft.folderID,
            source: source,
            sourceReference: reference,
            options: draft.options
        )
        library.add(transcript)
        queue.enqueue(transcript.id)
        return transcript.id
    }

    // MARK: Действия с расшифровками

    func retranscribe(_ id: UUID, options: TranscriptionOptions? = nil) {
        if let options {
            library.update(id) { $0.options = options }
        }
        queue.enqueue(id)
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        ids.forEach(queue.cancel)
        if let loaded = player.loadedID, ids.contains(loaded) {
            player.unload()
        }
        library.delete(ids)
        selection.subtract(ids)
    }

    /// Завершает переименование в списке; nil — отмена.
    func finishRename(_ id: UUID, to title: String?) {
        guard renamingTranscriptID == id else { return }
        renamingTranscriptID = nil
        if let title {
            library.rename(id, to: title)
        }
    }

    func revealInFinder(_ id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([library.directory(for: id)])
    }

    func export(_ ids: Set<UUID>) {
        let ready = library.transcripts.filter { ids.contains($0.id) && $0.status == .done }.map(\.id)
        guard !ready.isEmpty else { return }
        sheet = .export(ready)
    }

    @discardableResult
    func createFolder() -> UUID {
        let folder = library.createFolder()
        sidebarSelection = .folder(folder.id)
        return folder.id
    }

    func deleteFolder(_ id: UUID) {
        if sidebarSelection == .folder(id) {
            sidebarSelection = .all
        }
        library.deleteFolder(id)
    }

    // MARK: Клавиатура

    /// Пробел — пауза/воспроизведение, если фокус не в текстовом поле.
    private func installSpaceBarShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKeyDown(event) }
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.charactersIgnoringModifiers == " ", modifiers.isEmpty, sheet == nil, player.hasMedia else { return event }
        if NSApp.keyWindow?.firstResponder is NSText {
            return event
        }
        player.togglePlay()
        return nil
    }
}
