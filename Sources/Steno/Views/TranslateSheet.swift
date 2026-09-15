import SwiftUI
import Translation

/// Перевод расшифровки системными моделями Apple прямо на устройстве.
struct TranslateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let transcriptID: UUID

    @State private var targets: [Locale.Language] = []
    @State private var target: Locale.Language?
    @State private var isSourceSupported: Bool?
    @State private var configuration: TranslationSession.Configuration?
    @State private var progress: Double?
    @State private var errorText: String?

    private static let batchSize = 40

    var body: some View {
        let transcript = app.library.transcript(id: transcriptID)
        NavigationStack {
            Form {
                Section {
                    LabeledContent("С языка", value: transcript?.language.map(Languages.name(for:)) ?? "Не определён")
                    Picker("На язык", selection: $target) {
                        Text("Выберите").tag(Locale.Language?.none)
                        ForEach(targets, id: \.self) { language in
                            Text(Languages.name(for: language.minimalIdentifier)).tag(Optional(language))
                        }
                    }
                    .disabled(progress != nil)
                } footer: {
                    Text("Перевод идёт на этом Mac. Если языковой пакет ещё не установлен, macOS предложит его скачать.")
                        .foregroundStyle(.secondary)
                }

                if isSourceSupported == false {
                    Section {
                        Label("Системный переводчик не поддерживает язык этой расшифровки.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if let progress {
                    Section {
                        ProgressView(value: progress) {
                            Text("Перевожу…")
                        }
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if let translations = transcript?.translations, !translations.isEmpty {
                    Section("Готовые переводы") {
                        ForEach(translations, id: \.language) { translation in
                            HStack {
                                Text(Languages.name(for: translation.language))
                                Spacer()
                                Button("Удалить", role: .destructive) { removeTranslation(translation.language) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Перевод")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Перевести", action: start)
                        .disabled(target == nil || progress != nil || isSourceSupported != true)
                }
            }
        }
        .frame(width: 480, height: 460)
        .task { await loadLanguages(sourceCode: transcript?.language) }
        .translationTask(configuration) { session in
            await translate(using: session)
        }
    }

    private func loadLanguages(sourceCode: String?) async {
        let supported = await LanguageAvailability().supportedLanguages
        guard let sourceCode else {
            isSourceSupported = false
            return
        }
        let source = Locale.Language(identifier: sourceCode)
        isSourceSupported = supported.contains { $0.languageCode == source.languageCode }

        // Без региона: вместо восьми вариантов английского — один.
        var seen = Set<String>()
        targets = supported
            .filter { $0.languageCode != source.languageCode }
            .compactMap { language -> Locale.Language? in
                let generic = Locale.Language(languageCode: language.languageCode, script: language.script)
                return seen.insert(generic.minimalIdentifier).inserted ? generic : nil
            }
            .sorted { Languages.name(for: $0.minimalIdentifier) < Languages.name(for: $1.minimalIdentifier) }
    }

    private func start() {
        guard let target, let sourceCode = app.library.transcript(id: transcriptID)?.language else { return }
        errorText = nil
        progress = 0
        let source = Locale.Language(identifier: sourceCode)
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func translate(using session: TranslationSession) async {
        guard progress != nil, let target, let transcript = app.library.transcript(id: transcriptID) else { return }
        let segments = transcript.segments.filter { !$0.text.isEmpty }
        var texts: [String: String] = [:]
        do {
            try await session.prepareTranslation()
            for offset in stride(from: 0, to: segments.count, by: Self.batchSize) {
                let batch = segments[offset..<min(offset + Self.batchSize, segments.count)]
                let requests = batch.map {
                    TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
                }
                for response in try await session.translations(from: requests) {
                    if let id = response.clientIdentifier {
                        texts[id] = response.targetText
                    }
                }
                progress = Double(min(offset + Self.batchSize, segments.count)) / Double(max(segments.count, 1))
            }
            let code = target.minimalIdentifier
            app.library.update(transcriptID) { item in
                item.translations.removeAll { $0.language == code }
                item.translations.append(TranscriptTranslation(language: code, texts: texts))
            }
            app.displayLanguage = code
            dismiss()
        } catch {
            errorText = "Не удалось перевести: \(error.localizedDescription)"
            progress = nil
        }
    }

    private func removeTranslation(_ code: String) {
        app.library.update(transcriptID) { item in
            item.translations.removeAll { $0.language == code }
        }
        if app.displayLanguage == code {
            app.displayLanguage = nil
        }
    }
}
