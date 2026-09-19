import Foundation
import SQLite3

enum AntigravityScanError: LocalizedError, Equatable {
    case missingRoot(String)
    case database(String)

    var errorDescription: String? {
        switch self {
        case .missingRoot(let path): return "No Antigravity conversations at \(path)."
        case .database(let why): return "Antigravity database: \(why)."
        }
    }
}

// MARK: - Scanner

/// Reads Antigravity's per-conversation SQLite databases incrementally: the IDE keeps one under
/// `~/.gemini/antigravity/conversations` (and the CLI under `~/.gemini/antigravity-cli`) whose
/// `gen_metadata` table holds one protobuf blob per model response, with the token counts inside.
/// The highest row consumed per database is persisted, so a poll decodes only the rows appended
/// since the last one. The databases are opened read-only; the IDE keeps writing to them.
///
/// A response's time is not in its own row: the `last_step_index` tag names the conversation
/// step it ended on, and that step's row in `steps` carries the timestamp. A response without the
/// tag takes the first timestamp of its turn (the `stepUUID` both tables carry), and one without
/// either the database's modification time.
actor AntigravityTokenScanner {
    let roots: [URL]
    /// nil disables persistence (tests).
    let cacheURL: URL?

    static let defaultRoots = ["antigravity", "antigravity-cli"].map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/\($0)/conversations", isDirectory: true)
    }
    static var defaultCacheURL: URL { AppPaths.supportDirectory.appendingPathComponent("antigravity-tokens.json") }

    init(roots: [URL] = AntigravityTokenScanner.defaultRoots, cacheURL: URL? = AntigravityTokenScanner.defaultCacheURL) {
        self.roots = roots
        self.cacheURL = cacheURL
    }

    /// Bumped whenever the cache shape, the decoding or the retention changes, which forces a
    /// full rescan on the next launch. 2: retention grew from 31 to 91 days; databases already
    /// read to their end would otherwise never give back the rows a version-1 cache had pruned.
    static let cacheVersion = 2

    private struct Mark: Codable, Equatable {
        /// Highest `gen_metadata.idx` consumed; -1 before the first read.
        var genIdx: Int64
        /// Newest modification time of the database and its -wal, in ms, so an untouched database is not reopened.
        var stamp: Int64
    }

    private struct Cache: Codable {
        static let currentVersion = AntigravityTokenScanner.cacheVersion
        var version = currentVersion
        /// Symlink-resolved database path -> where the last scan stopped.
        var marks: [String: Mark] = [:]
        /// "<conversation id>:<response id>" -> record.
        var records: [String: TokenRecord] = [:]
        /// `model_enum` tag -> model id, learnt from responses that carry both, for the few that carry only the enum.
        var models: [String: String] = [:]
    }

    /// Loaded lazily on the first scan so init stays cheap and synchronous.
    private var cache: Cache?
    private var dirty = false
    private let decoder = UsageClient.makeDecoder()

    /// Scans, prunes anything older than `retainSince`, saves the cache when dirty,
    /// and returns every retained record.
    func scan(retainSince: Date) throws -> [TokenRecord] {
        var cache = self.cache ?? loadCache()
        var seen = Set<String>()

        for file in try enumerate() {
            // Every row in a database is older than its newest write, so nothing inside can be in-window.
            guard file.mtime >= retainSince else { continue }
            seen.insert(file.path)

            var mark = cache.marks[file.path] ?? Mark(genIdx: -1, stamp: 0)
            if mark.stamp == file.stamp { continue }
            // A database the IDE has locked or is replacing is left alone and retried next poll.
            guard let db = try? Database(path: file.path) else { continue }
            do {
                let maxIdx = try db.scalar("SELECT max(idx) FROM gen_metadata") ?? -1
                // Replaced with a shorter database: re-read from the top, the response-id dedup keeps that idempotent.
                if maxIdx < mark.genIdx { mark.genIdx = -1 }
                if maxIdx > mark.genIdx {
                    try ingest(db, conversation: file.id, after: mark.genIdx, fallback: file.mtime,
                               into: &cache, retainSince: retainSince)
                    mark.genIdx = maxIdx
                }
                mark.stamp = file.stamp
            } catch {
                continue
            }
            if cache.marks[file.path] != mark {
                cache.marks[file.path] = mark
                dirty = true
            }
        }

        let before = cache.records.count
        cache.records = cache.records.filter { $0.value.timestamp >= retainSince }
        if cache.records.count != before { dirty = true }
        let stale = cache.marks.keys.filter { !seen.contains($0) }
        for path in stale {
            cache.marks.removeValue(forKey: path)
            dirty = true
        }

        self.cache = cache
        if dirty {
            saveCache(cache)
            dirty = false
        }
        return Array(cache.records.values)
    }

    // MARK: - files

    private struct Entry {
        var path: String
        /// The conversation id: the database's file name without its extension.
        var id: String
        var mtime: Date
        var stamp: Int64
    }

    /// Every `*.db` directly under each root that exists, sorted by path. At least one root must exist.
    private func enumerate() throws -> [Entry] {
        var entries: [Entry] = []
        var found = false
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            found = true
            let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
            for url in urls where url.pathExtension == "db" {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                var mtime = values.contentModificationDate ?? .distantPast
                // In WAL mode the appended rows sit in the -wal until a checkpoint moves them over.
                let wal = URL(fileURLWithPath: url.path + "-wal")
                if let walDate = (try? wal.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    mtime = max(mtime, walDate)
                }
                entries.append(Entry(path: url.resolvingSymlinksInPath().path,
                                     id: url.deletingPathExtension().lastPathComponent,
                                     mtime: mtime,
                                     stamp: Int64((mtime.timeIntervalSince1970 * 1000).rounded())))
            }
        }
        guard found else { throw AntigravityScanError.missingRoot(roots.first?.path ?? "~/.gemini/antigravity/conversations") }
        return entries.sorted { $0.path < $1.path }
    }

    // MARK: - rows

    private func ingest(_ db: Database, conversation: String, after: Int64, fallback: Date,
                        into cache: inout Cache, retainSince: Date) throws
    {
        var generations: [AntigravityProto.Generation] = []
        try db.rows("SELECT idx, data FROM gen_metadata WHERE idx > ? ORDER BY idx", bind: after) { idx, blob in
            if let generation = AntigravityProto.generation(idx: idx, blob) { generations.append(generation) }
        }
        guard !generations.isEmpty else { return }

        // Only the steps the new responses point at, unless one needs the turn lookup.
        let needsTurns = generations.contains { $0.lastStepIndex == nil }
        let firstStep = needsTurns ? 0 : (generations.compactMap(\.lastStepIndex).min() ?? 0)
        var byIndex: [Int64: Date] = [:]
        var byTurn: [String: Date] = [:]
        try db.rows("SELECT idx, metadata FROM steps WHERE idx >= ? ORDER BY idx", bind: firstStep) { idx, blob in
            guard let step = AntigravityProto.step(blob), let timestamp = step.timestamp else { return }
            byIndex[idx] = timestamp
            if let uuid = step.uuid, byTurn[uuid] == nil { byTurn[uuid] = timestamp }
        }

        for g in generations {
            if let model = g.model, let code = g.modelEnum, cache.models[code] != model {
                cache.models[code] = model
                dirty = true
            }
            let model = g.model ?? g.modelEnum.flatMap { cache.models[$0] } ?? g.modelEnum ?? "unknown"
            let timestamp = g.lastStepIndex.flatMap { byIndex[$0] } ?? g.stepUUID.flatMap { byTurn[$0] } ?? fallback
            guard timestamp >= retainSince else { continue }

            // Thinking is billed as output; Antigravity reports no cache writes.
            let record = TokenRecord(timestamp: timestamp,
                                     model: model,
                                     input: g.systemPrompt + g.newInput,
                                     output: g.output + g.reasoning,
                                     cacheWrite5m: 0,
                                     cacheWrite1h: 0,
                                     cacheRead: g.cacheRead,
                                     sessionId: conversation)
            // An aborted generation leaves a row with no counts at all.
            guard record.total > 0 else { continue }
            let key = "\(conversation):" + (g.responseID ?? "row-\(g.idx)")
            if let old = cache.records[key], old.total >= record.total { continue }
            cache.records[key] = record
            dirty = true
        }
    }

    // MARK: - cache

    /// Decode failure or a version mismatch means a full first scan.
    private func loadCache() -> Cache {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? decoder.decode(Cache.self, from: data),
              cache.version == Cache.currentVersion else { return Cache() }
        return cache
    }

    private func saveCache(_ cache: Cache) {
        guard let cacheURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - SQLite

/// A read-only connection; `sqlite3_open_v2` with `SQLITE_OPEN_READONLY` never creates or
/// alters the database, and a short busy timeout rides out the IDE's own writes.
private final class Database {
    private let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw AntigravityScanError.database("open failed with code \(rc)")
        }
        sqlite3_busy_timeout(db, 250)
        handle = db
    }

    deinit { sqlite3_close(handle) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AntigravityScanError.database(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    /// The first column of the first row as an integer; nil for no row or NULL.
    func scalar(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
        case SQLITE_DONE: return nil
        default: throw AntigravityScanError.database(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Runs `sql` with one integer bound to its `?` and hands `body` each row's integer first
    /// column and blob second column; rows whose second column is not a blob are skipped.
    func rows(_ sql: String, bind: Int64, _ body: (Int64, ArraySlice<UInt8>) -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, bind)
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw AntigravityScanError.database(String(cString: sqlite3_errmsg(handle))) }
            guard sqlite3_column_type(statement, 1) == SQLITE_BLOB, let pointer = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            let bytes = Array(UnsafeRawBufferPointer(start: pointer, count: count))
            body(sqlite3_column_int64(statement, 0), bytes[...])
        }
    }
}

// MARK: - Protobuf

/// The slice of the protobuf wire format the scanner needs, walked without a schema: varints and
/// length-delimited fields are kept, fixed-width ones skipped, and anything else (a group, a
/// truncated field) ends the walk. The field numbers below are Antigravity's, as observed in its
/// databases; they are not published.
enum AntigravityProto {
    struct Field {
        var number: Int
        /// The varint value; 0 for a length-delimited field.
        var value: UInt64
        /// The payload of a length-delimited field; empty otherwise.
        var bytes: ArraySlice<UInt8>
        var isLengthDelimited: Bool

        var int: Int { isLengthDelimited ? 0 : Int(clamping: value) }
        var string: String? { isLengthDelimited ? String(bytes: bytes, encoding: .utf8) : nil }
    }

    /// One `gen_metadata` row: the counts and the pointers that place it in time.
    struct Generation: Equatable {
        var idx: Int64
        var model: String?
        var modelEnum: String?
        var responseID: String?
        var lastStepIndex: Int64?
        var stepUUID: String?
        var systemPrompt = 0
        var newInput = 0
        var cacheRead = 0
        var output = 0
        var reasoning = 0
    }

    /// nil on a message that does not parse.
    static func fields(_ bytes: ArraySlice<UInt8>) -> [Field]? {
        var out: [Field] = []
        var i = bytes.startIndex
        while i < bytes.endIndex {
            guard let (tag, afterTag) = varint(bytes, at: i) else { return nil }
            i = afterTag
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let (value, next) = varint(bytes, at: i) else { return nil }
                out.append(Field(number: number, value: value, bytes: [], isLengthDelimited: false))
                i = next
            case 1:
                guard bytes.endIndex - i >= 8 else { return nil }
                i += 8
            case 2:
                guard let (length, start) = varint(bytes, at: i), length <= UInt64(bytes.endIndex - start) else { return nil }
                let end = start + Int(length)
                out.append(Field(number: number, value: 0, bytes: bytes[start..<end], isLengthDelimited: true))
                i = end
            case 5:
                guard bytes.endIndex - i >= 4 else { return nil }
                i += 4
            default:
                return nil
            }
        }
        return out
    }

    static func varint(_ bytes: ArraySlice<UInt8>, at start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < bytes.endIndex, shift < 64 {
            let byte = bytes[i]
            i += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
        }
        return nil
    }

    private static func message(_ fields: [Field], _ number: Int) -> [Field]? {
        fields.first { $0.number == number && $0.isLengthDelimited }.flatMap { Self.fields($0.bytes) }
    }

    /// Root: 1 = the chat message, 4 = the turn's step uuid. Chat: 4 = usage, 19 = model id,
    /// 20 (repeated) = {1 key, 2 value} tags. Usage: 1 system prompt, 2 new input, 5 cache read,
    /// 9 output, 10 reasoning, 11 response id. Rows without a usage message (the conversation's
    /// configuration blobs share the table) come back nil.
    static func generation(idx: Int64, _ data: ArraySlice<UInt8>) -> Generation? {
        guard let root = fields(data), let chat = message(root, 1), let usage = message(chat, 4) else { return nil }
        var g = Generation(idx: idx)
        g.stepUUID = root.first { $0.number == 4 }?.string
        for field in usage {
            switch field.number {
            case 1: g.systemPrompt = field.int
            case 2: g.newInput = field.int
            case 5: g.cacheRead = field.int
            case 9: g.output = field.int
            case 10: g.reasoning = field.int
            case 11: g.responseID = field.string
            default: break
            }
        }
        for field in chat {
            switch field.number {
            case 19:
                g.model = field.string
            case 20:
                guard let tag = fields(field.bytes) else { continue }
                let value = tag.first { $0.number == 2 }?.string
                switch tag.first(where: { $0.number == 1 })?.string {
                case "model_enum": g.modelEnum = value
                case "last_step_index": g.lastStepIndex = value.flatMap { Int64($0) }
                default: break
                }
            default:
                break
            }
        }
        return g
    }

    /// `steps.metadata`: 1 = {1 seconds, 2 nanos} when the step was recorded, 12 = the turn's step uuid.
    static func step(_ data: ArraySlice<UInt8>) -> (timestamp: Date?, uuid: String?)? {
        guard let root = fields(data) else { return nil }
        var timestamp: Date?
        if let stamp = message(root, 1) {
            let seconds = stamp.first { $0.number == 1 }?.int ?? 0
            let nanos = stamp.first { $0.number == 2 }?.int ?? 0
            if seconds > 0 { timestamp = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9) }
        }
        return (timestamp, root.first { $0.number == 12 }?.string)
    }
}
