import Foundation
import SQLite3
import Synchronization

/// Offline place names (F3.5.1 / F4.8) from the bundled GeoNames database
/// (cities with population > 15k, built by Tools/build_cities.py). No network:
/// a photo gets the nearest city to its coordinate.
final class CityDatabase: Sendable {
    static let shared = CityDatabase(url: Bundle.main.url(forResource: "cities", withExtension: "sqlite"))

    struct Place: Hashable, Sendable {
        let id: Int
        let name: String
        let nameZH: String?
        let country: String
        let admin: String?
        let adminZH: String?

        /// The app UI is Chinese: Chinese names where GeoNames has them.
        var cityName: String { nameZH ?? name }
        var countryName: String {
            Locale(identifier: "zh-Hans").localizedString(forRegionCode: country) ?? country
        }
    }

    // Read-only and opened in serialized mode, so one connection serves all threads.
    nonisolated(unsafe) private let db: OpaquePointer?
    private let places = Mutex<[Int: Place]>([:])

    init(url: URL?) {
        var handle: OpaquePointer?
        if let url, sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            sqlite3_close(handle)
            handle = nil
        }
        db = handle
    }

    /// The city a photo was taken in: among cities within about one degree, the
    /// one with the highest population / (km + 1)³. Plain nearest-point picks
    /// districts like "Chūō" or "Paris 16 Passy" over 东京 / 巴黎, while the
    /// cubic falloff still keeps a satellite town from being named after the
    /// big city next door (佛山 stays 佛山, not 广州). nil when nothing is close.
    func nearest(latitude: Double, longitude: Double) -> (id: Int, km: Double)? {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, """
            SELECT id, lat, lon, population FROM city WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?;
            """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        // ±1° of latitude is ~111 km; widen longitude so the box stays ~111 km wide.
        let lonSpan = min(180, 1 / max(cos(latitude * .pi / 180), 0.01))
        sqlite3_bind_double(stmt, 1, latitude - 1)
        sqlite3_bind_double(stmt, 2, latitude + 1)
        sqlite3_bind_double(stmt, 3, longitude - lonSpan)
        sqlite3_bind_double(stmt, 4, longitude + lonSpan)
        var best: (id: Int, km: Double, weight: Double)?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let km = Self.distanceKm(latitude, longitude, sqlite3_column_double(stmt, 1), sqlite3_column_double(stmt, 2))
            let weight = Double(max(sqlite3_column_int64(stmt, 3), 1)) / pow(km + 1, 3)
            if weight > best?.weight ?? 0 { best = (Int(sqlite3_column_int64(stmt, 0)), km, weight) }
        }
        return best.map { ($0.id, $0.km) }
    }

    func place(id: Int) -> Place? {
        if let cached = places.withLock({ $0[id] }) { return cached }
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, """
            SELECT c.name, c.name_zh, c.country, a.name, a.name_zh
            FROM city c LEFT JOIN admin1 a ON a.code = c.admin1 WHERE c.id = ?;
            """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(id))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let place = Place(id: id, name: text(stmt, 0) ?? "", nameZH: text(stmt, 1), country: text(stmt, 2) ?? "",
                          admin: text(stmt, 3), adminZH: text(stmt, 4))
        places.withLock { $0[id] = place }
        return place
    }

    /// "杭州 · 浙江 · 中国". 30–100 km away reads "杭州附近"; beyond 100 km, or
    /// with no location, there is no place (F3.5.1).
    func displayName(cityID: Int?, km: Double?) -> String? {
        guard let cityID, let km, km <= 100, let place = place(id: cityID) else { return nil }
        let city = place.cityName
        var parts = [km > 30 ? city + "附近" : city]
        // Skip the province when it only repeats the city (北京 / 北京市, 东京 / 东京都),
        // or when only an English name exists next to a Chinese city name.
        if let admin = place.adminZH ?? (place.nameZH == nil ? place.admin : nil), !admin.isEmpty,
           !admin.hasPrefix(city), !city.hasPrefix(admin) {
            parts.append(admin)
        }
        parts.append(place.countryName)
        return parts.joined(separator: " · ")
    }

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 6371 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }
}
