// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

public actor QueueCore {
    private let store: SQLiteStore
    private var state: CoreState
    private var reservation: PasteReservation?
    private var autoDeleteEmptyQueues: Bool
    public static let maxTextBytes = 262_144
    public static let maxBatchBytes = 2_000_000
    public static let maxImageStorageBytes = 256 * 1024 * 1024

    public init(directory: URL, autoDeleteEmptyQueues: Bool = true) throws {
        self.autoDeleteEmptyQueues = autoDeleteEmptyQueues
        store = try SQLiteStore(directory: directory)
        state = try store.load()
        state.schema = 3
        state.activeID = nil
        for index in state.queues.indices where state.queues[index].status == .active {
            state.queues[index].status = .paused
            state.queues[index].pauseReason = "app_restarted"
            state.queues[index].revision += 1
        }
        if autoDeleteEmptyQueues { state.queues.removeAll { $0.remaining == 0 } }
        try store.save(state)
    }
    /// Enabling also cleans existing empty queues; a reserved item is still remaining.
    public func setAutoDeleteEmptyQueues(_ enabled: Bool) throws {
        var next = state
        if enabled {
            next.queues.removeAll { $0.remaining == 0 }
            if let id = next.activeID, !next.queues.contains(where: { $0.id == id }) { next.activeID = nil }
        }
        if next.queues != state.queues { try store.save(next); state = next }
        autoDeleteEmptyQueues = enabled
    }
    public func snapshot() -> CoreState { state }
    private func fingerprint(_ request: IPCRequest) throws -> String {
        var args = request.arguments; args.removeValue(forKey: "idempotency_key")
        let bytes = try JSONValue.object(["method": .string(request.method), "arguments": .object(args)]).encoded()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public func cachedResponse(_ request: IPCRequest) throws -> JSONValue? {
        guard let key = request.arguments["idempotency_key"]?.string, !key.isEmpty else { return nil }
        return try store.receipt(key: key, fingerprint: fingerprint(request))
    }

    public func handle(_ request: IPCRequest) throws -> JSONValue {
        let a = request.arguments
        switch request.method {
        case "board_list", "board_get":
            return try BoardOperations.read(request, state: state)
        case "queue_list":
            return .object(["queues": .array(state.queues.map { q in
                var summary = describe(q, content: false).object!
                summary.removeValue(forKey: "items"); summary.removeValue(forKey: "item_ids")
                return .object(summary)
            }), "active_id": state.activeID.map(JSONValue.string) ?? .null])
        case "queue_get":
            let q = state.queues[try index(a)]
            var value = describe(q, content: a["include_content"]?.bool ?? false).object!
            let offset = max(0, min(q.items.count, a["offset"]?.int ?? 0))
            let limit = max(1, min(100, a["limit"]?.int ?? 100))
            var bytes = 0
            let page = Array(value["items"]!.array!.dropFirst(offset).prefix(limit).prefix { item in
                bytes += (try? item.encoded().count) ?? 2_000_001; return bytes <= 2_000_000
            })
            value["items"] = .array(page); value["items_offset"] = .integer(offset)
            value["next_offset"] = offset + page.count < q.items.count ? .integer(offset + page.count) : .null
            return .object(value)
        case "history_search":
            let query = a["query"]?.string ?? ""
            let offset = max(0, min(10_000, a["offset"]?.int ?? 0))
            let limit = max(1, min(100, a["limit"]?.int ?? 30))
            let found = state.history.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query) || ($0.image != nil && ["image", "图片"].contains(where: { $0.localizedCaseInsensitiveContains(query) })) }
            var bytes = 0
            let page = Array(found.dropFirst(offset).prefix(limit).prefix { item in bytes += (try? JSONEncoder().encode(item).count) ?? 2_000_001; return bytes <= 2_000_000 })
            return .object(["items": .array(page.map { item in
                var value: [String: JSONValue] = ["id": .string(item.id), "kind": .string(item.image == nil ? "text" : "image"), "source": .string(item.source), "copied_at": .string(ISO8601DateFormatter().string(from: item.copiedAt))]
                if let image = item.image { value["image"] = image.metadata } else { value["text"] = .string(item.text) }
                return .object(value)
            }), "total": .integer(found.count), "next_offset": offset + page.count < found.count ? .integer(offset + page.count) : .null])
        default: break
        }
        let writeMethods: Set<String> = ["queue_create", "queue_append", "queue_reorder", "queue_remove", "queue_delete", "queue_activate", "queue_pause", "queue_undo_last", "history_delete", "history_clear"]
        guard writeMethods.contains(request.method) || BoardOperations.writes.contains(request.method) else { throw CoreError("unknown_method", "Unknown operation: \(request.method)") }
        let key = a["idempotency_key"]?.string
        if a["idempotency_key"] != nil && (key == nil || key!.isEmpty || key!.utf8.count > 256) {
            throw CoreError("invalid_arguments", "idempotency_key must be a nonempty string of at most 256 bytes.")
        }
        let fingerprint = try fingerprint(request)
        if let key, let saved = try store.receipt(key: key, fingerprint: fingerprint) { return saved }
        guard reservation == nil else { throw CoreError("busy", "A paste is being dispatched. Retry after it finishes.") }
        var next = state
        let response: JSONValue
        if BoardOperations.writes.contains(request.method) {
            response = try BoardOperations.write(request, state: &next)
        } else if request.method == "queue_create" {
            guard next.queues.count < 100 else { throw CoreError("capacity", "Keep at most 100 queues. Delete an old queue first.") }
            let items = try parseItems(a)
            let title = a["title"]?.string ?? "Queue"
            guard title.utf8.count <= 256 else { throw CoreError("invalid_arguments", "Queue title is too long.") }
            let queue = ClipQueue(title: title.isEmpty ? "Queue" : title, items: items)
            next.queues.insert(queue, at: 0)
            response = describe(queue, content: false)
        } else if request.method == "history_clear" {
            next.history.removeAll(); response = .object(["cleared": .bool(true)])
        } else if request.method == "history_delete" {
            let id = try requiredString(a, "item_id")
            next.history.removeAll { $0.id == id }; response = .object(["deleted": .bool(true)])
        } else {
            let i = try index(a)
            var q = next.queues[i]
            if let revision = a["expected_revision"], revision.int != q.revision {
                throw CoreError("revision_conflict", "Queue changed. Read it again and retry with the current revision.")
            }
            switch request.method {
            case "queue_append":
                let items = try parseItems(a)
                guard q.items.count + items.count <= 1000 else { throw CoreError("capacity", "A queue can contain at most 1000 items.") }
                q.items.append(contentsOf: items)
                if q.status == .completed { q.status = .paused; q.pauseReason = nil }
            case "queue_reorder":
                guard a["expected_revision"]?.int != nil else { throw CoreError("invalid_arguments", "Reordering requires expected_revision.") }
                guard let values = a["item_ids"]?.array else { throw CoreError("invalid_arguments", "item_ids must be an ordered array.") }
                let ids = values.compactMap(\.string)
                let pending = Array(q.items.dropFirst(q.cursor))
                guard ids.count == values.count, ids.count == pending.count, Set(ids).count == ids.count, Set(ids) == Set(pending.map(\.id)) else {
                    throw CoreError("invalid_order", "Supply every remaining item ID exactly once.")
                }
                let lookup = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
                q.items = Array(q.items.prefix(q.cursor)) + ids.compactMap { lookup[$0] }
            case "queue_remove":
                guard a["expected_revision"]?.int != nil else { throw CoreError("invalid_arguments", "Removing an item requires expected_revision.") }
                let id = try requiredString(a, "item_id")
                guard let position = q.items.firstIndex(where: { $0.id == id }), position >= q.cursor else { throw CoreError("not_found", "Remaining item not found.") }
                q.items.remove(at: position)
                if q.remaining == 0 { q.status = .completed; if next.activeID == q.id { next.activeID = nil } }
            case "queue_activate":
                guard q.remaining > 0 else { throw CoreError("empty_queue", "This queue has no remaining items.") }
                for j in next.queues.indices where next.queues[j].id != q.id && next.queues[j].status == .active {
                    next.queues[j].status = .paused; next.queues[j].pauseReason = "switched_queue"; next.queues[j].revision += 1
                }
                q.status = .active; q.pauseReason = nil; next.activeID = q.id
            case "queue_pause":
                if q.remaining > 0 { q.status = .paused; q.pauseReason = a["reason"]?.string ?? "user" }
                if next.activeID == q.id { next.activeID = nil }
            case "queue_undo_last":
                guard q.cursor > 0 else { throw CoreError("nothing_to_undo", "No dispatched item to restore.") }
                q.cursor -= 1; q.status = .paused; q.pauseReason = "undo"
                if next.activeID == q.id { next.activeID = nil }
            case "queue_delete":
                next.queues.remove(at: i)
                if next.activeID == q.id { next.activeID = nil }
                response = .object(["queue_id": .string(q.id), "deleted": .bool(true)])
                try persist(next, key: key, fingerprint: fingerprint, response: response)
                return response
            default: throw CoreError("unknown_method", "Unknown write operation.")
            }
            q.revision += 1
            if autoDeleteEmptyQueues && q.remaining == 0 {
                next.queues.remove(at: i)
                if next.activeID == q.id { next.activeID = nil }
                var value = describe(q, content: false).object!
                value["deleted"] = .bool(true)
                response = .object(value)
            } else {
                next.queues[i] = q
                response = describe(q, content: false)
            }
        }
        guard next.queues.reduce(0, { $0 + $1.items.reduce(0) { $0 + $1.text.utf8.count } }) <= 8_000_000 else {
            throw CoreError("capacity", "Saved queues exceed 8 MB. Delete an old queue first.")
        }
        var images: [String: Int] = [:]
        for item in next.queues.flatMap(\.items) {
            if let image = item.image { images[image.id] = image.byteCount }
        }
        for item in next.boards.flatMap(\.items) {
            if let image = item.image { images[image.id] = image.byteCount }
        }
        guard images.values.reduce(0, +) <= Self.maxImageStorageBytes else {
            throw CoreError("capacity", "Saved queue and pinboard images exceed 256 MiB. Remove unused saved images first.")
        }
        try persist(next, key: key, fingerprint: fingerprint, response: response)
        return response
    }

    private func persist(_ next: CoreState, key: String?, fingerprint: String, response: JSONValue) throws {
        try store.save(next, receipt: key.map { ($0, fingerprint, response) }); state = next
    }
    private func requiredString(_ a: [String: JSONValue], _ name: String) throws -> String {
        guard let value = a[name]?.string, !value.isEmpty else { throw CoreError("invalid_arguments", "\(name) must be a nonempty string.") }; return value
    }
    private func index(_ a: [String: JSONValue]) throws -> Int {
        let id = try requiredString(a, "queue_id")
        guard let index = state.queues.firstIndex(where: { $0.id == id }) else { throw CoreError("not_found", "Queue not found.") }; return index
    }
    private func parseItems(_ a: [String: JSONValue]) throws -> [QueueItem] {
        guard let values = a["items"]?.array, !values.isEmpty, values.count <= 1000 else {
            throw CoreError("invalid_arguments", "items must contain between 1 and 1000 entries.")
        }
        let items = try values.map { value -> QueueItem in
            guard let object = value.object, object.keys.allSatisfy({ ["text", "label", "history_id"].contains($0) }),
                  object["label"] == nil || object["label"]?.string != nil,
                  (object["text"] != nil) != (object["history_id"] != nil) else {
                throw CoreError("invalid_arguments", "Supply either text or history_id, plus an optional string label.")
            }
            let label = value["label"].string ?? ""
            guard label.utf8.count <= 256 else { throw CoreError("invalid_arguments", "Item label is too long.") }
            if let historyID = object["history_id"] {
                guard let id = historyID.string, let item = state.history.first(where: { $0.id == id }) else {
                    throw CoreError("not_found", "History item no longer exists. Refresh history and try again.")
                }
                return QueueItem(text: item.text, label: label, image: item.image)
            }
            guard let text = value["text"].string, text.utf8.count <= Self.maxTextBytes else {
                throw CoreError("invalid_arguments", "Every text item needs at most 256 KiB.")
            }
            return QueueItem(text: text, label: label)
        }
        guard items.reduce(0, { $0 + $1.text.utf8.count }) <= Self.maxBatchBytes else { throw CoreError("capacity", "One batch can contain at most 2 MB of text.") }
        return items
    }
    private func describe(_ q: ClipQueue, content: Bool) -> JSONValue {
        .object([
            "queue_id": .string(q.id), "title": .string(q.title), "state": .string(q.status.rawValue),
            "revision": .integer(q.revision), "cursor": .integer(q.cursor), "remaining": .integer(q.remaining),
            "total": .integer(q.items.count), "pause_reason": q.pauseReason.map(JSONValue.string) ?? .null,
            "next_item_id": q.next.map { .string($0.id) } ?? .null,
            "item_ids": .array(q.items.map { .string($0.id) }),
            "items": .array(q.items.enumerated().map { offset, item in
                var value: [String: JSONValue] = ["id": .string(item.id), "label": .string(item.label), "position": .integer(offset + 1), "dispatched": .bool(offset < q.cursor)]
                value["kind"] = .string(item.image == nil ? "text" : "image")
                if let image = item.image { value["image"] = image.metadata }
                else if content { value["text"] = .string(item.text) }
                return .object(value)
            })
        ])
    }

    public func capture(text: String, source: String, capacity: Int = 500, retentionDays: Int = 30) throws {
        guard !text.isEmpty, text.utf8.count <= Self.maxTextBytes else { return }
        var next = state
        next.history.removeAll { $0.image == nil && $0.text == text }
        next.history.insert(HistoryItem(text: text, source: source), at: 0)
        trimHistory(&next, capacity: capacity, retentionDays: retentionDays)
        try store.save(next); state = next
    }
    public func capture(image: PreparedClipboardImage, source: String, capacity: Int = 500, retentionDays: Int = 30) throws {
        var next = state
        next.history.removeAll { $0.image?.id == image.image.id }
        next.history.insert(HistoryItem(text: "", source: source, image: image.image), at: 0)
        trimHistory(&next, capacity: capacity, retentionDays: retentionDays)
        try store.save(next, image: image); state = next
    }
    public func imageData(_ image: ClipboardImage, thumbnail: Bool = false) throws -> Data {
        try store.imageData(id: image.id, thumbnail: thumbnail)
    }
    public func pruneHistory(capacity: Int, retentionDays: Int) throws {
        var next = state; trimHistory(&next, capacity: capacity, retentionDays: retentionDays)
        if next.history != state.history { try store.save(next); state = next }
    }
    private func trimHistory(_ next: inout CoreState, capacity: Int, retentionDays: Int) {
        let cutoff = Date().addingTimeInterval(-Double(max(1, retentionDays)) * 86400)
        next.history = Array(next.history.filter { $0.copiedAt >= cutoff }.prefix(max(0, min(2000, capacity))))
        var textBytes = 0, imageBytes = 0
        next.history = next.history.filter { item in
            if let image = item.image {
                guard image.byteCount <= Self.maxImageStorageBytes - imageBytes else { return false }
                imageBytes += image.byteCount
            } else {
                guard item.text.utf8.count <= 8_000_000 - textBytes else { return false }
                textBytes += item.text.utf8.count
            }
            return true
        }
    }
    public func reserveNext() throws -> PasteReservation {
        guard reservation == nil else { throw CoreError("busy", "A paste is already being dispatched.") }
        guard let q = state.activeQueue, let item = q.next else { throw CoreError("inactive", "No active queue.") }
        let result = PasteReservation(token: UUID(), queueID: q.id, item: item, revision: q.revision)
        reservation = result; return result
    }
    public func cancel(_ token: UUID) { if reservation?.token == token { reservation = nil } }
    public func commit(_ token: UUID) throws {
        guard let r = reservation, r.token == token, let i = state.queues.firstIndex(where: { $0.id == r.queueID }), state.queues[i].revision == r.revision else { throw CoreError("invalid_reservation", "Paste reservation expired.") }
        var next = state
        next.queues[i].cursor += 1; next.queues[i].revision += 1
        if next.queues[i].remaining == 0 {
            next.activeID = nil
            if autoDeleteEmptyQueues { next.queues.remove(at: i) }
            else { next.queues[i].status = .completed }
        }
        do { try store.save(next); state = next; reservation = nil }
        catch { reservation = nil; throw error }
    }
}
