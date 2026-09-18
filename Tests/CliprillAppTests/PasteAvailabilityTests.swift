import XCTest
import AppKit
import CliprillCore
@testable import CliprillApp

final class PasteAvailabilityTests: XCTestCase {
    @MainActor
    func testSecureInputBlocksQueueButNotDirectPastePermission() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try QueueCore(directory: directory)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let coordinator = PasteCoordinator(core: core, noCapture: true,
            pasteboard: board,
            accessibilityAvailable: { true }, secureInputEnabled: { true })
        XCTAssertNoThrow(try coordinator.ensureDirectPastePermission())
        XCTAssertThrowsError(try coordinator.ensureTap()) {
            XCTAssertEqual(($0 as? CoreError)?.code, "secure_input")
        }
    }

    @MainActor
    func testHistoryPasteReachesTargetValidationDuringSecureInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try QueueCore(directory: directory)
        try await core.capture(text: "test", source: "test")
        let item = await core.snapshot().history[0]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let coordinator = PasteCoordinator(core: core, noCapture: true, pasteboard: board,
            accessibilityAvailable: { true }, secureInputEnabled: { true })
        do {
            try await coordinator.pasteHistory(item, target: nil)
            XCTFail("Missing target must fail")
        } catch {
            XCTAssertEqual((error as? CoreError)?.code, "target_changed")
        }
        XCTAssertNil(board.string(forType: .string))
        let history = await core.snapshot().history
        XCTAssertEqual(history, [item])
    }

    @MainActor
    func testDirectPasteStillRequiresAccessibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let coordinator = PasteCoordinator(core: try QueueCore(directory: directory), noCapture: true,
            pasteboard: board,
            accessibilityAvailable: { false }, secureInputEnabled: { true })
        XCTAssertThrowsError(try coordinator.ensureDirectPastePermission()) {
            XCTAssertEqual(($0 as? CoreError)?.code, "accessibility_required")
        }
    }

    @MainActor
    func testCopyWithoutPermissionPausesButDoesNotConsumeQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try QueueCore(directory: directory)
        let result = try await core.handle(IPCRequest(method: "queue_create", arguments: [
            "items": .array([.object(["text": .string("queued")])])
        ]))
        let id = try XCTUnwrap(result["queue_id"].string)
        _ = try await core.handle(IPCRequest(method: "queue_activate", arguments: ["queue_id": .string(id)]))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let coordinator = PasteCoordinator(core: core, noCapture: true, pasteboard: board,
            accessibilityAvailable: { false }, secureInputEnabled: { true })
        coordinator.update(await core.snapshot())
        defer { coordinator.stop() }
        try await coordinator.copyContent(text: "manual", image: nil)
        XCTAssertEqual(board.string(forType: .string), "manual")
        let state = await core.snapshot()
        XCTAssertNil(state.activeID)
        XCTAssertEqual(state.queues.first?.remaining, 1)
        XCTAssertEqual(state.queues.first?.cursor, 0)
        XCTAssertTrue(state.history.isEmpty)
    }
}
