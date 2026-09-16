// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var int: Int? {
        if case .number(let v) = self, v.isFinite, v >= Double(Int.min), v < Double(Int.max), v.rounded() == v { return Int(v) }
        return nil
    }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public static func integer(_ value: Int) -> JSONValue { .number(Double(value)) }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct CoreError: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

public struct QueueItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String = UUID().uuidString
    public var text: String
    public var label: String
    public var image: ClipboardImage?
    public init(text: String, label: String = "", image: ClipboardImage? = nil) { self.text = text; self.label = label; self.image = image }
}
public enum QueueStatus: String, Codable, Sendable { case paused, active, completed }
public struct ClipQueue: Codable, Sendable, Identifiable, Equatable {
    public var id: String = UUID().uuidString
    public var title: String
    public var items: [QueueItem]
    public var cursor: Int = 0
    public var status: QueueStatus = .paused
    public var revision: Int = 1
    public var pauseReason: String? = nil
    public var createdAt: Date = Date()
    public var remaining: Int { items.count - cursor }
    public var next: QueueItem? { remaining > 0 ? items[cursor] : nil }
}
public struct HistoryItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String = UUID().uuidString
    public var text: String
    public var source: String
    public var copiedAt: Date = Date()
    public var image: ClipboardImage?
}
public struct CoreState: Codable, Sendable {
    public var schema: Int = 2
    public var queues: [ClipQueue] = []
    public var history: [HistoryItem] = []
    public var activeID: String? = nil
    public var activeQueue: ClipQueue? { queues.first { $0.id == activeID && $0.status == .active } }
    public init() {}
}
public struct PasteReservation: Sendable, Equatable {
    public let token: UUID
    public let queueID: String
    public let item: QueueItem
    public let revision: Int
}
public struct IPCRequest: Codable, Sendable {
    public var method: String
    public var arguments: [String: JSONValue]
    public init(method: String, arguments: [String: JSONValue] = [:]) { self.method = method; self.arguments = arguments }
}
public struct IPCResponse: Codable, Sendable {
    public var result: JSONValue?
    public var error: String?
    public var code: String?
    public init(result: JSONValue) { self.result = result }
    public init(error: Error) {
        self.error = error.localizedDescription
        code = (error as? CoreError)?.code ?? "internal_error"
    }
    public func get() throws -> JSONValue {
        if let error { throw CoreError(code ?? "internal_error", error) }
        return result ?? .null
    }
}

public enum CliprillPaths {
    public static var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["CLIPRILL_DATA_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cliprill", isDirectory: true)
    }
    public static func socketPath(in directory: URL) -> String { directory.appendingPathComponent("runtime/core.sock").path }
    public static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
