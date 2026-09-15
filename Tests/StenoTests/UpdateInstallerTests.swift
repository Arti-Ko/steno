import Foundation
import Testing
@testable import Steno

@Suite("Подмена приложения при обновлении")
struct UpdateInstallerTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "steno-swap-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test("Новая версия заменяет старую, временные файлы убираются")
    func replacesBundle() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Applications/Steno.app", directoryHint: .isDirectory)
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        let staged = staging.appending(path: "Steno.app", directoryHint: .isDirectory)
        try makeBundle(at: target, marker: "old")
        try makeBundle(at: staged, marker: "new")

        #expect(try runSwap(target: target, staged: staged, staging: staging) == 0)

        #expect(try marker(in: target) == "new")
        #expect(!FileManager.default.fileExists(atPath: target.path + ".previous"))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("Если копирование не удалось, старая версия возвращается на место")
    func restoresOldBundleOnFailure() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Applications/Steno.app", directoryHint: .isDirectory)
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        let missing = staging.appending(path: "Steno.app", directoryHint: .isDirectory)
        try makeBundle(at: target, marker: "old")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        _ = try runSwap(target: target, staged: missing, staging: staging)

        #expect(try marker(in: target) == "old")
        #expect(!FileManager.default.fileExists(atPath: target.path + ".previous"))
    }

    /// Сеть и опубликованный выпуск: STENO_UPDATE_E2E=1 swift test --filter UpdateInstallerTests
    @Test("Опубликованный выпуск скачивается и проходит проверку",
          .enabled(if: ProcessInfo.processInfo.environment["STENO_UPDATE_E2E"] != nil))
    func downloadsPublishedRelease() async throws {
        let release = try #require(try await ReleaseFeed.latest())
        let app = try await UpdateInstaller.download(release, expectedBundleID: "org.sleepycoffee.steno") { _ in }
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(FileManager.default.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/Steno").path))
        print("выпуск \(release.version), архив \(release.archiveSize) байт")
    }

    // MARK: Помощники

    private func makeBundle(at url: URL, marker: String) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: contents.appending(path: "marker"))
    }

    private func marker(in bundle: URL) throws -> String {
        try String(contentsOf: bundle.appending(path: "Contents/marker"), encoding: .utf8)
    }

    private func runSwap(target: URL, staged: URL, staging: URL) throws -> Int32 {
        let script = root.appending(path: "install.sh")
        try UpdateInstaller.swapScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // PID вне допустимого диапазона macOS: скрипту не нужно ждать выхода приложения.
        process.arguments = [script.path, "999999", target.path, staged.path, staging.path, "--no-launch"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
