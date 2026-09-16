// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import ImageIO
@testable import CliprillCore

final class ImageQueueTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cliprill-images-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func fixture(red: CGFloat = 0.5) throws -> PreparedClipboardImage {
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.1, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let bytes = NSMutableData(), destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try PreparedClipboardImage(data: bytes as Data)
    }
    private func historyReference(_ core: QueueCore) async throws -> JSONValue {
        let state = await core.snapshot()
        return .object(["history_id": .string(try XCTUnwrap(state.history.first?.id))])
    }
    func testMixedQueueRetainsImageAfterHistoryClearRestartAndUndo() async throws {
        let image = try fixture(), core = try QueueCore(directory: directory)
        try await core.capture(image: image, source: "Screenshot")
        let reference = try await historyReference(core)
        let created = try await core.handle(IPCRequest(method: "queue_create", arguments: ["items": .array([
            .object(["text": .string("before")]), reference, reference, .object(["text": .string("after")])])]))
        let id = try XCTUnwrap(created["queue_id"].string)
        let items = try XCTUnwrap(created["items"].array)
        XCTAssertEqual(items.map { $0["kind"].string }, ["text", "image", "image", "text"])
        XCTAssertNotEqual(items[1]["id"], items[2]["id"])
        _ = try await core.handle(IPCRequest(method: "history_clear"))
        _ = try await core.handle(IPCRequest(method: "queue_activate", arguments: ["queue_id": .string(id)]))
        let text = try await core.reserveNext(); XCTAssertEqual(text.item.text, "before"); try await core.commit(text.token)
        let next = try await core.reserveNext(); XCTAssertEqual(next.item.image, image.image); try await core.commit(next.token)
        let recovered = try QueueCore(directory: directory)
        let recoveredState = await recovered.snapshot()
        XCTAssertEqual(recoveredState.queues[0].cursor, 2); XCTAssertEqual(recoveredState.queues[0].status, .paused)
        let bytes = try await recovered.imageData(image.image); XCTAssertEqual(bytes, image.png)
        let undo = try await recovered.handle(IPCRequest(method: "queue_undo_last", arguments: ["queue_id": .string(id)]))
        XCTAssertEqual(undo["cursor"].int, 1)
        _ = try await recovered.handle(IPCRequest(method: "queue_delete", arguments: ["queue_id": .string(id)]))
        do { _ = try await recovered.imageData(image.image); XCTFail("Unreferenced image should be collected") }
        catch { XCTAssertEqual((error as? CoreError)?.code, "image_missing") }
    }
    func testImageDeduplicationPruningAndMetadataStayIndependentOfText() async throws {
        let first = try fixture(), second = try fixture(red: 0.9), core = try QueueCore(directory: directory)
        try await core.capture(text: "caption", source: "Editor")
        try await core.capture(image: first, source: "First")
        try await core.capture(image: first, source: "Second")
        var state = await core.snapshot()
        XCTAssertEqual(state.history.count, 2); XCTAssertEqual(state.history[0].source, "Second")
        let metadata = try await core.handle(IPCRequest(method: "history_search", arguments: ["query": .string("image")]))
        XCTAssertEqual(metadata["total"].int, 1)
        XCTAssertEqual(metadata["items"].array?[0]["image"]["width"].int, 32)
        XCTAssertNil(metadata["items"].array?[0]["text"].string)
        try await core.capture(image: second, source: "Third", capacity: 1)
        state = await core.snapshot(); XCTAssertEqual(state.history.count, 1)
        do { _ = try await core.imageData(first.image); XCTFail("Pruned image should be collected") }
        catch { XCTAssertEqual((error as? CoreError)?.code, "image_missing") }
        let data = try await core.imageData(second.image); XCTAssertEqual(data, second.png)
        let thumb = try await core.imageData(second.image, thumbnail: true)
        XCTAssertNotNil(CGImageSourceCreateWithData(thumb as CFData, nil))
    }
    func testMixedAppendFailureDoesNotPartiallyEnqueueImage() async throws {
        let image = try fixture(), core = try QueueCore(directory: directory)
        try await core.capture(image: image, source: "Test")
        let reference = try await historyReference(core)
        let q = try await core.handle(IPCRequest(method: "queue_create", arguments: ["items": .array([.object(["text": .string("start")])])]))
        do {
            _ = try await core.handle(IPCRequest(method: "queue_append", arguments: ["queue_id": q["queue_id"], "items": .array([reference, .object(["history_id": .string("missing")])])]))
            XCTFail("Missing history reference must reject the entire batch")
        } catch { XCTAssertEqual((error as? CoreError)?.code, "not_found") }
        let state = await core.snapshot(); XCTAssertEqual(state.queues[0].items.count, 1)
    }
    func testLegacyTextDatabaseMigratesWithoutLosingHistoryOrQueue() async throws {
        var state = CoreState(); state.schema = 1
        state.history = [HistoryItem(text: "saved history", source: "Editor")]
        state.queues = [ClipQueue(title: "Legacy", items: [QueueItem(text: "A"), QueueItem(text: "B")])]
        try SQLiteStore(directory: directory).save(state)
        let core = try QueueCore(directory: directory), loaded = await core.snapshot()
        XCTAssertEqual(loaded.schema, 2); XCTAssertEqual(loaded.history[0].text, "saved history")
        XCTAssertEqual(loaded.queues[0].items.map(\.text), ["A", "B"])
        XCTAssertNil(loaded.history[0].image); XCTAssertNil(loaded.queues[0].items[0].image)
    }
    func testMalformedImageIsRejected() {
        XCTAssertThrowsError(try PreparedClipboardImage(data: Data("not an image".utf8))) {
            XCTAssertEqual(($0 as? CoreError)?.code, "invalid_image")
        }
    }
}
