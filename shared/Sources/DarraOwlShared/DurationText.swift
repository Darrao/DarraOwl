import Foundation

/// Parsing and display of durations, French style ("1 h 30", "45 min").
public enum DurationText {
    /// Reads what a person types for a duration. Accepts a bare number of
    /// minutes ("90"), hours and minutes ("1h30", "1 h 30", "2h", "1:45") and
    /// minutes with a unit ("45m", "45 min"). Returns nil for anything else,
    /// including zero.
    public static func parse(_ text: String) -> TimeInterval? {
        let s = text.lowercased().filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }

        if let minutes = Int(s) {
            return minutes > 0 ? TimeInterval(minutes) * 60 : nil
        }

        if s.contains(":") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h >= 0, (0..<60).contains(m) else {
                return nil
            }
            return total(hours: h, minutes: m)
        }

        for suffix in ["minutes", "minute", "mins", "min", "mn", "m"] where !s.contains("h") && s.hasSuffix(suffix) {
            guard let m = Int(s.dropLast(suffix.count)) else { return nil }
            return m > 0 ? TimeInterval(m) * 60 : nil
        }

        if let hIndex = s.firstIndex(of: "h") {
            guard let h = Int(s[s.startIndex..<hIndex]), h >= 0 else { return nil }
            var rest = s[s.index(after: hIndex)...]
            for suffix in ["min", "mn", "m"] where rest.hasSuffix(suffix) {
                rest = rest.dropLast(suffix.count)
                break
            }
            if rest.isEmpty { return total(hours: h, minutes: 0) }
            guard let m = Int(rest), (0..<60).contains(m) else { return nil }
            return total(hours: h, minutes: m)
        }
        return nil
    }

    /// Days, hours and minutes typed in three fields. An empty field counts
    /// as 0. Returns nil when a field is not a whole number, is negative, or
    /// when the total is zero.
    public static func total(days: String, hours: String, minutes: String) -> TimeInterval? {
        var values: [Int] = []
        for field in [days, hours, minutes] {
            let s = field.trimmingCharacters(in: .whitespaces)
            if s.isEmpty {
                values.append(0)
                continue
            }
            guard s.allSatisfy(\.isASCII), let n = Int(s), n >= 0, n <= 10_000 else { return nil }
            values.append(n)
        }
        let seconds = TimeInterval(values[0] * 86_400 + values[1] * 3600 + values[2] * 60)
        return seconds > 0 ? seconds : nil
    }

    private static func total(hours: Int, minutes: Int) -> TimeInterval? {
        // In floating point: a huge number of hours must not overflow.
        let seconds = TimeInterval(hours) * 3600 + TimeInterval(minutes) * 60
        return seconds > 0 ? seconds : nil
    }

    /// "30 min", "1 h", "1 h 30", "12 h".
    public static func short(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(String(format: "%02d", m))"
        }
    }

    /// Countdown for the menu bar: "1:59:30", "4:05", "0:09".
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))" }
        return "\(m):\(String(format: "%02d", s))"
    }

    /// "16:42" in the 24 h clock of the given time zone.
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
