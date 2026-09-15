import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } content: {
            TranscriptListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 460)
        } detail: {
            DetailContainer()
        }
        .sheet(item: $app.sheet) { route in
            switch route {
            case .importer(let draft): ImportSheet(draft: draft)
            case .export(let ids): ExportSheet(transcriptIDs: ids)
            case .translate(let id): TranslateSheet(transcriptID: id)
            case .speakers(let id): SpeakersSheet(transcriptID: id)
            case .update(let release): UpdateSheet(release: release)
            }
        }
        .alert(
            "Что-то пошло не так",
            isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } }),
            presenting: app.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .onChange(of: app.selection) {
            app.rememberSelection()
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            app.newTranscription(files: files)
            return true
        }
    }
}

private struct DetailContainer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let transcript = app.selectedTranscript {
            TranscriptDetailView(transcript: transcript)
                .id(transcript.id)
        } else if app.selection.count > 1 {
            ContentUnavailableView {
                Label("Выбрано расшифровок: \(app.selection.count)", systemImage: "doc.on.doc")
            } actions: {
                Button("Экспортировать…") { app.export(app.selection) }
            }
        } else if app.library.transcripts.isEmpty {
            EmptyLibraryView()
        } else {
            ContentUnavailableView("Выберите расшифровку", systemImage: "waveform")
        }
    }
}

private struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("Перетащите аудио или видео", systemImage: "waveform")
        } description: {
            Text("Расшифровка идёт прямо на этом Mac — файлы никуда не отправляются.")
        } actions: {
            HStack {
                Button("Выбрать файлы…") { app.chooseFiles() }
                    .buttonStyle(.glassProminent)
                Button("По ссылке") { app.newTranscription(source: .link) }
                    .buttonStyle(.glass)
                Button("Записать") { app.newTranscription(source: .recording) }
                    .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
    }
}
