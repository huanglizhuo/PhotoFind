import Foundation

/// Filter bar state (F4.8). Applied before ranking, and on its own for browsing.
struct PhotoFilter: Equatable {
    enum Time: Equatable {
        case all, thisYear, lastYear
        case custom(start: Date, end: Date)
    }

    enum Place: Hashable {
        case city(Int)
        case country(String)
    }

    var time: Time = .all
    var place: Place?
    var favoritesOnly = false
    /// Any of the selected kinds matches (截图 or 自拍 …).
    var kinds: PhotoKinds = []

    var isActive: Bool { time != .all || place != nil || favoritesOnly || !kinds.isEmpty }

    func matches(_ photo: IndexedPhoto, calendar: Calendar = .current, now: Date = .now) -> Bool {
        if favoritesOnly && !photo.meta.isFavorite { return false }
        if !kinds.isEmpty && photo.meta.kinds.isDisjoint(with: kinds) { return false }
        if let range = dateRange(calendar: calendar, now: now) {
            guard let taken = photo.meta.takenAt, range.contains(taken) else { return false }
        }
        if let place {
            // Same 100 km cut-off as the place shown in the detail page (F3.5.1).
            guard let city = photo.meta.cityID, (photo.meta.cityKm ?? .infinity) <= 100 else { return false }
            switch place {
            case .city(let id): if city != id { return false }
            case .country(let code): if CityDatabase.shared.place(id: city)?.country != code { return false }
            }
        }
        return true
    }

    private func dateRange(calendar: Calendar, now: Date) -> Range<Date>? {
        switch time {
        case .all:
            return nil
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now).map { $0.start..<$0.end }
        case .lastYear:
            let lastYear = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .year, for: lastYear).map { $0.start..<$0.end }
        case .custom(let start, let end):
            let from = calendar.startOfDay(for: min(start, end))
            let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(start, end))) ?? end
            return from..<to
        }
    }
}
