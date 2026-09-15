import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var renamingFolderID: UUID?
    @State private var folderName = ""
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        @Bindable var app = app
        List(selection: $app.sidebarSelection) {
            Section("Библиотека") {
                Label("Все расшифровки", systemImage: "tray.full")
                    .tag(SidebarItem.all)
                    .dropDestination(for: String.self) { items, _ in _ = move(items, to: nil) }
                Label("Недавние", systemImage: "clock")
                    .tag(SidebarItem.recent)
                Label("В очереди", systemImage: "hourglass")
                    .badge(app.queue.count)
                    .tag(SidebarItem.queue)
            }

            Section("Папки") {
                ForEach(app.library.folders) { folder in
                    folderRow(folder)
                        .tag(SidebarItem.folder(folder.id))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let release = app.updater.availableRelease {
                    Button {
                        app.sheet = .update(release)
                    } label: {
                        Label("Доступна версия \(release.version.description)", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                }
                Button {
                    startRenaming(app.createFolder())
                } label: {
                    Label("Новая папка", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: Folder) -> some View {
        if renamingFolderID == folder.id {
            TextField("Название папки", text: $folderName)
                .focused($isRenameFocused)
                .onSubmit { finishRenaming(folder.id) }
                .onChange(of: isRenameFocused) { _, focused in
                    if !focused { finishRenaming(folder.id) }
                }
        } else {
            Label(folder.name, systemImage: "folder")
                .dropDestination(for: String.self) { items, _ in _ = move(items, to: folder.id) }
                .contextMenu {
                    Button("Переименовать") { startRenaming(folder.id) }
                    Divider()
                    Button("Удалить папку", role: .destructive) { app.deleteFolder(folder.id) }
                }
        }
    }

    private func startRenaming(_ id: UUID) {
        folderName = app.library.folders.first { $0.id == id }?.name ?? ""
        renamingFolderID = id
        isRenameFocused = true
    }

    private func finishRenaming(_ id: UUID) {
        guard renamingFolderID == id else { return }
        app.library.renameFolder(id, to: folderName)
        renamingFolderID = nil
    }

    private func move(_ items: [String], to folderID: UUID?) -> Bool {
        let ids = Set(items.compactMap(UUID.init(uuidString:)))
        guard !ids.isEmpty else { return false }
        app.library.move(ids, to: folderID)
        return true
    }
}
