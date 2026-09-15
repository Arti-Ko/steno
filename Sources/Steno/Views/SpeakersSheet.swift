import SwiftUI

struct SpeakersSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let transcriptID: UUID

    @State private var names: [Int: String] = [:]

    var body: some View {
        let transcript = app.library.transcript(id: transcriptID)
        NavigationStack {
            Form {
                Section {
                    ForEach(transcript?.speakers ?? []) { speaker in
                        row(speaker, in: transcript)
                    }
                } footer: {
                    Text("Имена попадут в экспорт. Чтобы переназначить отдельную реплику, откройте её контекстное меню в тексте.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Спикеры")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        saveNames()
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 460, height: 400)
        .onAppear {
            names = Dictionary(uniqueKeysWithValues: (transcript?.speakers ?? []).map { ($0.id, $0.name) })
        }
    }

    private func row(_ speaker: Speaker, in transcript: Transcript?) -> some View {
        let count = transcript?.segments.filter { $0.speaker == speaker.id }.count ?? 0
        let others = (transcript?.speakers ?? []).filter { $0.id != speaker.id }
        return HStack(spacing: 10) {
            Circle()
                .fill(SpeakerPalette.color(for: speaker.id))
                .frame(width: 10, height: 10)
            TextField(
                "Имя",
                text: Binding(get: { names[speaker.id] ?? speaker.name }, set: { names[speaker.id] = $0 }),
                prompt: Text("Спикер \(speaker.id + 1)")
            )
            .labelsHidden()
            Text("\(count) " + RussianPlural.form(count, one: "реплика", few: "реплики", many: "реплик"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if !others.isEmpty {
                Menu {
                    ForEach(others) { target in
                        Button(names[target.id] ?? target.name) { merge(speaker.id, into: target.id) }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.merge")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Объединить с другим спикером")
            }
        }
    }

    private func saveNames() {
        app.library.update(transcriptID) { item in
            for index in item.speakers.indices {
                let name = names[item.speakers[index].id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty {
                    item.speakers[index].name = name
                }
            }
        }
    }

    /// Все реплики спикера переходят другому, сам спикер исчезает.
    private func merge(_ source: Int, into target: Int) {
        saveNames()
        app.library.update(transcriptID) { item in
            for index in item.segments.indices where item.segments[index].speaker == source {
                item.segments[index].speaker = target
            }
            item.speakers.removeAll { $0.id == source }
        }
        names[source] = nil
    }
}
