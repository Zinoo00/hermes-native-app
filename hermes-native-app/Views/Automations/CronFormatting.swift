import Foundation

/// Formatting helpers for cron jobs: ISO timestamps from the backend
/// (Python `datetime.isoformat()`) and human-readable schedule lines
/// ("Every Monday at 9:00 AM") derived from cron expressions.
enum CronFormat {

    // MARK: ISO parsing

    /// Python isoformat() emits "2026-07-02T14:00:00+09:00",
    /// "2026-07-02T14:00:00.123456+09:00" or naive "2026-07-02T14:00:00".
    static func date(fromISO raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        for pattern in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            formatter.timeZone = .current
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// "Mon, Jun 29 · 9:00 AM" (design's next-run format); "—" when unknown.
    static func nextRunText(_ raw: String?) -> String {
        guard let date = date(fromISO: raw) else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d · h:mm a"
        return formatter.string(from: date)
    }

    // MARK: Human schedule line

    /// Natural-language schedule for a job. Prefers a derived phrase for cron
    /// expressions ("Every Monday at 9:00 AM"); falls back to the backend's
    /// schedule_display ("every 30m", "once at …") or the raw expression.
    static func humanSchedule(for job: CronJob) -> String {
        if job.scheduleKind == "cron", let expr = job.scheduleExpression,
           let nice = humanizeCron(expr) {
            return nice
        }
        if let display = job.scheduleDisplay, !display.isEmpty {
            return display
        }
        if let expr = job.scheduleExpression, !expr.isEmpty {
            return humanizeCron(expr) ?? expr
        }
        return "—"
    }

    /// Best-effort English phrasing for the common cron shapes the app writes.
    /// Returns nil for anything it can't phrase confidently.
    static func humanizeCron(_ expr: String) -> String? {
        let fields = expr.split(separator: " ").map(String.init)
        guard fields.count >= 5 else { return nil }
        let (minuteField, hourField, dom, month, dow) =
            (fields[0], fields[1], fields[2], fields[3], fields[4])
        guard dom == "*", month == "*" else { return nil }
        guard let minute = Int(minuteField), (0..<60).contains(minute) else { return nil }

        if hourField == "*" {
            guard dow == "*" else { return nil }
            return minute == 0 ? "Every hour" : String(format: "Every hour at :%02d", minute)
        }
        guard let hour = Int(hourField), (0..<24).contains(hour) else { return nil }
        let time = timeText(hour: hour, minute: minute)

        switch dow {
        case "*":
            return "Every day at \(time)"
        case "1-5":
            return "Weekdays at \(time)"
        case "0,6", "6,0":
            return "Weekends at \(time)"
        default:
            if let day = Int(dow), (0...7).contains(day) {
                let names = ["Sunday", "Monday", "Tuesday", "Wednesday",
                             "Thursday", "Friday", "Saturday", "Sunday"]
                return "Every \(names[day]) at \(time)"
            }
            return nil
        }
    }

    private static func timeText(hour: Int, minute: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let date = Calendar.current.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
