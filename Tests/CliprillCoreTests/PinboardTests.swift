// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CliprillCore

final class PinboardTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("cliprill-boards-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func create(_ core: QueueCore, title: String = "Work") async throws -> JSONValue {
        try await core.handle(IPCRequest(method: "board_create", arguments: ["title": .string(title), "color": .string("teal")]))
    }
    private func args(_ board: JSONValue, _ more: [String: JSONValue] = [:]) -> [String: JSONValue] {
        ["board_id": board["board_id"], "expected_revision": board["revision"]].merging(more) { $1 }
    }
    func testSnapshotSurvivesHistoryClearPruningAndRestart() async throws {
        let core = try QueueCore(directory: directory)
        try await core.capture(text: "internship\ncontribution", source: "Editor")
        let history = await core.snapshot().history[0]
        let board = try await create(core)
        _ = try await core.handle(IPCRequest(method: "board_add", arguments: args(board, ["history_id": .string(history.id), "label": .string("Impact")])))
        _ = try await core.handle(IPCRequest(method: "history_clear"))
        try await core.pruneHistory(capacity: 0, retentionDays: 1)
        let recovered = try QueueCore(directory: directory)
        let state = await recovered.snapshot()
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertEqual(state.boards[0].items[0].text, history.text)
        XCTAssertEqual(state.boards[0].items[0].pasteItem.text, history.text)
        XCTAssertEqual(state.boards[0].items.count, 1)
    }
    func testSensitiveMetadataIsRedactedAndContentNeedsExplicitOptIn() async throws {
        let core = try QueueCore(directory: directory), board = try await create(core)
        let added = try await core.handle(IPCRequest(method: "board_add", arguments: args(board, ["text": .string("test-id-123456789"), "label": .string("Identity"), "sensitive": .bool(true)])))
        let metadata = try await core.handle(IPCRequest(method: "board_get", arguments: args(added)))
        XCTAssertNil(metadata["items"].array?[0]["text"].string)
        XCTAssertEqual(metadata["items"].array?[0]["sensitive"].bool, true)
        let full = try await core.handle(IPCRequest(method: "board_get", arguments: args(added, ["include_content": .bool(true)])))
        XCTAssertEqual(full["items"].array?[0]["text"].string, "test-id-123456789")
    }
    func testRetryDoesNotDuplicateAndConflictingRetryFails() async throws {
        let core = try QueueCore(directory: directory), board = try await create(core)
        let request = IPCRequest(method: "board_add", arguments: args(board, ["text": .string("test@example.com"), "idempotency_key": .string("pin-once")]))
        let result = try await core.handle(request)
        let retried = try await core.handle(request)
        XCTAssertEqual(result, retried)
        let recovered = try QueueCore(directory: directory)
        let saved = try await recovered.handle(request)
        XCTAssertEqual(saved, result)
        do {
            _ = try await recovered.handle(IPCRequest(method: "board_add", arguments: args(board, ["text": .string("changed"), "idempotency_key": .string("pin-once")])))
            XCTFail("Conflicting retry")
        } catch { XCTAssertEqual((error as? CoreError)?.code, "idempotency_conflict") }
    }
    func testStaleEditMoveAndBadOrderLeaveBothBoardsIntact() async throws {
        let core = try QueueCore(directory: directory)
        let source = try await create(core), target = try await create(core, title: "Personal")
        let added = try await core.handle(IPCRequest(method: "board_add", arguments: args(source, ["text": .string("saved")])))
        do {
            _ = try await core.handle(IPCRequest(method: "board_move", arguments: args(added, ["item_id": added["item_id"], "destination_id": target["board_id"], "destination_revision": .integer(0)])))
            XCTFail("Stale destination")
        } catch { XCTAssertEqual((error as? CoreError)?.code, "revision_conflict") }
        do {
            _ = try await core.handle(IPCRequest(method: "board_reorder", arguments: args(added, ["item_ids": .array([])])))
            XCTFail("Incomplete order")
        } catch { XCTAssertEqual((error as? CoreError)?.code, "invalid_order") }
        let before = await core.snapshot()
        XCTAssertEqual(before.boards[0].items.count, 1); XCTAssertTrue(before.boards[1].items.isEmpty)
        _ = try await core.handle(IPCRequest(method: "board_move", arguments: args(added, ["item_id": added["item_id"], "destination_id": target["board_id"], "destination_revision": target["revision"]])))
        let after = await core.snapshot()
        XCTAssertTrue(after.boards[0].items.isEmpty); XCTAssertEqual(after.boards[1].items[0].text, "saved")
        XCTAssertEqual(after.boards[1].revision, 2)
    }
    func testRenameRecolorEditAndDeleteDoNotChangeQueues() async throws {
        let core = try QueueCore(directory: directory)
        _ = try await core.handle(IPCRequest(method: "queue_create", arguments: ["items": .array([.object(["text": .string("queue text")])])]))
        var board = try await create(core)
        board = try await core.handle(IPCRequest(method: "board_update", arguments: args(board, ["title": .string("Career"), "color": .string("rose")])))
        XCTAssertEqual(board["color"].string, "rose")
        board = try await core.handle(IPCRequest(method: "board_add", arguments: args(board, ["text": .string("original")])))
        board = try await core.handle(IPCRequest(method: "board_edit_item", arguments: args(board, ["item_id": board["item_id"], "label": .string("Project"), "text": .string("edited\nlong text"), "sensitive": .bool(true)])))
        let state = await core.snapshot()
        XCTAssertEqual(state.boards[0].items[0].text, "edited\nlong text")
        XCTAssertTrue(state.boards[0].items[0].sensitive)
        _ = try await core.handle(IPCRequest(method: "board_delete", arguments: args(board)))
        let after = await core.snapshot()
        XCTAssertTrue(after.boards.isEmpty); XCTAssertEqual(after.queues[0].items[0].text, "queue text")
    }
    func testInvalidFieldsAndOversizeTextDoNotMutateBoard() async throws {
        let core = try QueueCore(directory: directory), board = try await create(core)
        for extra: [String: JSONValue] in [["text": .string(String(repeating: "x", count: QueueCore.maxTextBytes + 1))], ["text": .string("a"), "history_id": .string("missing")], ["text": .string("a"), "sensitive": .string("yes")]] {
            do { _ = try await core.handle(IPCRequest(method: "board_add", arguments: args(board, extra))); XCTFail("Invalid input") }
            catch { XCTAssertEqual((error as? CoreError)?.code, "invalid_arguments") }
        }
        let state = await core.snapshot()
        XCTAssertTrue(state.boards[0].items.isEmpty); XCTAssertEqual(state.boards[0].revision, 1)
    }
    func testSchemaTwoWithoutBoardsMigratesAndPreservesHistory() async throws {
        let old = Data(#"{"schema":2,"queues":[],"history":[{"id":"old","text":"kept","source":"Editor","copiedAt":0}]}"#.utf8)
        let value = try JSONDecoder().decode(CoreState.self, from: old)
        XCTAssertTrue(value.boards.isEmpty)
        try SQLiteStore(directory: directory).save(value)
        let core = try QueueCore(directory: directory), state = await core.snapshot()
        XCTAssertEqual(state.schema, 3); XCTAssertEqual(state.history[0].text, "kept")
    }
    func testLargeBoardReadIsPagedBelowIPCEnvelope() async throws {
        let core = try QueueCore(directory: directory)
        var board = try await create(core)
        for _ in 0..<12 {
            board = try await core.handle(IPCRequest(method: "board_add", arguments: args(board, ["text": .string(String(repeating: "a", count: 200_000))])))
        }
        let page = try await core.handle(IPCRequest(method: "board_get", arguments: args(board, ["include_content": .bool(true)])))
        XCTAssertLessThan(try page.encoded().count, 2_010_000)
        XCTAssertNotNil(page["next_offset"].int)
    }
}
