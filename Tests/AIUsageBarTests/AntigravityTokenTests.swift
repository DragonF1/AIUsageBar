import SQLite3
import XCTest
@testable import AIUsageBar

// MARK: - Fixtures

/// Just enough of the protobuf wire format to build the blobs Antigravity writes.
enum Proto {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            let byte = UInt8(v & 0x7f)
            v >>= 7
            out.append(v == 0 ? byte : byte | 0x80)
        } while v != 0
        return out
    }

    static func field(_ number: Int, varint value: Int) -> [UInt8] {
        varint(UInt64(number << 3)) + varint(UInt64(value))
    }

    static func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    static func field(_ number: Int, string: String) -> [UInt8] {
        field(number, bytes: Array(string.utf8))
    }

    /// A fixed64 field, which the scanner must step over.
    static func fixed64(_ number: Int) -> [UInt8] {
        varint(UInt64(number << 3 | 1)) + [UInt8](repeating: 0xab, count: 8)
    }

    static func tag(_ key: String, _ value: String) -> [UInt8] {
        field(20, bytes: field(1, string: key) + field(2, string: value))
    }
}

/// One `gen_metadata` row in Antigravity's layout: root.1 = chat, root.4 = turn uuid; chat.4 =
/// usage, chat.19 = model, chat.20 = tags.
func generationBlob(model: String? = "gemini-3.8-flash", modelEnum: String? = "MODEL_PLACEHOLDER_M36",
                    responseID: String? = "resp-1", lastStepIndex: Int64? = 2, stepUUID: String? = "turn-1",
                    system: Int = 100, new: Int = 50, cacheRead: Int = 1000, output: Int = 20, reasoning: Int = 30,
                    usage: Bool = true) -> [UInt8]
{
    var chat: [UInt8] = []
    if usage {
        var u = Proto.field(1, varint: system) + Proto.field(2, varint: new) + Proto.field(3, varint: 7)
            + Proto.field(5, varint: cacheRead) + Proto.field(9, varint: output) + Proto.field(10, varint: reasoning)
        if let responseID { u += Proto.field(11, string: responseID) }
        chat += Proto.field(4, bytes: u)
    }
    chat += Proto.fixed64(7)
    if let model { chat += Proto.field(19, string: model) }
    chat += Proto.tag("trajectory_id", "traj")
    if let modelEnum { chat += Proto.tag("model_enum", modelEnum) }
    if let lastStepIndex { chat += Proto.tag("last_step_index", String(lastStepIndex)) }
    var root = Proto.field(1, bytes: chat)
    if let stepUUID { root += Proto.field(4, string: stepUUID) }
    return root
}

/// One `steps.metadata` blob: 1 = {seconds, nanos}, 12 = turn uuid.
func stepBlob(at date: Date, uuid: String? = "turn-1") -> [UInt8] {
    let seconds = Int(date.timeIntervalSince1970.rounded(.down))
    let nanos = Int(((date.timeIntervalSince1970 - Double(seconds)) * 1e9).rounded())
    var root = Proto.field(1, bytes: Proto.field(1, varint: seconds) + Proto.field(2, varint: nanos))
    if let uuid { root += Proto.field(12, string: uuid) }
    return root
}

/// A conversation database with Antigravity's two tables, written through the C API.
final class FixtureDB {
    let url: URL
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw Failure.open }
        try exec("CREATE TABLE IF NOT EXISTS gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER)")
        try exec("""
        CREATE TABLE IF NOT EXISTS steps (idx INTEGER PRIMARY KEY, step_type TEXT, status TEXT, has_subtrajectory INTEGER,
            metadata BLOB, error_details TEXT, permissions TEXT, task_details TEXT, render_info TEXT, step_payload BLOB, step_format TEXT)
        """)
    }

    deinit { sqlite3_close(handle) }

    enum Failure: Error { case open, sql(String) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sql(String(cString: sqlite3_errmsg(handle))) }
    }

    func insertGeneration(_ idx: Int64, _ blob: [UInt8]) throws {
        try insert("INSERT OR REPLACE INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)", idx, blob)
    }

    func insertStep(_ idx: Int64, _ blob: [UInt8]) throws {
        try insert("INSERT OR REPLACE INTO steps (idx, step_type, metadata) VALUES (?, ?, ?)", idx, blob)
    }

    private func insert(_ sql: String, _ idx: Int64, _ blob: [UInt8]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.sql(String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, idx)
        if sql.contains("steps") {
            sqlite3_bind_text(statement, 2, "STEP", -1, Self.transient)
            blob.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(blob.count), Self.transient) }
        } else {
            blob.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(blob.count), Self.transient) }
            sqlite3_bind_int64(statement, 3, Int64(blob.count))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.sql(String(cString: sqlite3_errmsg(handle))) }
    }

    /// Moves the file's modification time so the scanner sees a change (or an old file).
    func touch(_ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

func tempConversationRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("conversations-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Whole seconds plus a nanosecond part that survives the round trip.
func stepDate(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + offset).rounded(.down) + 0.25)
}

// MARK: - Protobuf

final class AntigravityProtoTests: XCTestCase {
    func testGenerationParsesCountsModelAndTags() throws {
        let g = try XCTUnwrap(AntigravityProto.generation(idx: 7, generationBlob()[...]))
        XCTAssertEqual(g, AntigravityProto.Generation(idx: 7, model: "gemini-3.8-flash", modelEnum: "MODEL_PLACEHOLDER_M36",
                                                      responseID: "resp-1", lastStepIndex: 2, stepUUID: "turn-1",
                                                      systemPrompt: 100, newInput: 50, cacheRead: 1000, output: 20, reasoning: 30))
    }

    func testRowsWithoutUsageAreNotGenerations() {
        XCTAssertNil(AntigravityProto.generation(idx: 0, generationBlob(usage: false)[...]))
        XCTAssertNil(AntigravityProto.generation(idx: 0, []))
        XCTAssertNil(AntigravityProto.generation(idx: 0, Proto.field(2, string: "no chat")[...]))
    }

    func testTruncatedAndUnknownWireTypesFail() {
        let blob = generationBlob()
        XCTAssertNil(AntigravityProto.fields(blob.dropLast(3)))
        // Wire type 3 (a group) is not walked.
        XCTAssertNil(AntigravityProto.fields([0x0b, 0x00][...]))
        // A fixed32 is stepped over like the fixed64 the fixture already carries.
        let fixed32: [UInt8] = Proto.varint(UInt64(3 << 3 | 5)) + [1, 2, 3, 4]
        XCTAssertEqual(AntigravityProto.fields((fixed32 + Proto.field(9, varint: 5))[...])?.map(\.number), [9])
    }

    func testVarintDecoding() {
        XCTAssertEqual(AntigravityProto.varint(Proto.varint(300)[...], at: 0)?.0, 300)
        XCTAssertEqual(AntigravityProto.varint(Proto.varint(UInt64.max)[...], at: 0)?.0, UInt64.max)
        XCTAssertNil(AntigravityProto.varint([0x80][...], at: 0))
    }

    func testStepTimestampAndTurn() throws {
        let date = stepDate(-60)
        let step = try XCTUnwrap(AntigravityProto.step(stepBlob(at: date, uuid: "t")[...]))
        XCTAssertEqual(try XCTUnwrap(step.timestamp).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(step.uuid, "t")
        let bare = try XCTUnwrap(AntigravityProto.step(Proto.field(12, string: "only")[...]))
        XCTAssertNil(bare.timestamp)
        XCTAssertEqual(bare.uuid, "only")
    }
}

// MARK: - Scanner

final class AntigravityTokenScannerTests: XCTestCase {
    let since = Date().addingTimeInterval(-8 * 86400)

    private func scanner(_ root: URL, cache: URL? = nil) -> AntigravityTokenScanner {
        AntigravityTokenScanner(roots: [root], cacheURL: cache)
    }

    /// Three steps, the response pinned to the middle one.
    private func seed(_ db: FixtureDB, at date: Date) throws {
        try db.insertStep(0, stepBlob(at: date.addingTimeInterval(-20)))
        try db.insertStep(1, stepBlob(at: date.addingTimeInterval(-10)))
        try db.insertStep(2, stepBlob(at: date))
        try db.insertStep(3, stepBlob(at: date.addingTimeInterval(10), uuid: "turn-2"))
        try db.insertGeneration(0, generationBlob(usage: false))
        try db.insertGeneration(1, generationBlob())
    }

    func testReadsCountsAndJoinsTheStepTimestamp() async throws {
        let root = try tempConversationRoot()
        let date = stepDate(-3600)
        let db = try FixtureDB(root.appendingPathComponent("abc-123.db"))
        try seed(db, at: date)

        let records = try await scanner(root).scan(retainSince: since)
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.model, "gemini-3.8-flash")
        XCTAssertEqual(r.input, 150)
        XCTAssertEqual(r.output, 50)
        XCTAssertEqual(r.cacheRead, 1000)
        XCTAssertEqual(r.cacheWrite5m, 0)
        XCTAssertEqual(r.cacheWrite1h, 0)
        XCTAssertEqual(r.total, 1200)
        XCTAssertEqual(r.sessionId, "abc-123")
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1e-6)
    }

    func testTurnFallbackThenFileTimeFallback() async throws {
        let root = try tempConversationRoot()
        let date = stepDate(-3600)
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try seed(db, at: date)
        // No last_step_index: the first step of its turn dates it.
        try db.insertGeneration(2, generationBlob(responseID: "resp-2", lastStepIndex: nil, stepUUID: "turn-2"))
        // Neither pointer: the database's own modification time.
        try db.insertGeneration(3, generationBlob(responseID: "resp-3", lastStepIndex: nil, stepUUID: nil))
        let mtime = stepDate(-600)
        try db.touch(mtime)

        let records = try await scanner(root).scan(retainSince: since)
        XCTAssertEqual(records.count, 3)
        let stamps = Dictionary(uniqueKeysWithValues: records.map { ($0.timestamp.timeIntervalSince1970, $0) })
        XCTAssertNotNil(stamps[date.timeIntervalSince1970])
        XCTAssertNotNil(stamps[date.addingTimeInterval(10).timeIntervalSince1970])
        XCTAssertNotNil(stamps[mtime.timeIntervalSince1970])
    }

    func testIncrementalScanReadsOnlyNewRows() async throws {
        let root = try tempConversationRoot()
        let cache = root.appendingPathComponent("cache/antigravity-tokens.json")
        let date = stepDate(-3600)
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try seed(db, at: date)
        let scanner = scanner(root, cache: cache)
        let first = try await scanner.scan(retainSince: since)
        XCTAssertEqual(tokenSum(first), 1200)

        // Same stamp: the database is not reopened, so a row that sneaks in without a new mtime waits.
        let before = try XCTUnwrap(try? FileManager.default.attributesOfItem(atPath: db.url.path)[.modificationDate] as? Date)
        try db.insertGeneration(2, generationBlob(responseID: "resp-2", output: 1))
        try db.touch(before)
        let unchanged = try await scanner.scan(retainSince: since)
        XCTAssertEqual(unchanged.count, 1)

        try db.touch(before.addingTimeInterval(1))
        let records = try await scanner.scan(retainSince: since)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(tokenSum(records), 1200 + 1181)

        // The same rows again from a fresh scanner on the same cache: nothing doubles.
        let again = try await self.scanner(root, cache: cache).scan(retainSince: since)
        XCTAssertEqual(again.count, 2)
        let text = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\":\(AntigravityTokenScanner.cacheVersion)"))
        XCTAssertTrue(text.contains("MODEL_PLACEHOLDER_M36"))
    }

    func testShorterDatabaseIsRereadWithoutDoubling() async throws {
        let root = try tempConversationRoot()
        let cache = root.appendingPathComponent("cache/antigravity-tokens.json")
        let date = stepDate(-3600)
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try seed(db, at: date)
        try db.insertGeneration(5, generationBlob(responseID: "resp-5", output: 2))
        let scanner = scanner(root, cache: cache)
        let first = try await scanner.scan(retainSince: since)
        XCTAssertEqual(first.count, 2)

        try db.exec("DELETE FROM gen_metadata WHERE idx = 5")
        try db.insertGeneration(2, generationBlob(responseID: "resp-2", output: 3))
        try db.touch(Date().addingTimeInterval(-1))
        let records = try await scanner.scan(retainSince: since)
        // Row 5 stays in the cache (its response id was seen), row 2 is new: nothing counted twice.
        XCTAssertEqual(Set(records.map(\.output)), [50, 32, 33])
        XCTAssertEqual(records.count, 3)
    }

    func testDuplicateResponseKeepsTheLargerCount() async throws {
        let root = try tempConversationRoot()
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try seed(db, at: stepDate(-3600))
        try db.insertGeneration(2, generationBlob(output: 5))
        try db.insertGeneration(3, generationBlob(output: 500))
        try db.insertGeneration(4, generationBlob(output: 6))
        let records = try await scanner(root).scan(retainSince: since)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.output, 530)
    }

    func testRowsWithoutAResponseIdKeyOnTheirIndex() async throws {
        let root = try tempConversationRoot()
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try seed(db, at: stepDate(-3600))
        try db.insertGeneration(2, generationBlob(responseID: nil, output: 1))
        try db.insertGeneration(3, generationBlob(responseID: nil, output: 2))
        let records = try await scanner(root).scan(retainSince: since)
        XCTAssertEqual(records.count, 3)
    }

    func testEmptyGenerationsAreSkipped() async throws {
        let root = try tempConversationRoot()
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try db.insertStep(0, stepBlob(at: stepDate(-60)))
        try db.insertGeneration(1, generationBlob(lastStepIndex: 0, system: 0, new: 0, cacheRead: 0, output: 0, reasoning: 0))
        let records = try await scanner(root).scan(retainSince: since)
        XCTAssertEqual(records.count, 0)
    }

    func testModelEnumFallsBackToWhatEarlierRowsTaught() async throws {
        let root = try tempConversationRoot()
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try seed(db, at: stepDate(-3600))
        try db.insertGeneration(2, generationBlob(model: nil, modelEnum: "MODEL_PLACEHOLDER_M36", responseID: "resp-2"))
        try db.insertGeneration(3, generationBlob(model: nil, modelEnum: "MODEL_PLACEHOLDER_M99", responseID: "resp-3"))
        try db.insertGeneration(4, generationBlob(model: nil, modelEnum: nil, responseID: "resp-4"))
        let records = try await scanner(root).scan(retainSince: since)
        XCTAssertEqual(records.map(\.model).sorted(), ["MODEL_PLACEHOLDER_M99", "gemini-3.8-flash", "gemini-3.8-flash", "unknown"])
    }

    func testTheClaudeRouteKeepsItsOwnModelId() async throws {
        let root = try tempConversationRoot()
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try seed(db, at: stepDate(-3600))
        try db.insertGeneration(2, generationBlob(model: "claude-sonnet-4-6", modelEnum: "MODEL_CLAUDE", responseID: "resp-2"))
        let records = try await scanner(root).scan(retainSince: since)
        let claude = try XCTUnwrap(records.first { $0.model == "claude-sonnet-4-6" })
        XCTAssertNotNil(TokenPricing.cost(claude))
    }

    func testOldFilesAndOldRowsAreLeftOut() async throws {
        let root = try tempConversationRoot()
        let old = try FixtureDB(root.appendingPathComponent("old.db"))
        try seed(old, at: stepDate(-3600))
        try old.touch(Date().addingTimeInterval(-10 * 86400))
        let mixed = try FixtureDB(root.appendingPathComponent("mixed.db"))
        try mixed.insertStep(0, stepBlob(at: stepDate(-9 * 86400)))
        try mixed.insertStep(1, stepBlob(at: stepDate(-60)))
        try mixed.insertGeneration(1, generationBlob(responseID: "resp-old", lastStepIndex: 0))
        try mixed.insertGeneration(2, generationBlob(responseID: "resp-new", lastStepIndex: 1, output: 1))
        let records = try await scanner(root).scan(retainSince: since)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.output, 31)
    }

    func testRetentionPrunesCachedRecordsAndForgottenFiles() async throws {
        let root = try tempConversationRoot()
        let cache = root.appendingPathComponent("cache/antigravity-tokens.json")
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try db.insertStep(0, stepBlob(at: stepDate(-9 * 86400)))
        try db.insertStep(1, stepBlob(at: stepDate(-60)))
        try db.insertGeneration(1, generationBlob(responseID: "resp-old", lastStepIndex: 0))
        try db.insertGeneration(2, generationBlob(responseID: "resp-new", lastStepIndex: 1, output: 1))
        let scanner = scanner(root, cache: cache)
        let wide = try await scanner.scan(retainSince: Date().addingTimeInterval(-10 * 86400))
        XCTAssertEqual(wide.count, 2)
        let narrow = try await scanner.scan(retainSince: since)
        XCTAssertEqual(narrow.count, 1)

        try FileManager.default.removeItem(at: db.url)
        let other = try FixtureDB(root.appendingPathComponent("d.db"))
        try other.insertStep(0, stepBlob(at: stepDate(-30)))
        try other.insertGeneration(1, generationBlob(responseID: "resp-d", lastStepIndex: 0))
        let records = try await scanner.scan(retainSince: since)
        XCTAssertEqual(records.compactMap(\.sessionId).sorted(), ["c", "d"])
        let text = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertFalse(text.contains("/c.db"))
        XCTAssertTrue(text.contains("/d.db"))
    }

    func testOnlyDatabasesDirectlyUnderTheRootsCount() async throws {
        let root = try tempConversationRoot()
        let nested = try FixtureDB(root.appendingPathComponent("sub/nested.db"))
        try nested.insertStep(0, stepBlob(at: stepDate(-30)))
        try nested.insertGeneration(1, generationBlob(lastStepIndex: 0))
        let journal = root.appendingPathComponent("notes.txt")
        try "not a database".write(to: journal, atomically: true, encoding: .utf8)
        let broken = try FixtureDB(root.appendingPathComponent("broken.db"))
        try broken.exec("DROP TABLE gen_metadata")
        let none = try await scanner(root).scan(retainSince: since)
        XCTAssertEqual(none.count, 0)

        // A second root fills in, and one of the two roots missing is fine.
        let cli = try tempConversationRoot()
        let db = try FixtureDB(cli.appendingPathComponent("c.db"))
        try db.insertStep(0, stepBlob(at: stepDate(-30)))
        try db.insertGeneration(1, generationBlob(lastStepIndex: 0))
        let both = AntigravityTokenScanner(roots: [root.appendingPathComponent("missing"), cli], cacheURL: nil)
        let one = try await both.scan(retainSince: since)
        XCTAssertEqual(one.count, 1)
    }

    func testMissingRootsThrow() async throws {
        let root = try tempConversationRoot().appendingPathComponent("nope")
        do {
            _ = try await scanner(root).scan(retainSince: since)
            XCTFail("expected throw")
        } catch let e as AntigravityScanError {
            XCTAssertEqual(e, .missingRoot(root.path))
            XCTAssertTrue(e.localizedDescription.hasPrefix("No Antigravity conversations at "))
        }
    }
}

// MARK: - Store

final class AntigravityTokenStoreTests: XCTestCase {
    @MainActor
    func testRefreshPopulatesAndReportsMissingRoot() async throws {
        let root = try tempConversationRoot()
        let db = try FixtureDB(root.appendingPathComponent("c.db"))
        try db.insertStep(0, stepBlob(at: stepDate(-30)))
        try db.insertGeneration(1, generationBlob(lastStepIndex: 0))
        try db.insertGeneration(2, generationBlob(responseID: "resp-2", lastStepIndex: 0, output: 1))
        let store = AntigravityTokenStore()
        store.scanner = AntigravityTokenScanner(roots: [root], cacheURL: nil)
        XCTAssertEqual(store.product, .antigravity)
        XCTAssertNil(store.lastScanned)

        await store.refresh(reason: "test")
        XCTAssertEqual(store.records.count, 2)
        XCTAssertNotNil(store.lastScanned)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.totals(since: .distantPast).tokens, 2381)
        XCTAssertEqual(store.totals(since: .distantFuture).tokens, 0)
        XCTAssertEqual(store.costReport().today.tokens, 2381)
        XCTAssertEqual(store.costReport().models.map(\.model), ["gemini-3.8-flash"])

        store.scanner = AntigravityTokenScanner(roots: [root.appendingPathComponent("missing")], cacheURL: nil)
        await store.refresh(reason: "test")
        XCTAssertTrue(store.error!.hasPrefix("No Antigravity conversations at "))
        XCTAssertEqual(store.records.count, 2)
    }
}

// MARK: - Pricing and names

final class GeminiPricingTests: XCTestCase {
    func testPrefixesAndAliases() {
        XCTAssertEqual(TokenPricing.rate(for: "gemini-3.8-flash")?.input, 0.75)
        XCTAssertEqual(TokenPricing.rate(for: "gemini-3.8-flash-high")?.output, 3.75)
        XCTAssertEqual(TokenPricing.rate(for: "gemini-3.1-pro-low")?.output, 12)
        // The longest prefix wins, so Flash-Lite is not priced as Flash.
        XCTAssertEqual(TokenPricing.rate(for: "gemini-3.5-flash-lite")?.input, 0.3)
        XCTAssertEqual(TokenPricing.rate(for: "gemini-3.5-flash")?.input, 1.5)
        XCTAssertEqual(TokenPricing.rate(for: "gemini-2.5-flash-lite-preview")?.output, 0.4)
        XCTAssertEqual(TokenPricing.rate(for: "gemini-pro-default")?.input, 2)
        XCTAssertEqual(TokenPricing.rate(for: "gemini-pro-agent")?.input, 2)
        XCTAssertNil(TokenPricing.rate(for: "gemini-3.8-flashy"))
        XCTAssertNil(TokenPricing.rate(for: "MODEL_PLACEHOLDER_M36"))
        XCTAssertNil(TokenPricing.rate(for: "unknown"))
    }

    func testAntigravityRecordCost() throws {
        let r = TokenRecord(timestamp: Date(), model: "gemini-3.8-flash", input: 1_000_000, output: 100_000,
                            cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 2_000_000)
        // 1M * 0.75 + 0.1M * 3.75 + 2M * 0.075
        let expected: Double = 0.75 + 0.375 + 0.15
        XCTAssertEqual(try XCTUnwrap(TokenPricing.cost(r)), expected, accuracy: 1e-9)
    }

    func testGeminiModelNames() {
        XCTAssertEqual(TokenText.modelName("gemini-3.8-flash"), "Gemini 3.8 Flash")
        XCTAssertEqual(TokenText.modelName("gemini-3.1-pro-low"), "Gemini 3.1 Pro Low")
        XCTAssertEqual(TokenText.modelName("gemini-pro-default"), "Gemini Pro Default")
        XCTAssertEqual(TokenText.modelName("MODEL_PLACEHOLDER_M36"), "MODEL_PLACEHOLDER_M36")
    }
}
