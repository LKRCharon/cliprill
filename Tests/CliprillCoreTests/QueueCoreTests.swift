// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CliprillCore

final class QueueCoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        // Darwin sockaddr_un allows only 103 path bytes; the per-user temp root can exceed this.
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("cliprill-test-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { if let directory { try? FileManager.default.removeItem(at: directory) } }
    private func create(_ core: QueueCore, _ texts: [String], key: String? = nil) async throws -> String {
        var args: [String: JSONValue] = ["items": .array(texts.map { .object(["text": .string($0)]) }), "title": .string("Test")]
        if let key { args["idempotency_key"] = .string(key) }
        let result = try await core.handle(IPCRequest(method: "queue_create", arguments: args))
        return try XCTUnwrap(result["queue_id"].string)
    }
    private func call(_ core: QueueCore, _ method: String, _ id: String, _ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await core.handle(IPCRequest(method: method, arguments: extra.merging(["queue_id": .string(id)]) { $1 }))
    }
    private func expectCode(_ code: String, _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected \(code)") }
        catch { XCTAssertEqual((error as? CoreError)?.code, code) }
    }
    func testPromoteHistoryPreservesIdentityAndPersists() async throws {
        let core = try QueueCore(directory: directory)
        try await core.capture(text: "first", source: "original")
        let original = await core.snapshot().history[0]
        try await core.capture(text: "second", source: "other")
        try await core.promoteHistory(id: original.id)
        let reopened = try QueueCore(directory: directory)
        let history = await reopened.snapshot().history
        XCTAssertEqual(history.map(\.text), ["first", "second"])
        XCTAssertEqual(history[0].id, original.id)
        XCTAssertEqual(history[0].source, original.source)
        XCTAssertGreaterThanOrEqual(history[0].copiedAt, original.copiedAt)
        try await core.promoteHistory(id: "missing")
        let unchanged = await core.snapshot().history
        XCTAssertEqual(unchanged, history)
    }
    func testFIFOAndCompletedQueue() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let id = try await create(core, ["A", "B", "C"])
        _ = try await call(core, "queue_activate", id)
        for text in ["A", "B", "C"] {
            let reservation = try await core.reserveNext()
            XCTAssertEqual(reservation.item.text, text)
            try await core.commit(reservation.token)
        }
        let state = await core.snapshot()
        XCTAssertNil(state.activeID); XCTAssertEqual(state.queues[0].remaining, 0); XCTAssertEqual(state.queues[0].status, .completed)
        await expectCode("inactive") { _ = try await core.reserveNext() }
    }
    func testDuplicatesAndMultilineAreIndependentItems() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let texts = ["A", "A", "B\nC", ""]
        let id = try await create(core, texts)
        let snapshot = await core.snapshot()
        XCTAssertEqual(Set(snapshot.queues[0].items.map(\.id)).count, 4)
        _ = try await call(core, "queue_activate", id)
        for text in texts { let item = try await core.reserveNext(); XCTAssertEqual(item.item.text, text); try await core.commit(item.token) }
    }
    func testIdempotencySurvivesRestartAndConflicts() async throws {
        let first = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let id = try await create(first, ["A", "A", "B"], key: "create-1")
        _ = try await call(first, "queue_activate", id)
        let second = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let sameID = try await create(second, ["A", "A", "B"], key: "create-1")
        XCTAssertEqual(id, sameID)
        let snapshot = await second.snapshot()
        XCTAssertEqual(snapshot.queues.count, 1); XCTAssertEqual(snapshot.queues[0].status, .paused); XCTAssertNil(snapshot.activeID)
        await expectCode("idempotency_conflict") { _ = try await self.create(second, ["C"], key: "create-1") }
        let state = await second.snapshot(); XCTAssertEqual(state.queues[0].items.count, 3)
    }
    func testAppendAtomicAndRetryDoesNotDuplicate() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let id = try await create(core, ["first"])
        let args: [String: JSONValue] = ["items": .array([.object(["text": .string("A")]), .object(["text": .string("A")])]), "idempotency_key": .string("append-1")]
        async let one = call(core, "queue_append", id, args)
        async let two = call(core, "queue_append", id, args)
        let (a, b) = try await (one, two); XCTAssertEqual(a, b)
        await expectCode("invalid_arguments") {
            _ = try await self.call(core, "queue_append", id, ["items": .array([.object(["text": .string("good")]), .object(["label": .string("missing text")])])])
        }
        let state = await core.snapshot(); XCTAssertEqual(state.queues[0].items.map(\.text), ["first", "A", "A"])
    }
    func testReorderRequiresCompleteRemainingPermutationAndRevision() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let id = try await create(core, ["A", "B", "C"])
        _ = try await call(core, "queue_activate", id)
        let reservation = try await core.reserveNext(); try await core.commit(reservation.token)
        let state = await core.snapshot(); let q = state.queues[0]
        let order = Array(q.items.dropFirst().reversed().map { JSONValue.string($0.id) })
        await expectCode("revision_conflict") { _ = try await self.call(core, "queue_reorder", id, ["item_ids": .array(order), "expected_revision": .integer(1)]) }
        await expectCode("invalid_order") { _ = try await self.call(core, "queue_reorder", id, ["item_ids": .array([order[0], order[0]]), "expected_revision": .integer(q.revision)]) }
        _ = try await call(core, "queue_reorder", id, ["item_ids": .array(order), "expected_revision": .integer(q.revision)])
        let changed = await core.snapshot(); XCTAssertEqual(changed.queues[0].items.map(\.text), ["A", "C", "B"]); XCTAssertEqual(changed.queues[0].cursor, 1)
    }
    func testReservationBlocksMutationAndCancelDoesNotConsume() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false); let id = try await create(core, ["A", "B"])
        _ = try await call(core, "queue_activate", id)
        let first = try await core.reserveNext()
        await expectCode("busy") { _ = try await core.reserveNext() }
        await expectCode("busy") { _ = try await self.call(core, "queue_pause", id) }
        await expectCode("busy") { _ = try await self.create(core, ["C"]) }
        await core.cancel(first.token)
        let second = try await core.reserveNext(); XCTAssertEqual(second.item.id, first.item.id)
        await expectCode("invalid_reservation") { try await core.commit(first.token) }
        try await core.commit(second.token)
        await expectCode("invalid_reservation") { try await core.commit(second.token) }
        let state = await core.snapshot(); XCTAssertEqual(state.queues[0].cursor, 1)
    }
    func testPauseUndoAndRestartRecovery() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false); let id = try await create(core, ["A", "B"])
        _ = try await call(core, "queue_activate", id)
        let first = try await core.reserveNext(); try await core.commit(first.token)
        _ = try await call(core, "queue_pause", id, ["reason": .string("external_copy")])
        let paused = await core.snapshot(); XCTAssertEqual(paused.queues[0].next?.text, "B"); XCTAssertEqual(paused.queues[0].pauseReason, "external_copy")
        _ = try await call(core, "queue_undo_last", id)
        let undo = await core.snapshot(); XCTAssertEqual(undo.queues[0].next?.text, "A"); XCTAssertEqual(undo.queues[0].status, .paused)
        _ = try await call(core, "queue_activate", id)
        let recovered = try QueueCore(directory: directory, autoDeleteEmptyQueues: false); let state = await recovered.snapshot()
        XCTAssertNil(state.activeID); XCTAssertEqual(state.queues[0].status, .paused); XCTAssertEqual(state.queues[0].pauseReason, "app_restarted")
        XCTAssertEqual(state.queues[0].next?.text, "A")
    }
    func testHistoryCleanupDoesNotChangeQueueSnapshots() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false); let id = try await create(core, ["A", "A", "B"])
        try await core.capture(text: "A", source: "Test"); try await core.capture(text: "A", source: "Other")
        let captured = await core.snapshot(); XCTAssertEqual(captured.history.count, 1); XCTAssertEqual(captured.history[0].source, "Other")
        _ = try await core.handle(IPCRequest(method: "history_clear"))
        let after = await core.snapshot(); XCTAssertTrue(after.history.isEmpty); XCTAssertEqual(after.queues[0].items.map(\.text), ["A", "A", "B"])
        let metadata = try await call(core, "queue_get", id)
        XCTAssertTrue(metadata["items"].array!.allSatisfy { $0["text"] == .null })
        let full = try await call(core, "queue_get", id, ["include_content": .bool(true)])
        XCTAssertEqual(full["items"].array?.first?["text"].string, "A")
    }
    func testSwitchingQueuesPausesPreviousAndCompletedCanAppend() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let a = try await create(core, ["A"]); let b = try await create(core, ["B"])
        _ = try await call(core, "queue_activate", a); _ = try await call(core, "queue_activate", b)
        let state = await core.snapshot(); XCTAssertEqual(state.activeID, b); XCTAssertEqual(state.queues.first { $0.id == a }?.status, .paused)
        let r = try await core.reserveNext(); try await core.commit(r.token)
        _ = try await call(core, "queue_append", b, ["items": .array([.object(["text": .string("C")])])])
        let updated = await core.snapshot(); XCTAssertEqual(updated.queues[0].next?.text, "C"); XCTAssertEqual(updated.queues[0].status, .paused)
    }
    func testHistoryPagingAndCapacity() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        for text in ["alpha", "beta", "gamma"] { try await core.capture(text: text, source: "Test", capacity: 2) }
        let search = try await core.handle(IPCRequest(method: "history_search", arguments: ["query": .string("a"), "limit": .integer(1)]))
        XCTAssertEqual(search["total"].int, 2); XCTAssertEqual(search["next_offset"].int, 1)
        XCTAssertEqual(search["items"].array?[0]["text"].string, "gamma")
    }
    func testInstanceLockRejectsSecondOwner() throws {
        let first = try InstanceLock(directory: directory)
        XCTAssertThrowsError(try InstanceLock(directory: directory)) { XCTAssertEqual(($0 as? CoreError)?.code, "already_running") }
        withExtendedLifetime(first) {}
    }
    func testContentPagingBoundsEscapedJSONAndPreservesFullOrder() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let text = String(repeating: "\u{01}", count: 200_000)
        let id = try await create(core, [text, text, text])
        let first = try await call(core, "queue_get", id, ["include_content": .bool(true)])
        XCTAssertEqual(first["item_ids"].array?.count, 3)
        XCTAssertEqual(first["items"].array?.count, 1)
        XCTAssertEqual(first["next_offset"].int, 1)
        XCTAssertLessThan(try first.encoded().count, 4_000_000)
        let last = try await call(core, "queue_get", id, ["include_content": .bool(true), "offset": .integer(2)])
        XCTAssertEqual(last["items"].array?.first?["text"].string, text)
        XCTAssertEqual(last["next_offset"], .null)
    }
    func testCachedActivationDoesNotResumeRecoveredQueue() async throws {
        let first = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let id = try await create(first, ["A"])
        let request = IPCRequest(method: "queue_activate", arguments: ["queue_id": .string(id), "idempotency_key": .string("activation")])
        let original = try await first.handle(request)
        let restarted = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let cached = try await restarted.cachedResponse(request)
        XCTAssertEqual(original, cached)
        let state = await restarted.snapshot()
        XCTAssertEqual(state.queues[0].status, .paused)
        XCTAssertNil(state.activeID)
    }
    func testRemoveCannotDeleteConsumedItemsAndDeletePreservesHistory() async throws {
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let id = try await create(core, ["A", "B"])
        try await core.capture(text: "A", source: "Test")
        _ = try await call(core, "queue_activate", id)
        let item = try await core.reserveNext(); try await core.commit(item.token)
        let state = await core.snapshot(); let q = state.queues[0]
        await expectCode("not_found") { _ = try await self.call(core, "queue_remove", id, ["item_id": .string(item.item.id), "expected_revision": .integer(q.revision)]) }
        _ = try await call(core, "queue_delete", id, ["expected_revision": .integer(q.revision)])
        let deleted = await core.snapshot()
        XCTAssertTrue(deleted.queues.isEmpty); XCTAssertEqual(deleted.history.count, 1); XCTAssertNil(deleted.activeID)
    }
    func testSocketRoundTripWithoutUI() async throws {
        let lock = try InstanceLock(directory: directory)
        let core = try QueueCore(directory: directory, autoDeleteEmptyQueues: false)
        let server = try IPCServer(directory: directory)
        server.start { request in do { return IPCResponse(result: try await core.handle(request)) } catch { return IPCResponse(error: error) } }
        defer { server.stop(); withExtendedLifetime(lock) {} }
        let directory = self.directory!
        let result = try await Task.detached {
            try IPCClient.send(IPCRequest(method: "queue_create", arguments: ["items": .array([.object(["text": .string("A\nB")]), .object(["text": .string("A\nB")])]), "idempotency_key": .string("ipc-test")]), directory: directory)
        }.value
        XCTAssertEqual(result["remaining"].int, 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: CliprillPaths.socketPath(in: directory))
        XCTAssertEqual(permissions[.posixPermissions] as? Int, 0o600)
    }
}
