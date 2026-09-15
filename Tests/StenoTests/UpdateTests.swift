import Foundation
import Testing
@testable import Steno

@Suite("Версии и выпуски")
struct UpdateTests {
    @Test("Разбор номера версии", arguments: [
        ("1.2.3", [1, 2, 3]),
        ("v2.0", [2, 0]),
        ("1.4.0-beta.1", [1, 4, 0]),
        (" 3 ", [3]),
    ])
    func parsesVersion(input: String, expected: [Int]) {
        #expect(AppVersion(input)?.components == expected)
    }

    @Test("Мусор не считается версией", arguments: ["", "v", "1..2", "latest", "1.x"])
    func rejectsGarbage(input: String) {
        #expect(AppVersion(input) == nil)
    }

    @Test("Версии сравниваются по числам, а не по строкам")
    func comparesNumerically() {
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
        #expect(AppVersion("2.0.0")! > AppVersion("1.99")!)
        #expect(!(AppVersion("1.0.0")! > AppVersion("1.0")!))
    }

    @Test("Выпуск с архивом разбирается")
    func parsesRelease() throws {
        let release = try #require(try ReleaseFeed.parse(releaseJSON()))
        #expect(release.version == AppVersion("1.2.0")!)
        #expect(release.archiveURL.lastPathComponent == "Steno.zip")
        #expect(release.archiveSize == 1234)
        #expect(release.notes == "Что нового")
    }

    @Test("Пререлиз не предлагается к установке")
    func ignoresPrerelease() throws {
        #expect(try ReleaseFeed.parse(releaseJSON(prerelease: true)) == nil)
    }

    @Test("Выпуск без архива приложения — ошибка")
    func missingArchiveThrows() {
        #expect(throws: UpdateError.self) {
            try ReleaseFeed.parse(releaseJSON(assets: "[]"))
        }
    }

    @Test("В окне обновления нет инструкции по установке, заголовки жирные")
    func cleansNotesForUpdateWindow() {
        let notes = "## Что нового\n\n- Быстрее импорт\n\n## Установка\n\n1. Скачайте DMG\n"
        #expect(ReleaseFeed.displayNotes(notes) == "**Что нового**\n\n- Быстрее импорт")
    }

    private func releaseJSON(tag: String = "v1.2.0", prerelease: Bool = false, assets: String? = nil) -> Data {
        let defaultAssets = #"""
        [{"name":"Steno.dmg","browser_download_url":"https://github.com/Arti-Ko/steno/releases/download/v1.2.0/Steno.dmg","size":2000},
         {"name":"Steno.zip","browser_download_url":"https://github.com/Arti-Ko/steno/releases/download/v1.2.0/Steno.zip","size":1234}]
        """#
        let json = #"""
        {"tag_name":"\#(tag)","body":"Что нового","html_url":"https://github.com/Arti-Ko/steno/releases/tag/\#(tag)",
         "draft":false,"prerelease":\#(prerelease),"assets":\#(assets ?? defaultAssets)}
        """#
        return Data(json.utf8)
    }
}
