import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Основные", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Модели", systemImage: "cpu") {
                ModelSettings()
            }
            Tab("Обновления", systemImage: "arrow.triangle.2.circlepath") {
                UpdateSettings()
            }
        }
        .frame(width: 560, height: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var options = TranscriptionOptions()

    var body: some View {
        Form {
            Section("Новые расшифровки") {
                Picker("Режим", selection: $options.mode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                LanguagePicker(title: "Язык речи", selection: $options.language)
                Toggle("Распознавать спикеров", isOn: $options.recognizeSpeakers)
                Toggle("Восстанавливать звук", isOn: $options.restoreAudio)
            }

            Section("Хранилище") {
                LabeledContent("Библиотека") {
                    Button("Показать в Finder") { reveal(app.library.libraryURL) }
                }
                LabeledContent("Модели") {
                    Button("Показать в Finder") { reveal(app.library.modelsURL) }
                }
            }

            Section("Утилиты") {
                ToolRow(tool: .ffmpeg, purpose: "Импорт аудио и видео любых форматов")
                ToolRow(tool: .ytDlp, purpose: "Скачивание звука по ссылкам")
            }
        }
        .formStyle(.grouped)
        .onAppear { options = app.defaultOptions }
        .onChange(of: options) { _, newValue in
            app.defaultOptions = newValue
        }
    }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct ToolRow: View {
    let tool: ExternalTool
    let purpose: String

    var body: some View {
        LabeledContent {
            if let url = tool.executableURL {
                Label(url.path, systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            } else {
                Text(tool.installHint)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.orange)
            }
        } label: {
            Text(tool.rawValue)
            Text(purpose)
        }
    }
}

private struct UpdateSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let updater = app.updater
        Form {
            Section {
                LabeledContent("Установленная версия", value: updater.currentVersion?.description ?? "сборка для разработки")
                Toggle(
                    "Проверять обновления автоматически",
                    isOn: Binding(get: { updater.checksAutomatically }, set: { updater.setChecksAutomatically($0) })
                )
                .disabled(!updater.canUpdate)
                Toggle(isOn: Binding(get: { updater.installsAutomatically }, set: { updater.setInstallsAutomatically($0) })) {
                    Text("Устанавливать обновления автоматически")
                    Text("Новая версия скачивается в фоне и ставится, когда вы закрываете Steno")
                }
                .disabled(!updater.canUpdate || !updater.checksAutomatically)
                LabeledContent {
                    if case .readyToInstall(let release) = updater.phase {
                        Button("Перезапустить сейчас") { updater.install(release) }
                    } else if let release = updater.availableRelease {
                        Button("Установить \(release.version.description)…") { app.sheet = .update(release) }
                    } else {
                        Button("Проверить сейчас") {
                            Task { await updater.check(userInitiated: true) }
                        }
                        .disabled(updater.isBusy || !updater.canUpdate)
                    }
                } label: {
                    Text("Состояние")
                    Text(statusText(updater))
                }
            } footer: {
                Link("Все выпуски на GitHub", destination: ReleaseFeed.releasesPage)
            }
        }
        .formStyle(.grouped)
    }

    private func statusText(_ updater: Updater) -> String {
        switch updater.phase {
        case .idle:
            updater.lastCheck.map { "Проверено \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Ещё не проверялись"
        case .checking:
            "Проверяю…"
        case .upToDate:
            "Установлена последняя версия"
        case .available(let release):
            "Доступна версия \(release.version.description)"
        case .downloading(_, let fraction):
            "Загрузка: \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .readyToInstall(let release):
            "Версия \(release.version.description) скачана и установится при выходе"
        case .installing:
            "Перезапуск…"
        case .failed(let message):
            message
        }
    }
}

private struct ModelSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let models = app.models
        Form {
            Section {
                ForEach(ModelStore.Item.all) { item in
                    ModelRow(item: item, models: models)
                }
            } footer: {
                Text("Модели скачиваются сами при первой расшифровке. Здесь их можно скачать заранее или удалить, чтобы освободить место.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { models.refresh() }
        .alert(
            "Модели",
            isPresented: Binding(get: { models.errorMessage != nil }, set: { if !$0 { models.errorMessage = nil } }),
            presenting: models.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}

private struct ModelRow: View {
    let item: ModelStore.Item
    let models: ModelStore

    var body: some View {
        LabeledContent {
            if let download = models.downloads[item] {
                HStack {
                    if let fraction = download {
                        ProgressView(value: fraction)
                            .frame(width: 120)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Отменить") { models.cancel(item) }
                }
            } else if models.installed.contains(item) {
                HStack {
                    Label("Скачана", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Button("Удалить", role: .destructive) { models.delete(item) }
                }
            } else {
                Button("Скачать · \(item.approximateSize)") { models.download(item) }
            }
        } label: {
            Text(item.title)
            Text(subtitle)
        }
    }

    private var subtitle: String {
        switch item {
        case .whisper(let mode): mode.summary
        case .speakers: "Pyannote — кто и когда говорит"
        }
    }
}
