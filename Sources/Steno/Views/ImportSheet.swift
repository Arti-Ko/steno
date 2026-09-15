import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ImportDraft
    @State private var recorder = AudioRecorder()
    @State private var isDropTargeted = false
    @State private var isPickingFiles = false
    @State private var didSubmit = false

    init(draft: ImportDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Источник", selection: $draft.source) {
                        ForEach(ImportSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch draft.source {
                    case .files: filesSection
                    case .link: linkSection
                    case .recording: recordingSection
                    }
                }

                Section("Режим") {
                    Picker("Режим", selection: $draft.options.mode) {
                        ForEach(TranscriptionMode.allCases) { mode in
                            ModeLabel(mode: mode, isInstalled: app.models.isInstalled(mode))
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                Section("Распознавание") {
                    LanguagePicker(title: "Язык речи", selection: $draft.options.language)
                    Toggle("Распознавать спикеров", isOn: $draft.options.recognizeSpeakers)
                    if draft.options.recognizeSpeakers {
                        Picker("Количество спикеров", selection: $draft.options.speakerCount) {
                            Text("Автоматически").tag(Int?.none)
                            ForEach(2...10, id: \.self) { count in
                                Text("\(count)").tag(Optional(count))
                            }
                        }
                    }
                    Toggle(isOn: $draft.options.restoreAudio) {
                        Text("Восстановить звук")
                        Text("Шумоподавление и выравнивание громкости для шумных и тихих записей")
                    }
                }

                if !app.library.folders.isEmpty {
                    Section {
                        Picker("Папка", selection: $draft.folderID) {
                            Text("Без папки").tag(UUID?.none)
                            ForEach(app.library.folders) { folder in
                                Text(folder.name).tag(Optional(folder.id))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Новая расшифровка")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle) {
                        didSubmit = true
                        app.submit(draft)
                    }
                    .disabled(!draft.canSubmit || recorder.phase == .recording)
                }
            }
        }
        .frame(width: 540, height: 660)
        .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.audiovisualContent], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                addFiles(urls)
            }
        }
        .onChange(of: recorder.phase) { _, phase in
            if case .finished(let url) = phase {
                draft.recordingURL = url
            } else {
                draft.recordingURL = nil
            }
        }
        .onChange(of: app.incomingFiles) { _, files in
            guard !files.isEmpty else { return }
            draft.source = .files
            addFiles(files)
            app.incomingFiles = []
        }
        .onDisappear {
            if !didSubmit {
                recorder.discard()
            }
        }
    }

    private var submitTitle: String {
        let count = switch draft.source {
        case .files: draft.files.count
        case .link: draft.parsedLinks.count
        case .recording: draft.recordingURL == nil ? 0 : 1
        }
        return count > 1 ? "Расшифровать (\(count))" : "Расшифровать"
    }

    // MARK: Источники

    @ViewBuilder
    private var filesSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text("Перетащите аудио или видео")
                .foregroundStyle(.secondary)
            Button("Выбрать файлы…") { isPickingFiles = true }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
        }
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }

        ForEach(draft.files, id: \.self) { url in
            HStack {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    draft.files.removeAll { $0 == url }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Убрать из списка")
            }
        }
    }

    @ViewBuilder
    private var linkSection: some View {
        TextField("Ссылки", text: $draft.links, prompt: Text("https://www.youtube.com/watch?v=…"), axis: .vertical)
            .lineLimit(3...6)
            .labelsHidden()
        Text("YouTube, Dropbox, Google Drive и другие сайты — по одной ссылке в строке. Скачивается только звук.")
            .font(.callout)
            .foregroundStyle(.secondary)
        if ExternalTool.ytDlp.executableURL == nil {
            Label("Для ссылок нужен yt-dlp: \(ExternalTool.ytDlp.installHint)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var recordingSection: some View {
        VStack(spacing: 14) {
            Text(TimeFormat.clock(recorder.elapsed))
                .font(.system(size: 42, weight: .light))
                .monospacedDigit()
                .contentTransition(.numericText())

            Capsule()
                .fill(.quaternary)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(recorder.phase == .recording ? Color.red : Color.secondary)
                            .frame(width: proxy.size.width * recorder.level)
                            .animation(.linear(duration: 0.05), value: recorder.level)
                    }
                }
                .frame(maxWidth: 280)

            switch recorder.phase {
            case .idle:
                Button {
                    Task { await recorder.start() }
                } label: {
                    Label("Начать запись", systemImage: "record.circle")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.large)
            case .recording:
                Button {
                    recorder.stop()
                } label: {
                    Label("Остановить", systemImage: "stop.fill")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            case .finished:
                HStack(spacing: 12) {
                    Label("Запись готова", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Записать заново") { recorder.discard() }
                }
            }

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func addFiles(_ urls: [URL]) {
        let fresh = urls.filter { $0.isFileURL && !draft.files.contains($0) }
        draft.files.append(contentsOf: fresh)
    }
}

private struct ModeLabel: View {
    let mode: TranscriptionMode
    let isInstalled: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mode.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                Text(isInstalled ? mode.summary : "\(mode.summary) · скачается при первом запуске (\(ModelStore.Item.whisper(mode).approximateSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct LanguagePicker: View {
    let title: String
    @Binding var selection: String?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Определить автоматически").tag(String?.none)
            Divider()
            ForEach(Languages.whisper) { language in
                Text(language.name).tag(Optional(language.code))
            }
        }
    }
}
