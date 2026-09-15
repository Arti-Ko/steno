import AVFoundation
import Foundation

enum MediaError: LocalizedError {
    case noAudioTrack
    case emptyAudio
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "В файле нет звуковой дорожки."
        case .emptyAudio: "Не удалось получить звук из файла."
        case .downloadFailed: "Не удалось скачать файл по ссылке."
        }
    }
}

struct MediaInfo: Sendable {
    let duration: Double
    let hasAudio: Bool
    let hasVideo: Bool
}

enum MediaTools {
    static let speechSampleRate = 16_000

    static func probe(_ url: URL) async throws -> MediaInfo {
        let output = try await ProcessRunner.run(.ffprobe, arguments: [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        let report = try JSONDecoder().decode(ProbeReport.self, from: Data(output.standardOutput.utf8))
        let streams = report.streams ?? []
        let duration = Double(report.format?.duration ?? "")
            ?? streams.compactMap { Double($0.duration ?? "") }.max()
            ?? 0
        return MediaInfo(
            duration: duration,
            hasAudio: streams.contains { $0.codecType == "audio" },
            hasVideo: streams.contains { $0.codecType == "video" && $0.disposition?.attachedPic != 1 }
        )
    }

    /// Умеет ли AVFoundation показать это видео в плеере.
    static func isPlayableVideo(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
    }

    /// Звук для плеера: AAC в m4a.
    static func makePlaybackAudio(
        from source: URL,
        to destination: URL,
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await runFFmpeg([
            "-i", source.path, "-map", "0:a:0", "-vn",
            "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", destination.path,
        ], duration: duration, progress: progress)
    }

    /// Звук для распознавания: 16 кГц, моно, float32 без заголовка.
    /// Лёгкая нормализация речи всегда включена: на тихих участках Whisper склонен галлюцинировать.
    static func makeSpeechAudio(
        from source: URL,
        to destination: URL,
        restore: Bool,
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let filters = restore
            ? "highpass=f=80,afftdn=nr=12:nf=-40:tn=1,speechnorm=e=6.25:r=0.00001:l=1"
            : "speechnorm=e=3:r=0.00001:l=1"
        try await runFFmpeg([
            "-i", source.path, "-map", "0:a:0", "-vn", "-af", filters,
            "-ac", "1", "-ar", "\(speechSampleRate)", "-f", "f32le", "-c:a", "pcm_f32le", destination.path,
        ], duration: duration, progress: progress)
    }

    static func loadSamples(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { throw MediaError.emptyAudio }
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return samples
    }

    private static func runFFmpeg(
        _ arguments: [String],
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let common = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-progress", "pipe:1", "-nostats"]
        _ = try await ProcessRunner.run(.ffmpeg, arguments: common + arguments) { line in
            guard duration > 0, line.hasPrefix("out_time_us="),
                  let microseconds = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress(min(1, max(0, microseconds / 1_000_000 / duration)))
        }
    }

    private struct ProbeReport: Decodable {
        struct Stream: Decodable {
            struct Disposition: Decodable {
                let attachedPic: Int?

                enum CodingKeys: String, CodingKey {
                    case attachedPic = "attached_pic"
                }
            }

            let codecType: String?
            let duration: String?
            let disposition: Disposition?

            enum CodingKeys: String, CodingKey {
                case codecType = "codec_type"
                case duration
                case disposition
            }
        }

        struct Format: Decodable {
            let duration: String?
        }

        let streams: [Stream]?
        let format: Format?
    }
}

/// Скачивание звука по ссылке (YouTube, Dropbox, Google Drive, прямые ссылки) через yt-dlp.
enum LinkImporter {
    struct Download: Sendable {
        let fileURL: URL
        let title: String?
    }

    private static let titleMarker = "STENO_TITLE:"
    private static let fileMarker = "STENO_FILE:"
    private static let progressMarker = "STENO_PROGRESS:"

    static func download(
        _ link: URL,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Download {
        let report = LinkReport()
        var arguments = [
            "--no-playlist", "--newline", "--no-part", "--no-colors",
            "-f", "bestaudio/best",
            "-o", directory.appending(path: "source.%(ext)s").path,
            "--no-simulate",
            "--print", "before_dl:\(titleMarker)%(title)s",
            "--print", "after_move:\(fileMarker)%(filepath)s",
            "--progress-template", "download:\(progressMarker)%(progress._percent_str)s",
        ]
        if let ffmpeg = ExternalTool.ffmpeg.executableURL {
            arguments += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        arguments.append(link.absoluteString)

        _ = try await ProcessRunner.run(.ytDlp, arguments: arguments) { line in
            if line.hasPrefix(titleMarker) {
                report.title = String(line.dropFirst(titleMarker.count))
            } else if line.hasPrefix(fileMarker) {
                report.filePath = String(line.dropFirst(fileMarker.count))
            } else if line.hasPrefix(progressMarker) {
                let number = line.dropFirst(progressMarker.count).filter { $0.isNumber || $0 == "." }
                if let percent = Double(number) {
                    progress(min(1, percent / 100))
                }
            }
        }

        if let path = report.filePath, FileManager.default.fileExists(atPath: path) {
            return Download(fileURL: URL(filePath: path), title: report.title)
        }
        let candidates = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let file = candidates.first(where: { $0.lastPathComponent.hasPrefix("source.") }) else {
            throw MediaError.downloadFailed
        }
        return Download(fileURL: file, title: report.title)
    }
}

private final class LinkReport: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTitle: String?
    private var storedPath: String?

    var title: String? {
        get { lock.withLock { storedTitle } }
        set { lock.withLock { storedTitle = newValue } }
    }

    var filePath: String? {
        get { lock.withLock { storedPath } }
        set { lock.withLock { storedPath = newValue } }
    }
}
