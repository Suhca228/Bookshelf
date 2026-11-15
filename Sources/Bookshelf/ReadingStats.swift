import Foundation

struct ReadingSessionSummary {
    let bookTitle: String
    let startedAt: Date
    let duration: TimeInterval
    let pagesTurned: Int
}

struct ReadingDay {
    let date: Date
    let seconds: TimeInterval
}

struct ReadingStats {
    let total: TimeInterval
    let today: TimeInterval
    let week: TimeInterval
    let streak: Int
    let days: [ReadingDay]
    let topBooks: [(title: String, seconds: TimeInterval)]
    let recent: [ReadingSessionSummary]

    var hasAny: Bool { total > 0 }
}

enum ReadingStatsBuilder {
    static func build(store: LibraryStore, books: [Book]) -> ReadingStats {
        let total = store.totalReadingDuration()
        let totals = store.dailyReadingTotals()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        var days: [ReadingDay] = []
        for offset in stride(from: 13, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
            let key = dayKey(date)
            days.append(ReadingDay(date: date, seconds: totals[key] ?? 0))
        }

        let weekSeconds = days.suffix(7).reduce(0) { $0 + $1.seconds }
        let todaySeconds = totals[dayKey(startOfToday)] ?? 0

        var streak = 0
        var cursor = startOfToday
        if (totals[dayKey(cursor)] ?? 0) < 60 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                return ReadingStats(total: total, today: todaySeconds, week: weekSeconds,
                                    streak: 0, days: days, topBooks: [], recent: [])
            }
            cursor = yesterday
        }
        while (totals[dayKey(cursor)] ?? 0) >= 60 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        let titles = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.title) })
        let topBooks = store.readingTotalsByBook(limit: 4).map { row in
            (title: titles[row.bookID] ?? "Без назви", seconds: row.seconds)
        }
        let recent = store.recentReadingSessions(limit: 5)

        return ReadingStats(
            total: total,
            today: todaySeconds,
            week: weekSeconds,
            streak: streak,
            days: days,
            topBooks: topBooks,
            recent: recent
        )
    }

    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

func formatReadingDuration(_ seconds: TimeInterval, compact: Bool = false) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 {
        return compact ? "\(hours)г \(minutes)х" : "\(hours) год \(minutes) хв"
    }
    if minutes > 0 {
        return "\(minutes) хв"
    }
    if total > 0 {
        return compact ? "\(total)с" : "\(total) с"
    }
    return compact ? "0х" : "0 хв"
}
