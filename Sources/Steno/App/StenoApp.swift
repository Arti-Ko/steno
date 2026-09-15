import SwiftUI

@main
struct StenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("Steno", id: "main") {
            ContentView()
                .environment(app)
                .onAppear {
                    appDelegate.openHandler = { urls in app.newTranscription(files: urls) }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            StenoCommands(app: app)
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

/// Принимает файлы, брошенные на иконку в Dock или открытые через «Открыть с помощью».
/// applicationDidFinishLaunching здесь не реализуем: это перекрывает создание окна SwiftUI.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []

    var openHandler: (([URL]) -> Void)? {
        didSet {
            guard let openHandler, !pendingURLs.isEmpty else { return }
            openHandler(pendingURLs)
            pendingURLs = []
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let openHandler {
            openHandler(files)
        } else {
            pendingURLs += files
        }
    }
}

struct StenoCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Проверить обновления…") {
                Task { await app.updater.check(userInitiated: true) }
            }
            .disabled(!app.updater.canUpdate || app.updater.isBusy)
        }

        CommandGroup(replacing: .newItem) {
            Button("Новая расшифровка…") { app.newTranscription() }
                .keyboardShortcut("n")
            Button("Открыть файлы…") { app.chooseFiles() }
                .keyboardShortcut("o")
            Button("Расшифровать по ссылке…") { app.newTranscription(source: .link) }
                .keyboardShortcut("l")
            Button("Новая запись…") { app.newTranscription(source: .recording) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Новая папка") { app.createFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .importExport) {
            Button("Экспортировать…") { app.export(app.selection) }
                .keyboardShortcut("e")
                .disabled(app.selection.isEmpty)
        }

        CommandGroup(after: .textEditing) {
            Button("Найти в расшифровке") { app.isFindVisible = true }
                .keyboardShortcut("f")
                .disabled(app.selectedTranscript == nil)
        }

        CommandMenu("Воспроизведение") {
            Button(app.player.isPlaying ? "Пауза" : "Воспроизвести") { app.player.togglePlay() }
                .disabled(!app.player.hasMedia)
            Button("Назад на 5 секунд") { app.player.skip(by: -5) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Вперёд на 5 секунд") { app.player.skip(by: 5) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            Picker("Скорость", selection: Binding(get: { app.player.rate }, set: { app.player.setRate($0) })) {
                ForEach(PlayerModel.rates, id: \.self) { rate in
                    Text(rate.rateLabel).tag(rate)
                }
            }
        }
    }
}
