import Foundation

enum TimeFormat {
    /// «02:03» или «1:02:03» — для интерфейса и текстовых экспортов.
    static func clock(_ seconds: Double, forceHours: Bool = false) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 || forceHours {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    /// «00:01:02,345» — отметка времени SRT.
    static func srt(_ seconds: Double) -> String {
        stamp(seconds, separator: ",")
    }

    /// «00:01:02.345» — отметка времени WebVTT.
    static func vtt(_ seconds: Double) -> String {
        stamp(seconds, separator: ".")
    }

    /// «1 ч 5 мин», «12 мин 30 с».
    static func spoken(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        return formatter.string(from: max(0, seconds)) ?? clock(seconds)
    }

    private static func stamp(_ seconds: Double, separator: String) -> String {
        let milliseconds = max(0, Int((seconds.isFinite ? seconds : 0) * 1000 + 0.5))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let wholeSeconds = (milliseconds % 60_000) / 1000
        let fraction = milliseconds % 1000
        return String(format: "%02d:%02d:%02d", hours, minutes, wholeSeconds)
            + separator
            + String(format: "%03d", fraction)
    }
}
