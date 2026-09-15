import AppKit
import Foundation

struct ReleaseInfo: Equatable, Identifiable, Sendable {
    let version: AppVersion
    let notes: String
    let pageURL: URL
    let archiveURL: URL
    let archiveSize: Int

    var id: String { version.description }
}

enum UpdateError: LocalizedError {
    case badResponse(Int)
    case rateLimited
    case missingArchive
    case invalidArchive
    case notInstalledAsApp
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status): "GitHub ответил с ошибкой \(status)."
        case .rateLimited: "GitHub временно ограничил запросы. Попробуйте позже."
        case .missingArchive: "В выпуске нет архива приложения."
        case .invalidArchive: "Скачанный архив не похож на Steno."
        case .notInstalledAsApp: "Обновление работает только для собранного Steno.app."
        case .notWritable(let path): "Нет прав на запись в \(path). Скачайте установщик со страницы выпуска."
        }
    }
}

/// Выпуски на GitHub Releases.
enum ReleaseFeed {
    static let repository = "Arti-Ko/steno"
    static let archiveName = "Steno.zip"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    private static let latestEndpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// Последний опубликованный выпуск; nil — выпусков ещё нет.
    static func latest() async throws -> ReleaseInfo? {
        var request = URLRequest(url: latestEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Без User-Agent GitHub API отвечает 403.
        request.setValue("Steno/\(AppVersion.current?.description ?? "dev")", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try parse(data)
        case 404: return nil
        case 403, 429: throw UpdateError.rateLimited
        default: throw UpdateError.badResponse(status)
        }
    }

    static func parse(_ data: Data) throws -> ReleaseInfo? {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease,
              let version = AppVersion(release.tagName),
              let pageURL = URL(string: release.htmlURL) else { return nil }
        guard let asset = release.assets.first(where: { $0.name == archiveName }),
              let archiveURL = URL(string: asset.downloadURL) else {
            throw UpdateError.missingArchive
        }
        return ReleaseInfo(
            version: version,
            notes: release.body ?? "",
            pageURL: pageURL,
            archiveURL: archiveURL,
            archiveSize: asset.size
        )
    }

    /// Текст для окна обновления: инструкция по установке нужна на странице выпуска, но не здесь;
    /// заголовки Markdown становятся жирными — окно показывает только строчную разметку.
    static func displayNotes(_ markdown: String) -> String {
        var lines: [String] = []
        var isSkipping = false
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                isSkipping = title.localizedCaseInsensitiveContains("установка")
                if !isSkipping {
                    lines.append("**\(title)**")
                }
                continue
            }
            if !isSkipping {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: String
            let size: Int

            enum CodingKeys: String, CodingKey {
                case name
                case size
                case downloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let body: String?
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case body, draft, prerelease, assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}

/// Скачивание выпуска и подмена бандла.
enum UpdateInstaller {
    /// Скачивает и распаковывает выпуск; возвращает путь к проверенному Steno.app.
    static func download(
        _ release: ReleaseInfo,
        expectedBundleID: String? = Bundle.main.bundleIdentifier,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "steno-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let archive = staging.appending(path: ReleaseFeed.archiveName)

        try await FileDownloader.download(release.archiveURL, to: archive, expectedSize: release.archiveSize, progress: progress)
        try await runTool("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])

        let app = staging.appending(path: "Steno.app", directoryHint: .isDirectory)
        let version = Bundle(url: app)
            .flatMap { $0.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            .flatMap(AppVersion.init)
        guard expectedBundleID != nil, Bundle(url: app)?.bundleIdentifier == expectedBundleID, version == release.version else {
            throw UpdateError.invalidArchive
        }
        return app
    }

    /// Можно ли заменить запущенное приложение: это .app и в его папку разрешена запись.
    static var canReplaceRunningApp: Bool {
        let target = Bundle.main.bundleURL
        return target.pathExtension == "app"
            && FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
    }

    /// Запускает скрипт, который дождётся выхода приложения и заменит бандл.
    /// relaunch — выйти сразу и открыть новую версию; иначе замена произойдёт, когда приложение закроют.
    @MainActor
    static func install(_ stagedApp: URL, relaunch: Bool) throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { throw UpdateError.notInstalledAsApp }
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }
        guard FileManager.default.fileExists(atPath: stagedApp.path) else { throw UpdateError.invalidArchive }

        let staging = stagedApp.deletingLastPathComponent()
        let script = staging.appending(path: "install.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            script.path,
            "\(ProcessInfo.processInfo.processIdentifier)",
            target.path,
            stagedApp.path,
            staging.path,
        ] + (relaunch ? [] : ["--no-launch"])
        try process.run()
        if relaunch {
            NSApp.terminate(nil)
        }
    }

    /// Старый бандл сначала отодвигается в сторону: если копирование не удалось, он возвращается на место.
    /// Пятый аргумент `--no-launch` нужен тестам, чтобы не открывать приложение.
    static let swapScript = """
    #!/bin/sh
    pid="$1"; target="$2"; staged="$3"; staging="$4"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    backup="$target.previous"
    rm -rf "$backup"
    mv "$target" "$backup" || exit 1
    if /usr/bin/ditto "$staged" "$target"; then
        rm -rf "$backup"
    else
        rm -rf "$target"
        mv "$backup" "$target"
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
    [ "$5" = "--no-launch" ] || /usr/bin/open "$target"
    rm -rf "$staging"
    """

    private static func runTool(_ path: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw UpdateError.invalidArchive }
        }.value
    }
}

/// Загрузка файла с прогрессом через делегат URLSession.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, expectedSize: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    static func download(
        _ url: URL,
        to destination: URL,
        expectedSize: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let downloader = FileDownloader(destination: destination, expectedSize: expectedSize, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                downloader.lock.withLock { downloader.continuation = continuation }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedSize)
        guard total > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Временный файл удаляется сразу после возврата из метода — переносим его синхронно.
        do {
            if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
                throw UpdateError.badResponse(response.statusCode)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { failure = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let pending = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            defer { continuation = nil }
            return (continuation, error ?? failure)
        }
        guard let continuation = pending.0 else { return }
        if let error = pending.1 {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
