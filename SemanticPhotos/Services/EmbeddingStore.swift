import Foundation
import SQLite3

/// SQLite-backed index: one row per imported photo (vector, cached library
/// metadata, recognized text) plus the persistent work queue (F2.3). Every
/// write is committed immediately so an interrupted run resumes where it stopped.
actor EmbeddingStore {
    struct IndexConfig: Equatable {
        let modelVersion: String
        let dimension: Int
    }

    struct MetaRow: Sendable {
        let id: String
        let modificationDate: Date?
        let importedAt: Date
        let meta: PhotoMeta
    }

    struct SearchRow: Sendable {
        let id: String
        let vector: [Float]
        /// Recognized text (F4.12); nil until the second pass has run.
        let text: String?
        let normalizedText: String?

        init(id: String, vector: [Float], text: String?, normalizedText: String? = nil) {
            self.id = id
            self.vector = vector
            self.text = text
            self.normalizedText = normalizedText ?? text?.lowercased()
        }
    }

    /// Stages of the persistent queue: text recognition runs after embedding.
    enum Stage: Int32, Sendable {
        case embed = 0
        case recognizeText = 1
    }

    // nonisolated(unsafe) so the pointer can be closed from `deinit`;
    // only this actor's serial executor ever touches it otherwise.
    nonisolated(unsafe) private var db: OpaquePointer?
    private var openError: String?
    // Only OCR text is cached; vectors are still released after each search.
    private var normalizedTextCache: [String: String] = [:]

    /// Convert database rows on the store actor before publishing the library on the main actor.
    func indexedLibrary() throws -> IndexedLibrary {
        try IndexedLibrary(metaRows().map { IndexedPhoto(id: $0.id, modificationDate: $0.modificationDate,
                                         importedAt: $0.importedAt, meta: $0.meta) })
    }

    func clearSearchTextCache() {
        normalizedTextCache.removeAll()
    }

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("index.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            openError = String(localized: "无法打开索引数据库")
            return
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS embeddings(
            asset_id TEXT PRIMARY KEY,
            embedding BLOB NOT NULL,
            dim INTEGER NOT NULL,
            model_version TEXT NOT NULL,
            asset_mod_date REAL,
            created_at REAL NOT NULL,
            perceptual_hash INTEGER
        );
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value TEXT
        );
        CREATE TABLE IF NOT EXISTS pending(
            asset_id TEXT NOT NULL,
            stage INTEGER NOT NULL,
            enqueued_at REAL NOT NULL,
            PRIMARY KEY(asset_id, stage)
        );
        CREATE INDEX IF NOT EXISTS idx_embeddings_created ON embeddings(created_at DESC);
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            openError = Self.errorMessage(for: db)
        }
        Self.addMissingColumns(db)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// v0.5 columns. ALTER keeps existing rows and vectors, so upgrading never
    /// re-embeds; the metadata is backfilled by the cold-start sweep.
    // T1: the world_* (constellation) columns are gone from this list; databases
    // upgraded before v0.7 keep the stale columns but they are never read again.
    private static let addedColumns = [
        ("taken_at", "REAL"), ("favorite", "INTEGER NOT NULL DEFAULT 0"), ("kinds", "INTEGER NOT NULL DEFAULT 0"),
        ("lat", "REAL"), ("lon", "REAL"), ("city_id", "INTEGER"), ("city_km", "REAL"), ("ocr_text", "TEXT"),
        // v0.8: 64-bit dHash for "find the original" (stored as a signed
        // INTEGER; converted back with bitPattern).
        ("perceptual_hash", "INTEGER"),
        ("color_hue", "REAL"), ("color_saturation", "REAL"), ("color_brightness", "REAL"),
    ]

    private static func addMissingColumns(_ db: OpaquePointer?) {
        var existing = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(embeddings);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                existing.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
        }
        sqlite3_finalize(stmt)
        for (name, type) in addedColumns where !existing.contains(name) {
            sqlite3_exec(db, "ALTER TABLE embeddings ADD COLUMN \(name) \(type);", nil, nil, nil)
        }
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_embeddings_taken ON embeddings(taken_at DESC);", nil, nil, nil)
    }

    // MARK: - Writes

    /// Upsert after (re-)embedding. Keeps the original import time and clears
    /// recognized text, since an edit may have changed the pixels.
    func insert(id: String, vector: [Float], modelVersion: String, modificationDate: Date?,
                meta: PhotoMeta, perceptualHash: UInt64? = nil) throws {
        normalizedTextCache.removeValue(forKey: id)
        let sql = """
        INSERT INTO embeddings(asset_id, embedding, dim, model_version, asset_mod_date, created_at,
                               taken_at, favorite, kinds, lat, lon, city_id, city_km, perceptual_hash, ocr_text)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        ON CONFLICT(asset_id) DO UPDATE SET
            embedding = excluded.embedding, dim = excluded.dim, model_version = excluded.model_version,
            asset_mod_date = excluded.asset_mod_date, taken_at = excluded.taken_at,
            favorite = excluded.favorite, kinds = excluded.kinds, lat = excluded.lat, lon = excluded.lon,
            city_id = excluded.city_id, city_km = excluded.city_km,
            perceptual_hash = excluded.perceptual_hash, ocr_text = NULL,
            color_hue = NULL, color_saturation = NULL, color_brightness = NULL;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(id, at: 1, in: stmt)
        var vector = vector
        _ = vector.withUnsafeMutableBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(ptr.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(stmt, 3, Int32(vector.count))
        bindText(modelVersion, at: 4, in: stmt)
        bind(modificationDate?.timeIntervalSince1970, at: 5, in: stmt)
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        bindMeta(meta, from: 7, in: stmt)
        if let perceptualHash {
            sqlite3_bind_int64(stmt, 14, Int64(bitPattern: perceptualHash))
        } else {
            sqlite3_bind_null(stmt, 14)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
    }

    func updateMeta(_ items: [(id: String, meta: PhotoMeta)]) throws {
        guard !items.isEmpty else { return }
        let stmt = try prepare("""
        UPDATE embeddings SET taken_at = ?, favorite = ?, kinds = ?, lat = ?, lon = ?, city_id = ?, city_km = ?
        WHERE asset_id = ?;
        """)
        defer { sqlite3_finalize(stmt) }
        try transaction {
            for item in items {
                sqlite3_reset(stmt)
                bindMeta(item.meta, from: 1, in: stmt)
                bindText(item.id, at: 8, in: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
            }
        }
    }

    /// Stores recognized text; an empty string marks "processed, no text".
    func setText(_ text: String, for id: String) throws {
        normalizedTextCache.removeValue(forKey: id)
        let stmt = try prepare("UPDATE embeddings SET ocr_text = ? WHERE asset_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(text, at: 1, in: stmt)
        bindText(id, at: 2, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
    }

    func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        for id in ids { normalizedTextCache.removeValue(forKey: id) }
        let rows = try prepare("DELETE FROM embeddings WHERE asset_id = ?;")
        defer { sqlite3_finalize(rows) }
        let queued = try prepare("DELETE FROM pending WHERE asset_id = ?;")
        defer { sqlite3_finalize(queued) }
        try transaction {
            for id in ids {
                for stmt in [rows, queued] {
                    sqlite3_reset(stmt)
                    bindText(id, at: 1, in: stmt)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
                }
            }
        }
    }

    func clearAll() throws {
        clearSearchTextCache()
        guard sqlite3_exec(db, "DELETE FROM embeddings; DELETE FROM pending;", nil, nil, nil) == SQLITE_OK else {
            throw storeError()
        }
    }

    // MARK: - Work queue (F2.3)

    func colorRows() throws -> [ColoredPhoto] {
        let stmt = try prepare("SELECT asset_id, asset_mod_date, color_hue, color_saturation, color_brightness FROM embeddings WHERE color_hue IS NOT NULL AND color_saturation IS NOT NULL AND color_brightness IS NOT NULL;")
        defer { sqlite3_finalize(stmt) }
        var rows: [ColoredPhoto] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            let color = PhotoColor(hue: sqlite3_column_double(stmt, 2), saturation: sqlite3_column_double(stmt, 3),
                                   brightness: sqlite3_column_double(stmt, 4))
            if color.isValid {
                rows.append(ColoredPhoto(id: String(cString: sqlite3_column_text(stmt, 0)),
                    modified: double(stmt, 1).map(Date.init(timeIntervalSince1970:)), color: color))
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw storeError() }
        return rows
    }

    /// A concurrent edit/re-index must never receive a color from the old photo version.
    @discardableResult
    func setColor(_ color: PhotoColor, for id: String, modificationDate: Date?) throws -> Bool {
        guard color.isValid else { return false }
        let stmt = try prepare("UPDATE embeddings SET color_hue = ?, color_saturation = ?, color_brightness = ? WHERE asset_id = ? AND asset_mod_date IS ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, color.hue)
        sqlite3_bind_double(stmt, 2, color.saturation)
        sqlite3_bind_double(stmt, 3, color.brightness)
        bindText(id, at: 4, in: stmt)
        bind(modificationDate?.timeIntervalSince1970, at: 5, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
        return sqlite3_changes(db) == 1
    }

    /// Appends in order; ids already queued for the stage keep their place.
    func addPending(_ ids: [String], stage: Stage) throws {
        guard !ids.isEmpty else { return }
        let stmt = try prepare("INSERT OR IGNORE INTO pending(asset_id, stage, enqueued_at) VALUES(?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        let now = Date().timeIntervalSince1970
        try transaction {
            for (offset, id) in ids.enumerated() {
                sqlite3_reset(stmt)
                bindText(id, at: 1, in: stmt)
                sqlite3_bind_int(stmt, 2, stage.rawValue)
                sqlite3_bind_double(stmt, 3, now + Double(offset) * 1e-6)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
            }
        }
    }

    func removePending(_ id: String, stage: Stage) throws {
        let stmt = try prepare("DELETE FROM pending WHERE asset_id = ? AND stage = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(id, at: 1, in: stmt)
        sqlite3_bind_int(stmt, 2, stage.rawValue)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
    }

    func clearPending(stage: Stage? = nil) throws {
        let sql = stage.map { "DELETE FROM pending WHERE stage = \($0.rawValue);" } ?? "DELETE FROM pending;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw storeError() }
    }

    func pending(stage: Stage) throws -> [String] {
        let stmt = try prepare("SELECT asset_id FROM pending WHERE stage = ? ORDER BY enqueued_at, rowid;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, stage.rawValue)
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return ids
    }

    // MARK: - Reads

    func metaRows() throws -> [MetaRow] {
        let stmt = try prepare("""
        SELECT asset_id, asset_mod_date, created_at, taken_at, favorite, kinds, lat, lon, city_id, city_km
        FROM embeddings ORDER BY COALESCE(taken_at, created_at) DESC;
        """)
        defer { sqlite3_finalize(stmt) }
        var rows: [MetaRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let meta = PhotoMeta(
                takenAt: double(stmt, 3).map(Date.init(timeIntervalSince1970:)),
                isFavorite: sqlite3_column_int(stmt, 4) != 0,
                kinds: PhotoKinds(rawValue: Int(sqlite3_column_int(stmt, 5))),
                latitude: double(stmt, 6),
                longitude: double(stmt, 7),
                cityID: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 8)),
                cityKm: double(stmt, 9))
            rows.append(MetaRow(id: String(cString: sqlite3_column_text(stmt, 0)),
                                modificationDate: double(stmt, 1).map(Date.init(timeIntervalSince1970:)),
                                importedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                                meta: meta))
        }
        return rows
    }

    func searchRows(includeText: Bool = true, filter: SearchFilter = SearchFilter()) throws -> [SearchRow] {
        try Task.checkCancellation()
        var conditions: [String] = []
        if filter.screenshotsOnly { conditions.append("(kinds & 1) != 0") }
        if filter.favoritesOnly { conditions.append("favorite = 1") }
        let start = filter.lowerBound()
        if start != nil { conditions.append("COALESCE(taken_at, created_at) >= ?") }
        let predicate = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let stmt = try prepare("SELECT asset_id, embedding, \(includeText ? "ocr_text" : "NULL") FROM embeddings\(predicate);")
        if let start { sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970) }
        defer { sqlite3_finalize(stmt) }
        var rows: [SearchRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if rows.count.isMultiple(of: 256) { try Task.checkCancellation() }
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let text = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 2))
            let normalized = text.map { text in
                guard !text.isEmpty else { return text }
                if let cached = normalizedTextCache[id] { return cached }
                let normalized = text.lowercased()
                normalizedTextCache[id] = normalized
                return normalized
            }
            rows.append(SearchRow(id: id, vector: vector(stmt, 1), text: text, normalizedText: normalized))
        }
        return rows
    }

    func vector(for id: String) throws -> [Float]? {
        let stmt = try prepare("SELECT embedding FROM embeddings WHERE asset_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(id, at: 1, in: stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? vector(stmt, 0) : nil
    }

    /// Photos the text pass hasn't covered yet, newest first. `screenshotsOnly`
    /// is the v0.8 / G2 default: `kinds` bit 0 is `PhotoKinds.screenshot`.
    func idsMissingText(screenshotsOnly: Bool) throws -> [String] {
        let stmt = try prepare("""
        SELECT asset_id FROM embeddings
        WHERE ocr_text IS NULL \(screenshotsOnly ? "AND (kinds & 1) = 1" : "")
        ORDER BY COALESCE(taken_at, created_at) DESC;
        """)
        defer { sqlite3_finalize(stmt) }
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return ids
    }

    // MARK: - Perceptual hash (v0.8)

    struct HashCandidate: Sendable, Equatable {
        let id: String
        let distance: Int
    }

    /// Near-duplicates of a shared image, closest first. A linear scan is fine:
    /// 100k rows of 64-bit hashes is a few milliseconds and only happens for
    /// "find the original", not for every text search.
    func nearDuplicateIDs(hash: UInt64, maxDistance: Int) throws -> [HashCandidate] {
        let stmt = try prepare("SELECT asset_id, perceptual_hash FROM embeddings WHERE perceptual_hash IS NOT NULL;")
        defer { sqlite3_finalize(stmt) }
        var candidates: [HashCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let stored = UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
            let distance = PerceptualHash.distance(stored, hash)
            guard distance <= maxDistance else { continue }
            candidates.append(HashCandidate(id: String(cString: sqlite3_column_text(stmt, 0)),
                                            distance: distance))
        }
        return Array(candidates.sorted { $0.distance < $1.distance }.prefix(20))
    }

    // MARK: - Index config (F4.6)

    func indexConfig() throws -> IndexConfig? {
        guard let version = try metaValue(for: "model_version"),
              let dimString = try metaValue(for: "dimension"),
              let dim = Int(dimString)
        else { return nil }
        return IndexConfig(modelVersion: version, dimension: dim)
    }

    func setIndexConfig(_ config: IndexConfig) throws {
        try setMetaValue(config.modelVersion, for: "model_version")
        try setMetaValue(String(config.dimension), for: "dimension")
    }

    private func metaValue(for key: String) throws -> String? {
        let stmt = try prepare("SELECT value FROM meta WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(key, at: 1, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    private func setMetaValue(_ value: String, for key: String) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);")
        defer { sqlite3_finalize(stmt) }
        bindText(key, at: 1, in: stmt)
        bindText(value, at: 2, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw storeError() }
    }

    // MARK: - Helpers

    private func transaction(_ body: () throws -> Void) throws {
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        do {
            try body()
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw storeError()
        }
        return stmt
    }

    private func bindText(_ value: String, at index: Int32, in stmt: OpaquePointer) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ value: Double?, at index: Int32, in stmt: OpaquePointer) {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    /// Binds the seven metadata columns starting at `first`.
    private func bindMeta(_ meta: PhotoMeta, from first: Int32, in stmt: OpaquePointer) {
        bind(meta.takenAt?.timeIntervalSince1970, at: first, in: stmt)
        sqlite3_bind_int(stmt, first + 1, meta.isFavorite ? 1 : 0)
        sqlite3_bind_int(stmt, first + 2, Int32(meta.kinds.rawValue))
        bind(meta.latitude, at: first + 3, in: stmt)
        bind(meta.longitude, at: first + 4, in: stmt)
        if let city = meta.cityID { sqlite3_bind_int64(stmt, first + 5, Int64(city)) } else { sqlite3_bind_null(stmt, first + 5) }
        bind(meta.cityKm, at: first + 6, in: stmt)
    }

    private func double(_ stmt: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, column)
    }

    private func vector(_ stmt: OpaquePointer, _ column: Int32) -> [Float] {
        guard let blob = sqlite3_column_blob(stmt, column) else { return [] }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return Data(bytes: blob, count: count).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func lastErrorMessage() -> String {
        Self.errorMessage(for: db)
    }

    private nonisolated static func errorMessage(for db: OpaquePointer?) -> String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? String(localized: "未知数据库错误")
    }

    private func storeError() -> EmbeddingStoreError {
        .sqlite(openError ?? lastErrorMessage())
    }
}

enum EmbeddingStoreError: LocalizedError {
    case sqlite(String)
    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return String(localized: "索引数据库错误:\(message)")
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
