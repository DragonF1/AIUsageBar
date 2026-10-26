import Foundation

// MARK: - Records

/// One API response from a Claude Code transcript, deduplicated on message id.
struct TokenRecord: Codable, Equatable, Sendable {
    var timestamp: Date
    /// Model id with any "[1m]" suffix stripped.
    var model: String
    var input: Int
    var output: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
    var cacheRead: Int
    /// The session the response belongs to. Antigravity records carry their conversation id;
    /// the Claude Code scanner leaves it nil (nothing reads it, and 150k copies of a UUID add up).
    var sessionId: String? = nil

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
}

/// What a transcript says about its session beyond the token records: the title Claude Code
/// gives it, the launcher colour, where it runs, and when it was first and last seen answering.
struct SessionMeta: Codable, Equatable, Sendable, Identifiable {
    var sessionId: String
    var title: String?
    var lastPrompt: String?
    var color: String?
    var cwd: String?
    var gitBranch: String?
    var slug: String?
    var firstSeen: Date
    var lastSeen: Date

    var id: String { sessionId }
}

/// Minimal shape of a transcript line; everything optional, only assistant lines are used.
private struct TranscriptLine: Decodable {
    var type: String?
    var timestamp: Date?
    var uuid: String?
    var requestId: String?
    var message: Message?

    struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?

        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?
            var cacheCreation: CacheCreation?
            /// Per-iteration usage of the same response; a few lines carry the totals only here.
            var iterations: [Usage]?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreation = "cache_creation"
                case iterations
            }

            var input: Int { inputTokens ?? 0 }
            var output: Int { outputTokens ?? 0 }
            var cacheRead: Int { cacheReadInputTokens ?? 0 }

            /// (5 m, 1 h) cache writes: the per-TTL object when present, else the flat count as 5 m.
            var cacheWrites: (Int, Int) {
                if let cc = cacheCreation, cc.ephemeral5m != nil || cc.ephemeral1h != nil {
                    return (cc.ephemeral5m ?? 0, cc.ephemeral1h ?? 0)
                }
                return (cacheCreationInputTokens ?? 0, 0)
            }

            var total: Int { input + output + cacheRead + cacheWrites.0 + cacheWrites.1 }

            /// The top-level counts, or the sum of `iterations` when that carries more: a few
            /// responses arrive with zeroed top-level fields and the real numbers one level down.
            var effective: (input: Int, output: Int, write5m: Int, write1h: Int, cacheRead: Int) {
                let top = (input, output, cacheWrites.0, cacheWrites.1, cacheRead)
                guard let iterations, !iterations.isEmpty else { return top }
                let summed = iterations.reduce(into: (0, 0, 0, 0, 0)) { acc, it in
                    let writes = it.cacheWrites
                    acc.0 += it.input; acc.1 += it.output; acc.2 += writes.0; acc.3 += writes.1; acc.4 += it.cacheRead
                }
                let summedTotal = summed.0 + summed.1 + summed.2 + summed.3 + summed.4
                return summedTotal > total ? summed : top
            }

            struct CacheCreation: Decodable {
                var ephemeral5m: Int?
                var ephemeral1h: Int?
                enum CodingKeys: String, CodingKey {
                    case ephemeral5m = "ephemeral_5m_input_tokens"
                    case ephemeral1h = "ephemeral_1h_input_tokens"
                }
            }
        }
    }
}

enum TokenScanError: LocalizedError, Equatable {
    case missingRoot(String)

    var errorDescription: String? {
        switch self {
        case .missingRoot(let path): return "No Claude Code transcripts at \(path)."
        }
    }
}

// MARK: - Scanner

/// Reads the Claude folder's `projects` (`~/.claude/projects` by default) incrementally: per-file
/// byte offsets plus a deduplicated record list, both persisted so a poll only reads the bytes
/// appended since the last one.
///
/// Sized for a heavy user (150k responses over the 91-day retention): the records live in one
/// array kept oldest first, so a scan that read nothing hands back the very same buffer and the
/// sums over it can binary-search their window; records are keyed by a 64-bit hash of the message
/// id instead of the id itself; and the cache file is a flat binary written at most every
/// `saveInterval` instead of a 40 MB JSON rewritten on every scan.
actor TokenScanner {
    let root: URL
    /// nil disables persistence (tests).
    let cacheURL: URL?
    /// The shortest gap between two cache writes; `flush()` writes whatever is pending.
    let saveInterval: TimeInterval

    /// The folder set in Settings, read when a scanner is made; each folder has a cache of its own.
    static var defaultRoot: URL { ClaudeFolder.current().projectsRoot }
    static var defaultCacheURL: URL { ClaudeFolder.current().tokenCacheURL }

    init(root: URL = TokenScanner.defaultRoot, cacheURL: URL? = TokenScanner.defaultCacheURL,
         saveInterval: TimeInterval = 300)
    {
        self.root = root
        self.cacheURL = cacheURL
        self.saveInterval = saveInterval
    }

    /// Bumped whenever the cache shape or the retention changes, which forces a full rescan on
    /// the next launch. 2: records carry a session id and the cache holds session metadata.
    /// 3: retention grew from 8 to 31 days; files already read to their end would otherwise
    /// never give back the older lines that a version-2 cache had pruned. 4: retention grew
    /// again, to 91 days, for the cost window's 90-day range. 5: the binary file below, with
    /// hashed keys and no session metadata; a version-4 JSON cache is converted, not rescanned.
    static let cacheVersion = 5
    /// The last JSON cache version, the only one `migrateLegacyCache` converts.
    static let legacyCacheVersion = 4
    /// Records older than the retention window are dropped once the oldest is this far past it,
    /// so pruning (which renumbers the whole index) runs about once an hour instead of every scan.
    static let pruneSlack: TimeInterval = 3600

    /// Symlink-resolved absolute path -> bytes consumed; always ends just after a newline.
    private var offsets: [String: UInt64] = [:]
    /// Oldest first; ties keep the order they were read in.
    private var records: [TokenRecord] = []
    /// `recordKey` of each record, parallel to `records`.
    private var keys: [UInt64] = []
    /// Record key -> position in `records`.
    private var index: [UInt64: Int] = [:]
    /// One instance per model id, so 150k records share a handful of string buffers.
    private var models: [String: String] = [:]

    /// The cache is loaded lazily on the first scan so init stays cheap and synchronous.
    private var loaded = false
    private var dirty = false
    /// When the last save was tried (uptime, so a clock change neither stalls nor rushes the
    /// next one); a failed write also waits out `saveInterval` rather than retrying every scan.
    private var lastSaveAttempt: TimeInterval?
    /// A version-4 JSON cache read by `load()`, deleted once its replacement is on disk.
    private var legacyToRemove: URL?
    private let decoder = UsageClient.makeDecoder()

    private static let chunkSize = 1 << 20
    /// Longest line the scanner is willing to hold while waiting for its newline (real lines top out near 2 MB).
    private static let maxLineBytes = 64 << 20
    private static let newline: UInt8 = 0x0A
    /// Cheap raw prefilter; the files are compact JSON so the key and value are adjacent.
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)

    /// Scans, prunes anything older than `retainSince` (with `pruneSlack`), saves the cache when
    /// it is dirty and the last save is `saveInterval` old, and returns every retained record,
    /// oldest first.
    func scan(retainSince: Date) throws -> [TokenRecord] {
        if !loaded { load() }
        let files = try enumerate()
        let firstNew = records.count
        // Lowest position whose record changed its timestamp in place; everything from there on
        // is re-sorted along with the new records.
        var firstMoved = firstNew

        for file in files {
            // Every line in a file is older than its mtime, so nothing inside can be in-window.
            guard file.mtime >= retainSince else { continue }
            var offset = offsets[file.path] ?? 0
            // Replaced or truncated: re-read from the top, id dedup keeps that idempotent.
            if file.size < offset { offset = 0 }
            if file.size > offset {
                offset = consume(file.url, from: offset) { line in
                    if let moved = ingest(line, retainSince: retainSince) { firstMoved = min(firstMoved, moved) }
                }
            }
            if offsets[file.path] != offset {
                offsets[file.path] = offset
                dirty = true
            }
        }
        restoreOrder(from: firstMoved)

        prune(before: retainSince)
        // Offsets for files that are gone or aged out. Every file still in the window has an
        // entry by now, so there is nothing stale unless the map outgrew that set. A file
        // appended to again later is re-read from 0; the timestamp filter and dedup keep that correct.
        let inWindow = files.lazy.filter { $0.mtime >= retainSince }.map(\.path)
        if offsets.count > inWindow.count {
            let seen = Set(inWindow)
            for path in offsets.keys where !seen.contains(path) {
                offsets.removeValue(forKey: path)
            }
            dirty = true
        }

        if dirty, lastSaveAttempt.map({ ProcessInfo.processInfo.systemUptime - $0 >= saveInterval }) ?? true {
            save()
        }
        return records
    }

    /// Writes the cache now if anything changed since the last write: before the app quits, and
    /// before the store swaps this scanner for another folder's.
    func flush() {
        if dirty { save() }
    }

    // MARK: - files

    private struct Entry {
        var path: String
        var size: UInt64
        var mtime: Date

        var url: URL { URL(fileURLWithPath: path, isDirectory: false) }
    }

    /// Every `*.jsonl` under the root at any depth (subagents nest two and four levels down), sorted by path.
    private func enumerate() throws -> [Entry] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TokenScanError.missingRoot(root.path)
        }
        // The root is resolved once and fts joins each name onto it, so every key is spelled the
        // same however the root was (/var vs /private/var) without a realpath per file. A URL
        // enumerator would hand back /private/var paths that the resolved root, and every cache
        // written so far, spell /var.
        let base = root.resolvingSymlinksInPath().path
        // fts rather than FileManager: this runs on every refresh, and the directory enumerator's
        // `fileAttributes` costs an attributesOfItem (extended attributes included) per file, about
        // 70 ms a pass over 1500 transcripts. fts hands back the lstat it already made.
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(base), nil]
        defer { free(argv[0]) }
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            throw TokenScanError.missingRoot(root.path)
        }
        defer { fts_close(stream) }
        var entries: [Entry] = []
        while let node = fts_read(stream) {
            // Regular files only (FTS_PHYSICAL reports symlinks as FTS_SL and never follows them).
            guard Int32(node.pointee.fts_info) == FTS_F, let stat = node.pointee.fts_statp?.pointee else { continue }
            let path = String(cString: node.pointee.fts_path)
            guard path.hasSuffix(".jsonl") else { continue }
            let mtime = stat.st_mtimespec
            entries.append(Entry(path: path,
                                 size: UInt64(max(stat.st_size, 0)),
                                 mtime: Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1e9)))
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Reads from `start` in 1 MB chunks and hands out complete lines only. Returns the offset just
    /// after the last newline consumed; a partial trailing line waits for the next scan.
    /// A file that cannot be opened is left alone (its offset stays put).
    private func consume(_ url: URL, from start: UInt64, handle: (Data) -> Void) -> UInt64 {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return start }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: start)) != nil else { return start }

        var consumed = start
        // Bytes after the last newline seen so far. Data slices keep their parent's indices,
        // so every position below is relative to `pending.startIndex`.
        var pending = Data()
        // The chunk is autoreleased; without a pool every chunk of a file stays resident until
        // the scan returns (hundreds of MB for a busy session file instead of a few).
        while let chunk = autoreleasepool(invoking: { try? fh.read(upToCount: Self.chunkSize) }), !chunk.isEmpty {
            // Newlines before the old tail were already searched.
            var searchFrom = pending.endIndex
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let nl = pending[searchFrom...].firstIndex(of: Self.newline) {
                handle(Data(pending[lineStart..<nl]))
                lineStart = nl + 1
                searchFrom = lineStart
            }
            consumed += UInt64(lineStart - pending.startIndex)
            pending.removeSubrange(pending.startIndex..<lineStart)
            // A line that never ends (a file with no trailing newline for many MB) is not buffered
            // without limit; the file is left at `consumed` and retried next poll.
            if pending.count > Self.maxLineBytes { break }
        }
        return consumed
    }

    // MARK: - lines

    /// Takes in one line. Returns the position of a record whose timestamp it changed, which
    /// breaks the oldest-first order before the new records; nil otherwise.
    private func ingest(_ line: Data, retainSince: Date) -> Int? {
        guard line.range(of: Self.assistantMarker) != nil,
              let entry = try? decoder.decode(TranscriptLine.self, from: line),
              entry.type == "assistant",
              let message = entry.message,
              let usage = message.usage,
              let timestamp = entry.timestamp,
              timestamp >= retainSince,
              let id = message.id ?? entry.requestId ?? entry.uuid
        else { return nil }

        var model = message.model ?? ""
        if model.contains("[") { model = model.replacingOccurrences(of: "[1m]", with: "") }
        guard model != "<synthetic>" else { return nil }

        let counts = usage.effective
        let record = TokenRecord(timestamp: timestamp,
                                 model: intern(model),
                                 input: counts.input,
                                 output: counts.output,
                                 cacheWrite5m: counts.write5m,
                                 cacheWrite1h: counts.write1h,
                                 cacheRead: counts.cacheRead)

        // Block lines of one response repeat the same usage; forked sessions copy lines,
        // sometimes with zeroed usage. The larger total wins either way.
        let key = Self.recordKey(id)
        guard let position = index[key] else {
            index[key] = records.count
            records.append(record)
            keys.append(key)
            dirty = true
            return nil
        }
        let old = records[position]
        guard record.total > old.total else { return nil }
        records[position] = record
        dirty = true
        return record.timestamp == old.timestamp ? nil : position
    }

    private func intern(_ model: String) -> String {
        if let shared = models[model] { return shared }
        models[model] = model
        return model
    }

    /// 64-bit FNV-1a of the message id. Stable across launches (Swift's `Hasher` is seeded per
    /// process), and at 150k ids the odds of any two colliding are about one in a billion.
    static func recordKey(_ id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - order

    /// Puts `records` back in oldest-first order when everything before `start` already is.
    /// A scan appends in file order, and parallel sessions interleave, so the new tail usually
    /// lands a few minutes back: only the records from the earliest new timestamp onwards move.
    private func restoreOrder(from start: Int) {
        let count = records.count
        guard start < count else { return }
        var lowest = records[start].timestamp
        var tailSorted = true
        for i in (start + 1)..<count {
            let t = records[i].timestamp
            if t < records[i - 1].timestamp { tailSorted = false }
            if t < lowest { lowest = t }
        }
        let from = firstIndex(after: lowest, below: start)
        if tailSorted && from == start { return }

        let order = (from..<count).sorted { a, b in
            let ta = records[a].timestamp, tb = records[b].timestamp
            return ta != tb ? ta < tb : a < b
        }
        let movedRecords = order.map { records[$0] }
        let movedKeys = order.map { keys[$0] }
        records.replaceSubrange(from..<count, with: movedRecords)
        keys.replaceSubrange(from..<count, with: movedKeys)
        for i in from..<count { index[keys[i]] = i }
    }

    /// The first position below `end` whose record is newer than `date` (`end` when none is).
    private func firstIndex(after date: Date, below end: Int) -> Int {
        var lo = 0, hi = end
        while lo < hi {
            let mid = (lo + hi) / 2
            if records[mid].timestamp <= date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Drops every record older than `retainSince`, but only once the oldest is `pruneSlack`
    /// past it: the drop renumbers the index, which is not worth doing for a record or two.
    private func prune(before retainSince: Date) {
        guard let oldest = records.first?.timestamp,
              oldest < retainSince.addingTimeInterval(-Self.pruneSlack) else { return }
        var cut = 0, hi = records.count
        while cut < hi {
            let mid = (cut + hi) / 2
            if records[mid].timestamp < retainSince { cut = mid + 1 } else { hi = mid }
        }
        records.removeFirst(cut)
        keys.removeFirst(cut)
        rebuildIndex()
        dirty = true
    }

    private func rebuildIndex() {
        index = [:]
        index.reserveCapacity(keys.count)
        for (position, key) in keys.enumerated() { index[key] = position }
    }

    // MARK: - cache

    /// A failed read or a version mismatch means a full first scan; a version-4 JSON cache next
    /// to the binary path is converted instead (re-reading 90 days of transcripts can take minutes).
    private func load() {
        loaded = true
        guard let cacheURL else { return }
        if let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
           let file = CacheFile(data: data), file.version == Self.cacheVersion {
            adopt(file)
            return
        }
        migrateLegacyCache()
    }

    private func adopt(_ file: CacheFile) {
        offsets = file.offsets
        records = file.records.map { var r = $0; r.model = intern(r.model); return r }
        keys = file.keys
        rebuildIndex()
        // A file written by this version is already oldest first; this pass only costs a scan.
        restoreOrder(from: 0)
    }

    /// `tokens.json` (version 4) next to a `tokens.bin` cache path: its offsets and records are
    /// taken over as they are, and the JSON is deleted once the binary file is written.
    private func migrateLegacyCache() {
        guard let cacheURL, cacheURL.pathExtension == "bin" else { return }
        let legacy = cacheURL.deletingPathExtension().appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        legacyToRemove = legacy
        dirty = true
        struct Legacy: Decodable {
            var version: Int
            var offsets: [String: UInt64]
            var records: [String: TokenRecord]
        }
        autoreleasepool {
            guard let data = try? Data(contentsOf: legacy),
                  let old = try? decoder.decode(Legacy.self, from: data),
                  old.version == Self.legacyCacheVersion else { return }
            offsets = old.offsets
            let sorted = old.records.sorted { $0.value.timestamp < $1.value.timestamp }
            records = sorted.map { var r = $0.value; r.model = intern(r.model); r.sessionId = nil; return r }
            keys = sorted.map { Self.recordKey($0.key) }
            rebuildIndex()
        }
    }

    private func save() {
        guard let cacheURL else {
            dirty = false
            return
        }
        lastSaveAttempt = ProcessInfo.processInfo.systemUptime
        let data = CacheFile(offsets: offsets, records: records, keys: keys).encoded()
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: cacheURL, options: .atomic)) != nil else { return }
        dirty = false
        if let legacy = legacyToRemove {
            try? FileManager.default.removeItem(at: legacy)
            legacyToRemove = nil
        }
    }

    // MARK: - cache file

    /// The cache on disk, little-endian throughout:
    ///
    ///     "AUBT" | u32 version
    ///     u32 n | n × (u32 byte count | UTF-8 path | u64 offset)
    ///     u32 m | m × (u32 byte count | UTF-8 model id)
    ///     u32 r | r × (u64 key | f64 timestamp | u32 model | 5 × i64 input, output,
    ///                  cache write 5 m, cache write 1 h, cache read)
    ///
    /// About 60 bytes a record against JSON's 270, and it decodes without a parser.
    struct CacheFile {
        static let magic: [UInt8] = Array("AUBT".utf8)
        static let recordSize = 8 + 8 + 4 + 5 * 8

        var version = TokenScanner.cacheVersion
        var offsets: [String: UInt64]
        var records: [TokenRecord]
        var keys: [UInt64]

        init(offsets: [String: UInt64], records: [TokenRecord], keys: [UInt64]) {
            self.offsets = offsets
            self.records = records
            self.keys = keys
        }

        func encoded() -> Data {
            var modelIDs: [String: UInt32] = [:]
            var modelList: [String] = []
            for record in records where modelIDs[record.model] == nil {
                modelIDs[record.model] = UInt32(modelList.count)
                modelList.append(record.model)
            }
            let paths = offsets.map { (Array($0.key.utf8), $0.value) }
            let names = modelList.map { Array($0.utf8) }
            let size = 8 + 4 + paths.reduce(0) { $0 + 4 + $1.0.count + 8 }
                + 4 + names.reduce(0) { $0 + 4 + $1.count }
                + 4 + records.count * Self.recordSize

            var data = Data(count: size)
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                var writer = Writer(raw: raw)
                writer.bytes(Self.magic)
                writer.u32(UInt32(version))
                writer.u32(UInt32(paths.count))
                for (path, offset) in paths {
                    writer.u32(UInt32(path.count))
                    writer.bytes(path)
                    writer.u64(offset)
                }
                writer.u32(UInt32(names.count))
                for name in names {
                    writer.u32(UInt32(name.count))
                    writer.bytes(name)
                }
                writer.u32(UInt32(records.count))
                for (record, key) in zip(records, keys) {
                    writer.u64(key)
                    writer.u64(record.timestamp.timeIntervalSinceReferenceDate.bitPattern)
                    writer.u32(modelIDs[record.model] ?? 0)
                    writer.int(record.input)
                    writer.int(record.output)
                    writer.int(record.cacheWrite5m)
                    writer.int(record.cacheWrite1h)
                    writer.int(record.cacheRead)
                }
            }
            return data
        }

        /// nil for anything that is not a whole cache file (wrong magic, cut short); the caller
        /// checks the version.
        init?(data: Data) {
            let parsed: (Int, [String: UInt64], [TokenRecord], [UInt64])? = data.withUnsafeBytes { raw in
                var reader = Reader(raw: raw)
                guard reader.bytes(4).map(Array.init) == Self.magic, let version = reader.u32() else { return nil }
                guard Int(version) == TokenScanner.cacheVersion else { return (Int(version), [:], [], []) }

                guard let pathCount = reader.u32() else { return nil }
                var offsets: [String: UInt64] = [:]
                // A path entry is at least its length prefix and offset, so a corrupt count
                // cannot reserve more than the file could hold.
                offsets.reserveCapacity(min(Int(pathCount), reader.remaining / 12))
                for _ in 0..<pathCount {
                    guard let path = reader.string(), let offset = reader.u64() else { return nil }
                    offsets[path] = offset
                }
                guard let modelCount = reader.u32() else { return nil }
                var models: [String] = []
                for _ in 0..<modelCount {
                    guard let name = reader.string() else { return nil }
                    models.append(name)
                }
                guard let recordCount = reader.u32().map(Int.init),
                      reader.remaining >= recordCount * Self.recordSize else { return nil }
                var records: [TokenRecord] = []
                var keys: [UInt64] = []
                records.reserveCapacity(recordCount)
                keys.reserveCapacity(recordCount)
                for _ in 0..<recordCount {
                    guard let key = reader.u64(), let bits = reader.u64(), let model = reader.u32(),
                          Int(model) < models.count,
                          let input = reader.int(), let output = reader.int(), let write5m = reader.int(),
                          let write1h = reader.int(), let cacheRead = reader.int() else { return nil }
                    keys.append(key)
                    records.append(TokenRecord(timestamp: Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits)),
                                               model: models[Int(model)], input: input, output: output,
                                               cacheWrite5m: write5m, cacheWrite1h: write1h, cacheRead: cacheRead))
                }
                return (Int(version), offsets, records, keys)
            }
            guard let parsed else { return nil }
            version = parsed.0
            offsets = parsed.1
            records = parsed.2
            keys = parsed.3
        }

        private struct Writer {
            let raw: UnsafeMutableRawBufferPointer
            var at = 0

            mutating func bytes(_ b: [UInt8]) {
                // An empty model id ("" when a line has none) has no buffer to copy from.
                guard !b.isEmpty else { return }
                b.withUnsafeBytes { raw.baseAddress!.advanced(by: at).copyMemory(from: $0.baseAddress!, byteCount: b.count) }
                at += b.count
            }

            mutating func u32(_ v: UInt32) {
                raw.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt32.self)
                at += 4
            }

            mutating func u64(_ v: UInt64) {
                raw.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt64.self)
                at += 8
            }

            mutating func int(_ v: Int) { u64(UInt64(bitPattern: Int64(v))) }
        }

        private struct Reader {
            let raw: UnsafeRawBufferPointer
            var at = 0

            var remaining: Int { raw.count - at }

            mutating func bytes(_ n: Int) -> UnsafeRawBufferPointer? {
                guard n >= 0, remaining >= n else { return nil }
                defer { at += n }
                return UnsafeRawBufferPointer(rebasing: raw[at..<(at + n)])
            }

            mutating func u32() -> UInt32? {
                guard remaining >= 4 else { return nil }
                defer { at += 4 }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            }

            mutating func u64() -> UInt64? {
                guard remaining >= 8 else { return nil }
                defer { at += 8 }
                return UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt64.self))
            }

            mutating func int() -> Int? { u64().map { Int(Int64(bitPattern: $0)) } }

            mutating func string() -> String? {
                guard let count = u32(), let bytes = bytes(Int(count)) else { return nil }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }
}
