import SwiftUI

struct TranscriptListView: View {
    @Environment(AppModel.self) private var app
    @State private var pendingDeletion: Set<UUID> = []

    var body: some View {
        @Bindable var app = app
        let transcripts = app.visibleTranscripts
        List(selection: $app.selection) {
            ForEach(transcripts) { transcript in
                TranscriptRow(
                    transcript: transcript,
                    progress: app.queue.progress[transcript.id],
                    isRenaming: app.renamingTranscriptID == transcript.id,
                    onRename: { app.finishRename(transcript.id, to: $0) }
                )
                .tag(transcript.id)
                .draggable(transcript.id.uuidString)
            }
        }
        .navigationTitle(title)
        .searchable(text: $app.searchText, prompt: "Название или фраза")
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            // Двойной щелчок или Return по записи — переименование, как в Finder.
            if ids.count == 1, let id = ids.first {
                app.renamingTranscriptID = id
            }
        }
        .onDeleteCommand {
            pendingDeletion = app.selection
        }
        .overlay {
            if transcripts.isEmpty {
                if app.searchText.isEmpty {
                    ContentUnavailableView("Здесь пока пусто", systemImage: "tray")
                } else {
                    ContentUnavailableView.search(text: app.searchText)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { app.newTranscription() } label: {
                    Label("Новая расшифровка", systemImage: "plus")
                }
                .help("Новая расшифровка")
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
        ) {
            Button("Удалить", role: .destructive) {
                app.delete(pendingDeletion)
                pendingDeletion = []
            }
        } message: {
            Text("Текст и сохранённый звук будут удалены. Исходные файлы не пострадают.")
        }
    }

    private var title: String {
        switch app.sidebarSelection ?? .all {
        case .all: "Все расшифровки"
        case .recent: "Недавние"
        case .queue: "В очереди"
        case .folder(let id): app.library.folders.first { $0.id == id }?.name ?? "Папка"
        }
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1 ? "Удалить расшифровку?" : "Удалить расшифровки (\(pendingDeletion.count))?"
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        let items = app.library.transcripts.filter { ids.contains($0.id) }
        if !items.isEmpty {
            if items.contains(where: { $0.status == .done }) {
                Button("Экспортировать…") { app.export(ids) }
            }
            Menu("Переместить в папку") {
                Button("Без папки") { app.library.move(ids, to: nil) }
                if !app.library.folders.isEmpty {
                    Divider()
                }
                ForEach(app.library.folders) { folder in
                    Button(folder.name) { app.library.move(ids, to: folder.id) }
                }
            }
            Divider()
            if items.contains(where: \.isPending) {
                Button("Отменить расшифровку") { ids.forEach(app.queue.cancel) }
            } else {
                Button("Расшифровать заново") { ids.forEach { app.retranscribe($0) } }
            }
            if items.count == 1, let item = items.first {
                Button("Переименовать") { app.renamingTranscriptID = item.id }
                Button("Показать в Finder") { app.revealInFinder(item.id) }
            }
            Divider()
            Button("Удалить…", role: .destructive) { pendingDeletion = ids }
        }
    }
}

private struct TranscriptRow: View {
    let transcript: Transcript
    let progress: JobProgress?
    let isRenaming: Bool
    /// Новое название или nil, если переименование отменили.
    let onRename: (String?) -> Void

    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: sourceSymbol)
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                if isRenaming {
                    TextField("Название", text: $draft)
                        .textFieldStyle(.plain)
                        .fontWeight(.medium)
                        .focused($isFieldFocused)
                        .task {
                            draft = transcript.title
                            isFieldFocused = true
                        }
                        .onSubmit { onRename(draft) }
                        .onExitCommand { onRename(nil) }
                        .onChange(of: isFieldFocused) { _, focused in
                            if !focused { onRename(draft) }
                        }
                } else {
                    Text(transcript.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(transcript.createdAt, format: .dateTime.day().month(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            status
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        switch transcript.status {
        case .done:
            Text(metadata)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .queued, .processing:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(progress?.stage.title ?? JobStage.waiting.title)
                    Spacer()
                    if let fraction = progress?.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var sourceSymbol: String {
        switch transcript.source {
        case .file: transcript.videoPath == nil ? "waveform" : "film"
        case .link: "link"
        case .recording: "mic"
        }
    }

    private var metadata: String {
        var parts = [TimeFormat.clock(transcript.duration), transcript.options.mode.title]
        if transcript.speakers.count > 1 {
            parts.append(RussianPlural.speakers(transcript.speakers.count))
        }
        if let language = transcript.language {
            parts.append(Languages.name(for: language))
        }
        return parts.joined(separator: " · ")
    }
}
