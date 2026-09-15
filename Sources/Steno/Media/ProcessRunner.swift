import Foundation

enum ExternalTool: String, Sendable {
    case ffmpeg
    case ffprobe
    case ytDlp = "yt-dlp"

    private static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    var executableURL: URL? {
        Self.searchDirectories
            .map { URL(filePath: $0).appending(path: rawValue) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var installHint: String {
        switch self {
        case .ffmpeg, .ffprobe: "brew install ffmpeg"
        case .ytDlp: "brew install yt-dlp"
        }
    }
}

enum ProcessError: LocalizedError {
    case toolMissing(ExternalTool)
    case failed(ExternalTool, String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let tool):
            "Не найден \(tool.rawValue). Установите его командой «\(tool.installHint)»."
        case .failed(let tool, let message):
            "\(tool.rawValue): \(message.isEmpty ? "неизвестная ошибка" : message)"
        }
    }
}

struct ProcessOutput: Sendable {
    let standardOutput: String
    let standardError: String
}

enum ProcessRunner {
    /// Запускает внешнюю утилиту и построчно отдаёт её вывод (stdout и stderr).
    static func run(
        _ tool: ExternalTool,
        arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        guard let executable = tool.executableURL else { throw ProcessError.toolMissing(tool) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let collector = OutputCollector(onLine: onLine)
        outputPipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, isError: false) }
        errorPipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, isError: true) }

        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(outputPipe.fileHandleForReading.readDataToEndOfFile(), isError: false)
                    collector.append(errorPipe.fileHandleForReading.readDataToEndOfFile(), isError: true)
                    let output = collector.output()

                    // Сигнал от системы (падение утилиты) — это ошибка, а не отмена пользователем.
                    if cancellation.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if finished.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        let message = output.standardError
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .split(separator: "\n")
                            .suffix(3)
                            .joined(separator: " ")
                        continuation.resume(throwing: ProcessError.failed(tool, message))
                    }
                }
                do {
                    try cancellation.launch(process)
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellation.cancel(process)
        }
    }
}

/// Отмена может прийти до запуска процесса — тогда его нельзя стартовать вовсе.
private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func launch(_ process: Process) throws {
        try lock.withLock {
            if cancelled {
                throw CancellationError()
            }
            try process.run()
        }
    }

    func cancel(_ process: Process) {
        lock.withLock {
            cancelled = true
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

/// Собирает вывод процесса из фоновых потоков и режет его на строки.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: (@Sendable (String) -> Void)?
    private var outputData = Data()
    private var errorData = Data()
    private var pendingOutput = Data()
    private var pendingError = Data()

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        var lines: [String] = []

        lock.lock()
        if isError {
            errorData.append(data)
        } else {
            outputData.append(data)
        }
        if onLine != nil {
            var buffer = isError ? pendingError : pendingOutput
            buffer.append(data)
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self)
                if !line.isEmpty {
                    lines.append(line)
                }
                buffer = Data(buffer[(index + 1)...])
            }
            if isError {
                pendingError = buffer
            } else {
                pendingOutput = buffer
            }
        }
        lock.unlock()

        lines.forEach { onLine?($0) }
    }

    func output() -> ProcessOutput {
        lock.lock()
        defer { lock.unlock() }
        return ProcessOutput(
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
