import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt, docx, pdf, srt, vtt, csv, md, json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .txt: "Текст (TXT)"
        case .docx: "Word (DOCX)"
        case .pdf: "PDF"
        case .srt: "Субтитры (SRT)"
        case .vtt: "Субтитры (VTT)"
        case .csv: "Таблица (CSV)"
        case .md: "Markdown"
        case .json: "JSON"
        }
    }

    var fileExtension: String { rawValue }

    var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .data
    }

    var isSubtitle: Bool { self == .srt || self == .vtt }

    /// Результат можно положить в буфер обмена как текст.
    var isPlainText: Bool { self != .docx && self != .pdf }
}

struct ExportOptions: Equatable, Sendable {
    var includeTimestamps = true
    var includeSpeakers = true
    var mergeSpeakerTurns = true
    /// Язык перевода; nil — оригинал.
    var language: String?
    var maxCharactersPerLine = 42
    var maxLines = 2
    var maxCueDuration = 6.0
}

enum ExportError: LocalizedError {
    case emptyTranscript
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: "В расшифровке пока нет текста."
        case .renderFailed: "Не удалось сформировать документ."
        }
    }
}

struct ExportParagraph: Equatable, Sendable {
    let start: Double
    let end: Double
    let speaker: String?
    let text: String
}

@MainActor
enum Exporter {
    static func fileName(for transcript: Transcript, format: ExportFormat, options: ExportOptions) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let base = transcript.title.components(separatedBy: unsafe).joined(separator: "-")
        let suffix = options.language.map { " — \(Languages.name(for: $0))" } ?? ""
        return "\(base)\(suffix).\(format.fileExtension)"
    }

    static func data(for transcript: Transcript, format: ExportFormat, options: ExportOptions) throws -> Data {
        guard transcript.segments.contains(where: { !$0.text.isEmpty }) else { throw ExportError.emptyTranscript }
        switch format {
        case .docx:
            return try docx(transcript, options: options)
        case .pdf:
            return try pdf(transcript, options: options)
        case .json:
            return try json(transcript, options: options)
        case .csv:
            // BOM нужен, чтобы Excel открыл кириллицу без кракозябр.
            return Data(("\u{FEFF}" + csv(transcript, options: options)).utf8)
        case .txt, .srt, .vtt, .md:
            return Data((text(for: transcript, format: format, options: options) ?? "").utf8)
        }
    }

    static func text(for transcript: Transcript, format: ExportFormat, options: ExportOptions) -> String? {
        switch format {
        case .txt: plainText(transcript, options: options)
        case .md: markdown(transcript, options: options)
        case .csv: csv(transcript, options: options)
        case .srt: srt(transcript, options: options)
        case .vtt: vtt(transcript, options: options)
        case .json: (try? json(transcript, options: options)).map { String(decoding: $0, as: UTF8.self) }
        case .docx, .pdf: nil
        }
    }

    // MARK: Абзацы

    static func paragraphs(_ transcript: Transcript, options: ExportOptions, merge: Bool? = nil) -> [ExportParagraph] {
        let shouldMerge = merge ?? options.mergeSpeakerTurns
        var result: [ExportParagraph] = []
        for segment in transcript.segments {
            let text = transcript.text(of: segment, language: options.language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = options.includeSpeakers ? transcript.speakerName(for: segment.speaker) : nil
            if shouldMerge, let last = result.last, speaker != nil, last.speaker == speaker {
                result[result.count - 1] = ExportParagraph(
                    start: last.start, end: segment.end, speaker: speaker, text: last.text + " " + text
                )
            } else {
                result.append(ExportParagraph(start: segment.start, end: segment.end, speaker: speaker, text: text))
            }
        }
        return result
    }

    static func header(for paragraph: ExportParagraph, options: ExportOptions, longClock: Bool) -> String? {
        var parts: [String] = []
        if options.includeTimestamps {
            parts.append("[\(TimeFormat.clock(paragraph.start, forceHours: longClock))]")
        }
        if let speaker = paragraph.speaker {
            parts.append(speaker)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Текстовые форматы

    static func plainText(_ transcript: Transcript, options: ExportOptions) -> String {
        let longClock = transcript.duration >= 3600
        return paragraphs(transcript, options: options)
            .map { paragraph in
                [header(for: paragraph, options: options, longClock: longClock), paragraph.text]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
            .joined(separator: "\n\n") + "\n"
    }

    static func markdown(_ transcript: Transcript, options: ExportOptions) -> String {
        let longClock = transcript.duration >= 3600
        let body = paragraphs(transcript, options: options).map { paragraph in
            var lines: [String] = []
            let clock = options.includeTimestamps ? "`\(TimeFormat.clock(paragraph.start, forceHours: longClock))`" : nil
            let speaker = paragraph.speaker.map { "**\($0)**" }
            let heading = [speaker, clock].compactMap { $0 }.joined(separator: " · ")
            if !heading.isEmpty {
                lines.append(heading)
            }
            lines.append(paragraph.text)
            return lines.joined(separator: "  \n")
        }
        return (["# \(transcript.title)"] + body).joined(separator: "\n\n") + "\n"
    }

    static func csv(_ transcript: Transcript, options: ExportOptions) -> String {
        var rows = ["Начало,Конец,Спикер,Текст"]
        for paragraph in paragraphs(transcript, options: options, merge: false) {
            let fields = [TimeFormat.vtt(paragraph.start), TimeFormat.vtt(paragraph.end), paragraph.speaker ?? "", paragraph.text]
            rows.append(fields.map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    static func srt(_ transcript: Transcript, options: ExportOptions) -> String {
        var previousSpeaker: String?
        return cues(transcript, options: options)
            .enumerated()
            .map { index, cue in
                var lines = cue.lines
                if let speaker = cue.speaker, speaker != previousSpeaker, !lines.isEmpty {
                    lines[0] = "\(speaker): \(lines[0])"
                }
                previousSpeaker = cue.speaker
                return "\(index + 1)\n\(TimeFormat.srt(cue.start)) --> \(TimeFormat.srt(cue.end))\n"
                    + lines.joined(separator: "\n")
            }
            .joined(separator: "\n\n") + "\n"
    }

    static func vtt(_ transcript: Transcript, options: ExportOptions) -> String {
        let body = cues(transcript, options: options).map { cue in
            let text = cue.lines.joined(separator: "\n")
            let voiced = cue.speaker.map { "<v \($0)>\(text)" } ?? text
            return "\(TimeFormat.vtt(cue.start)) --> \(TimeFormat.vtt(cue.end))\n\(voiced)"
        }
        return "WEBVTT\n\n" + body.joined(separator: "\n\n") + "\n"
    }

    private static func cues(_ transcript: Transcript, options: ExportOptions) -> [SubtitleCue] {
        let items = transcript.segments.compactMap { segment -> TimedText? in
            let text = transcript.text(of: segment, language: options.language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedText(
                start: segment.start,
                end: segment.end,
                text: text,
                speaker: options.includeSpeakers ? transcript.speakerName(for: segment.speaker) : nil,
                words: options.language == nil ? segment.words : []
            )
        }
        return SubtitleBuilder.cues(
            from: items,
            maxCharactersPerLine: options.maxCharactersPerLine,
            maxLines: options.maxLines,
            maxDuration: options.maxCueDuration
        )
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: JSON

    private struct JSONDocument: Encodable {
        struct Item: Encodable {
            let start: Double
            let end: Double
            let speaker: String?
            let text: String
        }

        let title: String
        let language: String?
        let duration: Double
        let segments: [Item]
    }

    private static func json(_ transcript: Transcript, options: ExportOptions) throws -> Data {
        let rounded = { (value: Double) in (value * 1000).rounded() / 1000 }
        let document = JSONDocument(
            title: transcript.title,
            language: options.language ?? transcript.language,
            duration: rounded(transcript.duration),
            segments: paragraphs(transcript, options: options, merge: false).map {
                .init(start: rounded($0.start), end: rounded($0.end), speaker: $0.speaker, text: $0.text)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    // MARK: DOCX и PDF

    private static func docx(_ transcript: Transcript, options: ExportOptions) throws -> Data {
        // Arial есть и в Word на Windows, и на Mac — системный шрифт в DOCX превратился бы в неизвестное имя.
        let document = attributedDocument(transcript, options: options, fontName: "Arial")
        do {
            return try document.data(
                from: NSRange(location: 0, length: document.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
        } catch {
            throw ExportError.renderFailed
        }
    }

    private static func pdf(_ transcript: Transcript, options: ExportOptions) throws -> Data {
        let document = attributedDocument(transcript, options: options, fontName: nil)
        let pageSize = NSSize(width: 595, height: 842)
        let margin: CGFloat = 56
        let width = pageSize.width - margin * 2

        let storage = NSTextStorage(attributedString: document)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height) + 1
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height), textContainer: container)
        textView.drawsBackground = false

        let fileURL = FileManager.default.temporaryDirectory.appending(path: "steno-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let printInfo = NSPrintInfo()
        printInfo.paperSize = pageSize
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary().setObject(fileURL, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), let data = try? Data(contentsOf: fileURL) else {
            throw ExportError.renderFailed
        }
        return data
    }

    private static func attributedDocument(
        _ transcript: Transcript,
        options: ExportOptions,
        fontName: String?
    ) -> NSAttributedString {
        func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
            if let fontName, let base = NSFont(name: fontName, size: size) {
                return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
            }
            return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        }

        func style(before: CGFloat = 0, after: CGFloat = 0, lineHeight: CGFloat = 1) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.lineHeightMultiple = lineHeight
            return style
        }

        let document = NSMutableAttributedString()
        document.append(NSAttributedString(string: transcript.title + "\n", attributes: [
            .font: font(20, bold: true), .foregroundColor: NSColor.black, .paragraphStyle: style(after: 4),
        ]))
        document.append(NSAttributedString(string: metadataLine(transcript, options: options) + "\n", attributes: [
            .font: font(10), .foregroundColor: NSColor.gray, .paragraphStyle: style(after: 14),
        ]))

        let longClock = transcript.duration >= 3600
        for paragraph in paragraphs(transcript, options: options) {
            if let header = header(for: paragraph, options: options, longClock: longClock) {
                document.append(NSAttributedString(string: header + "\n", attributes: [
                    .font: font(10, bold: true), .foregroundColor: NSColor.darkGray, .paragraphStyle: style(before: 8, after: 2),
                ]))
            }
            document.append(NSAttributedString(string: paragraph.text + "\n", attributes: [
                .font: font(12), .foregroundColor: NSColor.black, .paragraphStyle: style(after: 6, lineHeight: 1.15),
            ]))
        }
        return document
    }

    private static func metadataLine(_ transcript: Transcript, options: ExportOptions) -> String {
        [
            TimeFormat.spoken(transcript.duration),
            transcript.language.map(Languages.name(for:)),
            options.language.map { "перевод: \(Languages.name(for: $0))" },
            transcript.createdAt.formatted(date: .long, time: .shortened),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}
