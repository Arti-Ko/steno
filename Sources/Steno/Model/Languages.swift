import Foundation

struct SpokenLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String

    var id: String { code }
}

enum Languages {
    /// Языки, которые распознаёт Whisper.
    static let whisperCodes = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv",
        "it", "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
        "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr",
        "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
        "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu",
        "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
        "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue",
    ]

    static let whisper: [SpokenLanguage] = whisperCodes
        .map { SpokenLanguage(code: $0, name: name(for: $0)) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private static let interfaceLocale = Locale(identifier: "ru_RU")

    /// Название языка по-русски с заглавной буквы: «Английский (США)».
    static func name(for code: String) -> String {
        let identifier = code == "jw" ? "jv" : code
        let raw = interfaceLocale.localizedString(forIdentifier: identifier) ?? code
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
