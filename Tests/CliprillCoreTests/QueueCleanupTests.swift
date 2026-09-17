// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CliprillCore

final class QueueCleanupTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("cliprill-cleanup-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func create(_ core: QueueCore, _ texts: [String]) async throws -> String {
        let value = try await core.handle(IPCRequest(method: "queue_create", arguments: ["items": .array(texts.map { .object(["text": .string($0)]) })]))
        return try XCTUnwrap(value["queue_id"].string)
    }
    private func activate(_ core: QueueCore, _ id: String) async throws {
        _ = try await core.handle(IPCRequest(method: "queue_activate", arguments: ["queue_id": .string(id)]))
    }
    func testDefaultDeletesOnlyFinishedQueueAndPreservesOtherDataAcrossRestart() async throws {
        let core = try QueueCore(directory: directory)
        try await core.capture(text: "history", source: "Fixture")
        _ = try await core.handle(IPCRequest(method: "board_create", arguments: ["title": .string("Saved")]))
        let first = try await create(core, ["A", "B"]), other = try await create(core, ["C"])
        try await activate(core, first)
        let a = try await core.reserveNext(); try await core.commit(a.token)
        var state = await core.snapshot(); XCTAssertEqual(state.activeQueue?.remaining, 1)
        let b = try await core.reserveNext(); try await core.commit(b.token)
        state = await core.snapshot()
        XCTAssertNil(state.activeID); XCTAssertEqual(state.queues.map(\.id), [other])
        XCTAssertEqual(state.history[0].text, "history"); XCTAssertEqual(state.boards[0].title, "Saved")
        let restarted = try QueueCore(directory: directory)
        let saved = await restarted.snapshot(); XCTAssertEqual(saved.queues.map(\.id), [other]); XCTAssertNil(saved.activeID)
    }
    func testRemovingLastPendingItemDeletesAtomicallyAndRetryRemainsValid() async throws {
        let core = try QueueCore(directory: directory), id = try await create(core, ["A", "B"])
        try await activate(core, id)
        let first = try await core.reserveNext(); try await core.commit(first.token)
        let snapshot = await core.snapshot()
        let q = try XCTUnwrap(snapshot.activeQueue)
        let request = IPCRequest(method: "queue_remove", arguments: ["queue_id": .string(id), "item_id": .string(q.next!.id), "expected_revision": .integer(q.revision), "idempotency_key": .string("remove-last")])
        let result = try await core.handle(request)
        XCTAssertEqual(result["deleted"].bool, true)
        let state = await core.snapshot(); XCTAssertTrue(state.queues.isEmpty); XCTAssertNil(state.activeID)
        let restarted = try QueueCore(directory: directory)
        let retry = try await restarted.handle(request); XCTAssertEqual(retry, result)
        do { _ = try await restarted.handle(IPCRequest(method: "queue_get", arguments: ["queue_id": .string(id)])); XCTFail("Deleted queue must be absent") }
        catch { XCTAssertEqual((error as? CoreError)?.code, "not_found") }
    }
    func testOptOutRetainsUndoAndEnablingCleansOnlyEmptyQueuesDuringReservation() async throws {
        let core = try QueueCore(directory: directory)
        try await core.setAutoDeleteEmptyQueues(false)
        let completed = try await create(core, ["A"])
        try await activate(core, completed)
        let a = try await core.reserveNext(); try await core.commit(a.token)
        _ = try await core.handle(IPCRequest(method: "queue_undo_last", arguments: ["queue_id": .string(completed)]))
        var state = await core.snapshot(); XCTAssertEqual(state.queues[0].remaining, 1)
        try await activate(core, completed)
        let again = try await core.reserveNext(); try await core.commit(again.token)
        let active = try await create(core, ["B"])
        try await activate(core, active)
        let reserved = try await core.reserveNext()
        try await core.setAutoDeleteEmptyQueues(true)
        state = await core.snapshot(); XCTAssertEqual(state.queues.map(\.id), [active])
        try await core.commit(reserved.token)
        state = await core.snapshot(); XCTAssertTrue(state.queues.isEmpty)
    }
    func testStartupUsesChosenPolicyAndCancelledPasteNeverDeletesPendingItem() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let id = try await create(core, ["A"])
        try await activate(core, id)
        let cancelled = try await core.reserveNext(); await core.cancel(cancelled.token)
        let untouched = await core.snapshot(); XCTAssertEqual(untouched.activeQueue?.remaining, 1)
        let final = try await core.reserveNext(); try await core.commit(final.token)
        let retained = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let old = await retained.snapshot(); XCTAssertEqual(old.queues.count, 1)
        let cleaned = try QueueCore(directory: directory)
        let state = await cleaned.snapshot(); XCTAssertTrue(state.queues.isEmpty)
    }
}
