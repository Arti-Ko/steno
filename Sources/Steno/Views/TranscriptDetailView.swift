import AppKit
import AVKit
import SwiftUI

struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var app
    let transcript: Transcript

    @State private var findQuery = ""
    @State private var matchIndex = 0
    @FocusState private var isFindFocused: Bool

    var body: some View {
        Group {
            switch transcript.status {
            case .done:
                transcriptContent
            case .queued, .processing:
                ProcessingView(transcript: transcript, progress: app.queue.progress[transcript.id])
            case .failed(let message):
                ContentUnavailableView {
                    Label("Не удалось расшифровать", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Попробовать снова") { app.retranscribe(transcript.id) }
                }
            }
        }
        .navigationTitle(transcript.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .onAppear(perform: loadMedia)
        .onChange(of: transcript.mediaFileName) { loadMedia() }
    }

    // MARK: Текст

    private var transcriptContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transcript.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)

                    if app.player.loadedID == transcript.id, app.player.videoURL != nil {
                        VideoPreview(player: app.player.player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 14, style: .continuous))
                            .padding(.bottom, 18)
                    }
                    ForEach(transcript.segments) { segment in
                        SegmentRow(
                            text: transcript.text(of: segment, language: effectiveLanguage),
                            start: segment.start,
                            speakerName: transcript.speakerName(for: segment.speaker),
                            speakerColor: SpeakerPalette.color(for: segment.speaker),
                            speakers: transcript.speakers,
                            isActive: segment.id == activeSegmentID,
                            highlight: findQuery,
                            isCurrentMatch: segment.id == currentMatchID,
                            isEditing: app.isEditing,
                            longClock: transcript.duration >= 3600,
                            onSeek: { app.player.play(from: segment.start) },
                            onCommit: { commit(segment.id, text: $0) },
                            onAssign: { assign(segment.id, to: $0) }
                        )
                        .id(segment.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 110)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if app.isFindVisible {
                    FindBar(
                        query: $findQuery,
                        index: $matchIndex,
                        matchCount: matchIDs.count,
                        isFocused: $isFindFocused,
                        onClose: closeFind
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }
            }
            .overlay(alignment: .bottom) {
                PlayerBar()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .onChange(of: activeSegmentID) { _, id in
                guard let id, app.player.isPlaying, !app.isEditing else { return }
                withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: currentMatchID) { _, id in
                guard let id else { return }
                withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: findQuery) { matchIndex = 0 }
            .onChange(of: app.isFindVisible) { _, visible in
                isFindFocused = visible
            }
        }
    }

    private var effectiveLanguage: String? {
        transcript.translation(for: app.displayLanguage) == nil ? nil : app.displayLanguage
    }

    private var activeSegmentID: UUID? {
        guard app.player.loadedID == transcript.id else { return nil }
        let time = app.player.currentTime
        var low = 0
        var high = transcript.segments.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if transcript.segments[middle].start <= time + 0.05 {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let found, time <= transcript.segments[found].end + 1.5 else { return nil }
        return transcript.segments[found].id
    }

    private var matchIDs: [UUID] {
        guard !findQuery.isEmpty else { return [] }
        return transcript.segments
            .filter { transcript.text(of: $0, language: effectiveLanguage).range(of: findQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(\.id)
    }

    private var currentMatchID: UUID? {
        let ids = matchIDs
        guard !ids.isEmpty else { return nil }
        return ids[((matchIndex % ids.count) + ids.count) % ids.count]
    }

    private var subtitle: String {
        var parts = [TimeFormat.spoken(transcript.duration)]
        if let language = transcript.language {
            parts.append(Languages.name(for: language))
        }
        if transcript.speakers.count > 1 {
            parts.append(RussianPlural.speakers(transcript.speakers.count))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Панель инструментов

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if transcript.status == .done {
            if !transcript.translations.isEmpty {
                ToolbarItem {
                    Picker("Язык текста", selection: Binding(get: { effectiveLanguage }, set: { app.displayLanguage = $0 })) {
                        Text("Оригинал").tag(String?.none)
                        ForEach(transcript.translations, id: \.language) { translation in
                            Text(Languages.name(for: translation.language)).tag(Optional(translation.language))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            ToolbarItemGroup {
                Toggle(isOn: Binding(get: { app.isEditing }, set: { app.isEditing = $0 })) {
                    Label("Редактировать", systemImage: "pencil")
                }
                .help("Редактировать текст")
                Button { app.sheet = .speakers(transcript.id) } label: {
                    Label("Спикеры", systemImage: "person.2")
                }
                .help("Имена спикеров")
                .disabled(transcript.speakers.isEmpty)
                Button { app.sheet = .translate(transcript.id) } label: {
                    Label("Перевести", systemImage: "translate")
                }
                .help("Перевести расшифровку")
            }
            ToolbarItem {
                Button { app.export([transcript.id]) } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .help("Экспортировать")
            }
        }
        ToolbarItem {
            Menu {
                if transcript.status == .done {
                    Button("Скопировать весь текст") { copyAllText() }
                    Button("Найти в расшифровке") { app.isFindVisible = true }
                    Divider()
                }
                Menu("Расшифровать заново") {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Button {
                            var options = transcript.options
                            options.mode = mode
                            app.retranscribe(transcript.id, options: options)
                        } label: {
                            Label(mode.title, systemImage: mode.symbol)
                        }
                    }
                }
                .disabled(transcript.isPending)
                Button("Показать в Finder") { app.revealInFinder(transcript.id) }
            } label: {
                Label("Ещё", systemImage: "ellipsis")
            }
        }
    }

    // MARK: Действия

    private func loadMedia() {
        guard let audioURL = app.library.mediaURL(for: transcript) else { return }
        app.player.load(transcript.id, audioURL: audioURL, videoURL: app.library.videoURL(for: transcript), duration: transcript.duration)
    }

    private func closeFind() {
        app.isFindVisible = false
        findQuery = ""
    }

    private func copyAllText() {
        var options = ExportOptions()
        options.language = effectiveLanguage
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Exporter.plainText(transcript, options: options), forType: .string)
    }

    private func commit(_ segmentID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = effectiveLanguage
        app.library.update(transcript.id) { item in
            guard let index = item.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            if let language, let translationIndex = item.translations.firstIndex(where: { $0.language == language }) {
                item.translations[translationIndex].texts[segmentID.uuidString] = trimmed
            } else {
                item.segments[index].text = trimmed
            }
        }
    }

    private func assign(_ segmentID: UUID, to speaker: Int) {
        app.library.update(transcript.id) { item in
            guard let index = item.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            if !item.speakers.contains(where: { $0.id == speaker }) {
                item.speakers.append(Speaker(id: speaker, name: "Спикер \(speaker + 1)"))
            }
            item.segments[index].speaker = speaker
        }
    }
}

// MARK: - Реплика

private struct SegmentRow: View {
    let text: String
    let start: Double
    let speakerName: String?
    let speakerColor: Color
    let speakers: [Speaker]
    let isActive: Bool
    let highlight: String
    let isCurrentMatch: Bool
    let isEditing: Bool
    let longClock: Bool
    let onSeek: () -> Void
    let onCommit: (String) -> Void
    let onAssign: (Int) -> Void

    @State private var draft = ""
    @State private var isDraftLoaded = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let speakerName {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(speakerColor)
                            .frame(width: 7, height: 7)
                        Text(speakerName)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                Text(TimeFormat.clock(start, forceHours: longClock))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if isEditing {
                TextField("Текст реплики", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineSpacing(3)
                    .focused($isFocused)
                    .onAppear {
                        draft = text
                        isDraftLoaded = true
                    }
                    .onSubmit(commitIfChanged)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commitIfChanged() }
                    }
                    .onDisappear(perform: commitIfChanged)
            } else {
                Text(highlighted)
                    .font(.body)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.12) : .clear)
        }
        .contentShape(.rect)
        .onTapGesture {
            if !isEditing { onSeek() }
        }
        .contextMenu {
            Button("Воспроизвести отсюда", action: onSeek)
            Button("Скопировать") { copy(text) }
            Button("Скопировать с отметкой времени") {
                copy("[\(TimeFormat.clock(start, forceHours: longClock))] " + [speakerName, text].compactMap { $0 }.joined(separator: ": "))
            }
            Divider()
            Menu("Спикер") {
                ForEach(speakers) { speaker in
                    Button(speaker.name) { onAssign(speaker.id) }
                }
                if !speakers.isEmpty {
                    Divider()
                }
                Button("Новый спикер") { onAssign((speakers.map(\.id).max() ?? -1) + 1) }
            }
        }
    }

    private var highlighted: AttributedString {
        var result = AttributedString(text)
        guard !highlight.isEmpty else { return result }
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result[searchStart...].range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = isCurrentMatch ? Color.yellow.opacity(0.75) : Color.yellow.opacity(0.3)
            searchStart = range.upperBound
        }
        return result
    }

    private func commitIfChanged() {
        // Не сохраняем пустой черновик, который ещё не успели заполнить текстом реплики.
        guard isDraftLoaded, draft != text else { return }
        onCommit(draft)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// MARK: - Поиск

private struct FindBar: View {
    @Binding var query: String
    @Binding var index: Int
    let matchCount: Int
    var isFocused: FocusState<Bool>.Binding
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Найти в расшифровке", text: $query)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onSubmit { index += 1 }
            if !query.isEmpty {
                Text(matchCount == 0 ? "Нет совпадений" : "\((index % matchCount + matchCount) % matchCount + 1) из \(matchCount)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ControlGroup {
                Button { index -= 1 } label: { Image(systemName: "chevron.up") }
                Button { index += 1 } label: { Image(systemName: "chevron.down") }
            }
            .fixedSize()
            .disabled(matchCount == 0)
            Button("Готово", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .onExitCommand(perform: onClose)
    }
}

// MARK: - Обработка

private struct ProcessingView: View {
    @Environment(AppModel.self) private var app
    let transcript: Transcript
    let progress: JobProgress?

    var body: some View {
        VStack(spacing: 16) {
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
                    .frame(width: 260)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text((progress?.stage ?? .waiting).title)
                .font(.title3.weight(.semibold))
            if let hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button("Отменить") { app.queue.cancel(transcript.id) }
                .buttonStyle(.glass)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hint: String? {
        switch progress?.stage {
        case .downloadingModel: "Модель «\(transcript.options.mode.title)» скачивается один раз, дальше всё работает без интернета."
        case .loadingModel: "При первом запуске macOS оптимизирует модель под этот Mac — это может занять несколько минут."
        case .diarizing: "Определяю, кто и когда говорит."
        case .waiting, nil: "Файл ждёт своей очереди."
        default: nil
        }
    }
}

private struct VideoPreview: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
