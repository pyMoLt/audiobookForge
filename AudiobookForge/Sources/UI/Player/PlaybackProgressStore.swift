import Foundation

/// Remembers the playback position per book (plan 5.2) in UserDefaults and
/// derives the listening progress the library shelf shows ("Weiterhören").
///
/// The key format (`ABFPlayerPosition.<uuid>`) and the first three fields
/// are unchanged from v3.0, so saved positions survive the update.
enum PlaybackProgressStore {
    struct Saved: Codable, Equatable {
        var chapterIndex: Int
        var time: Double
        /// True in packaged mode: `time` is absolute book time; otherwise
        /// it is relative to `chapterIndex`.
        var isAbsolute: Bool
        /// Last time the book was played (v3.1; nil for older entries).
        var lastPlayedAt: Date?
    }

    private static func key(_ bookID: UUID) -> String {
        "ABFPlayerPosition.\(bookID.uuidString)"
    }

    static func save(_ saved: Saved, bookID: UUID, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: key(bookID))
        }
    }

    static func load(bookID: UUID, defaults: UserDefaults = .standard) -> Saved? {
        guard let data = defaults.data(forKey: key(bookID)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    /// Absolute listened seconds for a saved position, given the book's
    /// chapter durations in narration order.
    static func listenedSeconds(_ saved: Saved, chapterDurations: [Double]) -> Double {
        if saved.isAbsolute { return max(0, saved.time) }
        let before = chapterDurations.prefix(max(0, saved.chapterIndex)).reduce(0, +)
        return max(0, before + saved.time)
    }

    /// Progress summary for the shelf; nil when the book was never played.
    struct Summary: Equatable {
        var fraction: Double
        var remainingSeconds: Double
        var totalSeconds: Double
        var lastPlayedAt: Date?
        var chapterIndex: Int
    }

    static func summary(for book: BookProject, defaults: UserDefaults = .standard) -> Summary? {
        guard let saved = load(bookID: book.id, defaults: defaults) else { return nil }
        let durations = book.sortedChapters.map { $0.audioDurationSeconds ?? 0 }
        let total = durations.reduce(0, +)
        guard total > 0 else { return nil }
        let listened = min(total, listenedSeconds(saved, chapterDurations: durations))
        let chapterIndex: Int = {
            guard saved.isAbsolute else { return saved.chapterIndex }
            var acc = 0.0
            for (index, d) in durations.enumerated() {
                acc += d
                if listened < acc { return index }
            }
            return max(0, durations.count - 1)
        }()
        return Summary(
            fraction: listened / total,
            remainingSeconds: max(0, total - listened),
            totalSeconds: total,
            lastPlayedAt: saved.lastPlayedAt,
            chapterIndex: chapterIndex
        )
    }
}

/// Seconds listened per calendar day (key "yyyy-MM-dd", local time).
enum ListeningStats {
    static let key = "listening.daily"

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func add(_ seconds: TimeInterval, at date: Date = Date(), defaults: UserDefaults = .standard) {
        guard seconds > 0, seconds < 24 * 3600 else { return }
        var days = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        days[dayKey(date), default: 0] += seconds
        defaults.set(days, forKey: key)
    }

    static func today(_ date: Date = Date(), defaults: UserDefaults = .standard) -> TimeInterval {
        (defaults.dictionary(forKey: key) as? [String: Double])?[dayKey(date)] ?? 0
    }

    static func thisMonth(_ date: Date = Date(), defaults: UserDefaults = .standard) -> TimeInterval {
        let prefix = String(dayKey(date).prefix(7))
        return (defaults.dictionary(forKey: key) as? [String: Double] ?? [:])
            .filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
    }
}

/// Short human durations: "4 Std. 12 Min.", "12 Min.", "45 s".
enum ListeningTimeFormatter {
    static func long(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return L("0 Min.") }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? String(localized: "\(hours) Std. \(minutes) Min.") : String(localized: "\(hours) Std.") }
        if minutes > 0 { return String(localized: "\(minutes) Min.") }
        return String(localized: "\(total) s")
    }

    /// Clock style for the scrubber: "1:02:03" / "4:05".
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Compact format for headers and badges: "12 Min.", "1 h", "1,5 h", "12 h".
    static func compact(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return L("0 Min.") }
        if seconds < 3600 {
            let minutes = max(1, Int((seconds / 60).rounded()))
            return String(localized: "\(minutes) Min.")
        }
        let hours = seconds / 3600.0
        let rounded = (hours * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded)) h"
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let text = formatter.string(from: NSNumber(value: rounded)) ?? String(format: "%.1f", rounded)
        return "\(text) h"
    }

    /// Clean abbreviations for item counts: "999", "1k", "1,2k", "1M".
    static func abbreviateCount(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        let (divisor, suffix): (Double, String) = count < 1_000_000 ? (1000.0, "k") : (1_000_000.0, "M")
        let val = Double(count) / divisor
        let rounded = (val * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))\(suffix)"
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let text = formatter.string(from: NSNumber(value: rounded)) ?? String(format: "%.1f", rounded)
        return "\(text)\(suffix)"
    }
}
