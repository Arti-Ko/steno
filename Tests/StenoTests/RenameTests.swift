import Foundation
import Testing
@testable import Steno

@MainActor
@Suite("Переименование записи")
struct RenameTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "steno-rename-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeLibrary() -> (LibraryStore, UUID) {
        let library = LibraryStore(rootURL: root)
        let transcript = Transcript(
            title: "Запись 2026-09-16 10.00.00",
            source: .recording,
            sourceReference: "/tmp/запись.m4a",
            options: TranscriptionOptions()
        )
        library.add(transcript)
        return (library, transcript.id)
    }

    @Test("Новое название сохраняется без пробелов по краям")
    func renamesAndTrims() {
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, id) = makeLibrary()

        #expect(library.rename(id, to: "  Планёрка с заказчиком \n"))
        #expect(library.transcript(id: id)?.title == "Планёрка с заказчиком")
    }

    @Test("Пустое название не сохраняется")
    func rejectsEmptyTitle() {
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, id) = makeLibrary()

        #expect(!library.rename(id, to: "   "))
        #expect(library.transcript(id: id)?.title == "Запись 2026-09-16 10.00.00")
    }
}
