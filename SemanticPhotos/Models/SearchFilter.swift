import Foundation

struct SearchFilter: Equatable, Sendable {
    enum Period: String, CaseIterable, Sendable {
        case all = "不限时间"
        case month = "最近 30 天"
        case year = "今年"
        var title: String {
            switch self {
            case .all: String(localized: "不限时间")
            case .month: String(localized: "最近 30 天")
            case .year: String(localized: "今年")
            }
        }
    }
    var period: Period = .all
    var screenshotsOnly = false
    var favoritesOnly = false
    var isActive: Bool { period != .all || screenshotsOnly || favoritesOnly }

    func lowerBound(now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch period {
        case .all: nil
        case .month: calendar.date(byAdding: .day, value: -30, to: now)
        case .year: calendar.dateInterval(of: .year, for: now)?.start
        }
    }
}
