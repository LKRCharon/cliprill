// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum BoardColor: String, Codable, CaseIterable, Sendable {
    case teal, blue, purple, rose, orange, graphite
}
public struct PinnedItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String = UUID().uuidString
    public var text: String
    public var label: String
    public var image: ClipboardImage?
    public var sensitive: Bool
    public var pasteItem: HistoryItem { HistoryItem(text: text, source: label, image: image) }
    public init(text: String, label: String = "", image: ClipboardImage? = nil, sensitive: Bool = false) {
        self.text = text; self.label = label; self.image = image; self.sensitive = sensitive
    }
}
public struct Pinboard: Codable, Sendable, Identifiable, Equatable {
    public var id: String = UUID().uuidString
    public var title: String
    public var color: BoardColor
    public var items: [PinnedItem] = []
    public var revision: Int = 1
    public init(title: String, color: BoardColor = .teal) { self.title = title; self.color = color }
}

/// Pure state transitions; QueueCore commits the resulting snapshot and receipt atomically.
enum BoardOperations {
    static let writes: Set<String> = ["board_create", "board_update", "board_delete", "board_add", "board_edit_item", "board_remove", "board_reorder", "board_move"]
    static func index(_ a: [String: JSONValue], in state: CoreState) throws -> Int {
        guard let id = a["board_id"]?.string, let i = state.boards.firstIndex(where: { $0.id == id }) else {
            throw CoreError("not_found", "Pinboard not found.")
        }
        return i
    }
    static func describe(_ board: Pinboard) -> JSONValue {
        .object(["board_id": .string(board.id), "title": .string(board.title), "color": .string(board.color.rawValue),
                 "revision": .integer(board.revision), "count": .integer(board.items.count)])
    }
    static func read(_ request: IPCRequest, state: CoreState) throws -> JSONValue {
        let a = request.arguments
        if request.method == "board_list" { return .object(["boards": .array(state.boards.map(describe))]) }
        let board = state.boards[try index(a, in: state)]
        var result = describe(board).object!
        let offset = max(0, min(board.items.count, a["offset"]?.int ?? 0))
        let limit = max(1, min(100, a["limit"]?.int ?? 100))
        let content = a["include_content"]?.bool ?? false
        var page: [JSONValue] = [], bytes = 0
        for item in board.items.dropFirst(offset).prefix(limit) {
            var value: [String: JSONValue] = ["id": .string(item.id), "label": .string(item.label),
                "sensitive": .bool(item.sensitive), "kind": .string(item.image == nil ? "text" : "image")]
            if let image = item.image { value["image"] = image.metadata }
            else if content { value["text"] = .string(item.text) }
            let json = JSONValue.object(value)
            bytes += try json.encoded().count
            if bytes > QueueCore.maxBatchBytes { break }
            page.append(json)
        }
        result["items"] = .array(page)
        result["item_ids"] = .array(board.items.map { .string($0.id) })
        result["next_offset"] = offset + page.count < board.items.count ? .integer(offset + page.count) : .null
        return .object(result)
    }
    private static func string(_ a: [String: JSONValue], _ key: String, max: Int, empty: Bool = false) throws -> String {
        guard let value = a[key]?.string, value.utf8.count <= max, empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError("invalid_arguments", "Invalid \(key).")
        }
        return value
    }
    private static func color(_ a: [String: JSONValue]) throws -> BoardColor {
        guard let value = a["color"]?.string, let color = BoardColor(rawValue: value) else { throw CoreError("invalid_arguments", "Unknown board color.") }
        return color
    }
    private static func checkRevision(_ a: [String: JSONValue], _ board: Pinboard, key: String = "expected_revision") throws {
        guard let revision = a[key]?.int else { throw CoreError("invalid_arguments", "Pinboard edits require \(key).") }
        guard revision == board.revision else { throw CoreError("revision_conflict", "Pinboard changed. Refresh and try again.") }
    }
    static func write(_ request: IPCRequest, state: inout CoreState) throws -> JSONValue {
        let a = request.arguments
        if request.method == "board_create" {
            guard state.boards.count < 30 else { throw CoreError("capacity", "Keep at most 30 pinboards.") }
            let board = Pinboard(title: try string(a, "title", max: 256), color: try a["color"] == nil ? .teal : color(a))
            state.boards.append(board)
            return describe(board)
        }
        let i = try index(a, in: state)
        var board = state.boards[i]
        try checkRevision(a, board)
        if request.method == "board_delete" {
            state.boards.remove(at: i)
            return .object(["board_id": .string(board.id), "deleted": .bool(true)])
        }
        switch request.method {
        case "board_update":
            if a["title"] != nil { board.title = try string(a, "title", max: 256) }
            if a["color"] != nil { board.color = try color(a) }
        case "board_add":
            guard (a["text"] != nil) != (a["history_id"] != nil) else { throw CoreError("invalid_arguments", "Supply either text or history_id.") }
            let label = a["label"] == nil ? "" : try string(a, "label", max: 256, empty: true)
            if a["sensitive"] != nil && a["sensitive"]?.bool == nil { throw CoreError("invalid_arguments", "sensitive must be boolean.") }
            var item: PinnedItem
            if let id = a["history_id"]?.string {
                guard let source = state.history.first(where: { $0.id == id }) else { throw CoreError("not_found", "History item no longer exists.") }
                item = PinnedItem(text: source.text, label: label, image: source.image, sensitive: a["sensitive"]?.bool ?? false)
            } else {
                item = PinnedItem(text: try string(a, "text", max: QueueCore.maxTextBytes), label: label, sensitive: a["sensitive"]?.bool ?? false)
            }
            // A fixed item is an independent snapshot; deleting history never removes it.
            board.items.append(item)
        case "board_reorder":
            guard let values = a["item_ids"]?.array else { throw CoreError("invalid_order", "Supply all item IDs in the desired order.") }
            let ids = values.compactMap(\.string)
            guard ids.count == values.count, ids.count == board.items.count, Set(ids).count == ids.count, Set(ids) == Set(board.items.map(\.id)) else {
                throw CoreError("invalid_order", "Supply every pinboard item exactly once.")
            }
            let lookup = Dictionary(uniqueKeysWithValues: board.items.map { ($0.id, $0) })
            board.items = ids.compactMap { lookup[$0] }
        case "board_edit_item", "board_remove", "board_move":
            guard let id = a["item_id"]?.string, let j = board.items.firstIndex(where: { $0.id == id }) else { throw CoreError("not_found", "Pinned item not found.") }
            if request.method == "board_remove" { board.items.remove(at: j) }
            else if request.method == "board_move" {
                guard let target = a["destination_id"]?.string, let destination = state.boards.firstIndex(where: { $0.id == target }), destination != i else {
                    throw CoreError("invalid_arguments", "Choose a different pinboard.")
                }
                try checkRevision(a, state.boards[destination], key: "destination_revision")
                guard state.boards[destination].items.count < 500 else { throw CoreError("capacity", "A pinboard can hold at most 500 items.") }
                state.boards[destination].items.append(board.items.remove(at: j)); state.boards[destination].revision += 1
            } else {
                if a["label"] != nil { board.items[j].label = try string(a, "label", max: 256, empty: true) }
                if a["text"] != nil {
                    guard board.items[j].image == nil else { throw CoreError("invalid_arguments", "An image item cannot be edited as text.") }
                    board.items[j].text = try string(a, "text", max: QueueCore.maxTextBytes)
                }
                if let sensitive = a["sensitive"] {
                    guard let value = sensitive.bool else { throw CoreError("invalid_arguments", "sensitive must be boolean.") }
                    board.items[j].sensitive = value
                }
            }
        default: throw CoreError("unknown_method", "Unknown pinboard operation.")
        }
        guard board.items.count <= 500 else { throw CoreError("capacity", "A pinboard can hold at most 500 items.") }
        board.revision += 1; state.boards[i] = board
        guard state.boards.reduce(0, { $0 + $1.items.count }) <= 2000,
              state.boards.reduce(0, { $0 + $1.items.reduce(0, { $0 + $1.text.utf8.count + $1.label.utf8.count }) }) <= 8_000_000 else {
            throw CoreError("capacity", "Pinboards can hold up to 2,000 items and 8 MB of text.")
        }
        var result = describe(board).object!
        if request.method == "board_add" { result["item_id"] = .string(board.items.last!.id) }
        return .object(result)
    }
}
