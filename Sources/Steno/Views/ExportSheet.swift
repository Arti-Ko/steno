import AppKit
import SwiftUI

struct ExportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let transcriptIDs: [UUID]

    @AppStorage("exportFormat") private var storedFormat = ExportFormat.docx.rawValue
    @State private var format = ExportFormat.docx
    @State private var options = ExportOptions()
    @State private var didCopy = false
    @State private var errorText: String?

    private static let previewLimit = 1500

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Формат", selection: $format) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    if !sharedTranslationLanguages.isEmpty {
                        Picker("Язык текста", selection: $options.language) {
                            Text("Оригинал").tag(String?.none)
                            ForEach(sharedTranslationLanguages, id: \.self) { code in
                                Text(Languages.name(for: code)).tag(Optional(code))
                            }
                        }
                    }
                }

                if format.isSubtitle {
                    Section("Субтитры") {
                        Stepper(value: $options.maxCharactersPerLine, in: 20...80, step: 2) {
                            LabeledContent("Символов в строке", value: "\(options.maxCharactersPerLine)")
                        }
                        Picker("Строк в титре", selection: $options.maxLines) {
                            Text("Одна").tag(1)
                            Text("Две").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Stepper(value: $options.maxCueDuration, in: 1...10, step: 0.5) {
                            LabeledContent(
                                "Длительность титра до",
                                value: options.maxCueDuration.formatted(.number.precision(.fractionLength(0...1))) + " с"
                            )
                        }
                        Toggle("Имена спикеров", isOn: $options.includeSpeakers)
                    }
                } else if format != .json {
                    Section("Оформление") {
                        Toggle("Отметки времени", isOn: $options.includeTimestamps)
                        Toggle("Имена спикеров", isOn: $options.includeSpeakers)
                        Toggle("Объединять подряд идущие реплики одного спикера", isOn: $options.mergeSpeakerTurns)
                            .disabled(!options.includeSpeakers)
                    }
                }

                if let preview {
                    Section {
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } header: {
                        HStack {
                            Text("Предпросмотр")
                            Spacer()
                            Button(didCopy ? "Скопировано" : "Скопировать всё", action: copyToPasteboard)
                                .buttonStyle(.borderless)
                        }
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(transcripts.count == 1 ? "Экспорт" : "Экспорт: \(transcripts.count)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(transcripts.count == 1 ? "Сохранить…" : "Выбрать папку…", action: save)
                }
            }
        }
        .frame(width: 540, height: 620)
        .onAppear {
            format = ExportFormat(rawValue: storedFormat) ?? .docx
            options.includeSpeakers = !format.isSubtitle
        }
        .onChange(of: format) { _, newFormat in
            storedFormat = newFormat.rawValue
            options.includeSpeakers = !newFormat.isSubtitle
            didCopy = false
        }
        .onChange(of: options) { didCopy = false }
    }

    private var transcripts: [Transcript] {
        transcriptIDs.compactMap { app.library.transcript(id: $0) }
    }

    private var sharedTranslationLanguages: [String] {
        guard let first = transcripts.first else { return [] }
        let shared = transcripts.dropFirst().reduce(Set(first.translations.map(\.language))) { result, transcript in
            result.intersection(transcript.translations.map(\.language))
        }
        return shared.sorted()
    }

    private var preview: String? {
        guard transcripts.count == 1, let transcript = transcripts.first,
              let text = Exporter.text(for: transcript, format: format, options: options) else { return nil }
        return text.count > Self.previewLimit ? String(text.prefix(Self.previewLimit)) + "\n…" : text
    }

    private func copyToPasteboard() {
        guard let transcript = transcripts.first,
              let text = Exporter.text(for: transcript, format: format, options: options) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
    }

    private func save() {
        errorText = nil
        do {
            if transcripts.count == 1, let transcript = transcripts.first {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = Exporter.fileName(for: transcript, format: format, options: options)
                panel.allowedContentTypes = [format.contentType]
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try Exporter.data(for: transcript, format: format, options: options).write(to: url, options: .atomic)
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Экспортировать"
                panel.message = "Каждая расшифровка сохранится отдельным файлом"
                guard panel.runModal() == .OK, let directory = panel.url else { return }
                for transcript in transcripts {
                    let name = Exporter.fileName(for: transcript, format: format, options: options)
                    let data = try Exporter.data(for: transcript, format: format, options: options)
                    try data.write(to: uniqueURL(in: directory, name: name), options: .atomic)
                }
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        var candidate = directory.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base) \(counter).\(fileExtension)")
            counter += 1
        }
        return candidate
    }
}
