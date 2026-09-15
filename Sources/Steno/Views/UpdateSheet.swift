import AppKit
import SwiftUI

struct UpdateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let release: ReleaseInfo

    var body: some View {
        let updater = app.updater
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Доступна версия \(release.version.description)")
                        .font(.title2.weight(.semibold))
                    Text("Сейчас установлена \(updater.currentVersion?.description ?? "сборка для разработки")")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 240)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10, style: .continuous))

            if app.queue.count > 0 {
                Label("Идёт расшифровка — после перезапуска она начнётся заново.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            status(updater.phase)

            HStack {
                Button("Пропустить эту версию") {
                    updater.skip(release)
                    dismiss()
                }
                .disabled(updater.isBusy)
                Spacer()
                Link("Страница выпуска", destination: release.pageURL)
                Button("Позже") {
                    updater.cancelDownload()
                    dismiss()
                }
                Button("Установить и перезапустить") {
                    updater.install(release)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(updater.isBusy)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var notes: AttributedString {
        let text = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return AttributedString("Описание изменений — на странице выпуска.") }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    @ViewBuilder
    private func status(_ phase: Updater.Phase) -> some View {
        switch phase {
        case .downloading(_, let fraction):
            ProgressView(value: fraction) {
                Text("Загрузка обновления…")
            }
        case .installing:
            ProgressView {
                Text("Перезапуск…")
            }
            .progressViewStyle(.linear)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}
