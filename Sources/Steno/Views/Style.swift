import SwiftUI

enum SpeakerPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .indigo, .brown, .mint, .red, .cyan, .yellow]

    static func color(for id: Int?) -> Color {
        guard let id else { return .secondary }
        return colors[id % colors.count]
    }
}

enum RussianPlural {
    /// Выбирает форму слова: 1 спикер, 2 спикера, 5 спикеров.
    static func form(_ count: Int, one: String, few: String, many: String) -> String {
        let lastTwo = abs(count) % 100
        let last = lastTwo % 10
        if (11...14).contains(lastTwo) { return many }
        switch last {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    static func speakers(_ count: Int) -> String {
        "\(count) " + form(count, one: "спикер", few: "спикера", many: "спикеров")
    }
}

extension Float {
    var rateLabel: String {
        formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
