// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MCP
import CliprillCore

private struct ToolSpec {
    let name: String
    let description: String
    let properties: [String: JSONValue]
    let required: [String]
    let readOnly: Bool
    var tool: Tool {
        let schema = JSONValue.object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
        return Tool(name: name, description: description, inputSchema: try! JSONDecoder().decode(Value.self, from: schema.encoded()), annotations: .init(readOnlyHint: readOnly, destructiveHint: name == "queue_remove" || name == "queue_delete", idempotentHint: true, openWorldHint: false))
    }
}

@main
enum CliprillMCP {
    private static let string: JSONValue = .object(["type": .string("string"), "minLength": .integer(1)])
    private static let integer: JSONValue = .object(["type": .string("integer"), "minimum": .integer(0)])
    private static let items: JSONValue = .object([
        "type": .string("array"), "minItems": .integer(1), "maxItems": .integer(1000),
        "description": .string("FIFO order; duplicates are preserved. Use text for a new text item, or history_id to snapshot captured text or an image."),
        "items": .object([
            "type": .string("object"),
            "properties": .object(["text": .object(["type": .string("string")]), "history_id": string, "label": .object(["type": .string("string")])]),
            "oneOf": .array([.object(["required": .array([.string("text")])]), .object(["required": .array([.string("history_id")])])]),
            "additionalProperties": .bool(false)
        ])
    ])
    private static var specs: [ToolSpec] {
        let queue: [String: JSONValue] = ["queue_id": string]
        let write = queue.merging(["idempotency_key": string, "expected_revision": integer]) { $1 }
        func spec(_ name: String, _ description: String, _ properties: [String: JSONValue], _ required: [String], _ read: Bool = false) -> ToolSpec {
            ToolSpec(name: name, description: description, properties: properties, required: required, readOnly: read)
        }
        return [
            spec("queue_create", "Atomically create a paused FIFO queue of text and captured images. Array order is paste order. Does not type into an application.", ["title": string, "items": items, "idempotency_key": string], ["items", "idempotency_key"]),
            spec("queue_append", "Atomically append items. A retry with the same key and arguments returns the original result.", write.merging(["items": items]) { $1 }, ["queue_id", "items", "idempotency_key"]),
            spec("queue_list", "List saved queue metadata and the active queue ID without clipboard text. Works while the panel is closed.", [:], [], true),
            spec("queue_get", "Read queue state and up to 100 items per page. Follow next_offset for more; item_ids always lists the full order. Text is omitted unless include_content is true. Image items return kind and dimensions/size metadata, never binary image data. Dispatched means a paste key event was sent, not confirmed target receipt.", queue.merging(["include_content": .object(["type": .string("boolean"), "default": .bool(false)]), "offset": integer, "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(100)])]) { $1 }, ["queue_id"], true),
            spec("queue_reorder", "Reorder every remaining item by ID. Include each unconsumed ID exactly once; consumed prefix stays fixed.", write.merging(["item_ids": .object(["type": .string("array"), "items": string])]) { $1 }, ["queue_id", "item_ids", "expected_revision", "idempotency_key"]),
            spec("queue_remove", "Remove one remaining queue item; history is preserved.", write.merging(["item_id": string]) { $1 }, ["queue_id", "item_id", "expected_revision", "idempotency_key"]),
            spec("queue_delete", "Delete a saved queue. Clipboard history is preserved.", write, ["queue_id", "expected_revision", "idempotency_key"]),
            spec("queue_activate", "Activate a queue for ordinary Command-V, and prepare its head on the clipboard. Requires Accessibility permission. Does not paste by itself.", write, ["queue_id", "idempotency_key"]),
            spec("queue_pause", "Pause sequential paste and keep all remaining items.", write, ["queue_id", "idempotency_key"]),
            spec("queue_undo_last", "Restore the last dispatched item as next and pause. Does not undo text in the target app.", write, ["queue_id", "idempotency_key"]),
            spec("history_search", "Search local text and image history. Returns text or image metadata, source, timestamps and pagination. Use a returned id as history_id when creating or appending a queue; image pixels are never returned.", ["query": .object(["type": .string("string")]), "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(100)]), "offset": integer], [], true)
        ]
    }

    static func main() async {
        do {
            if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--call" {
                let raw = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "{}"
                let args = try JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8))
                let result = try await dispatch(name: CommandLine.arguments[2], arguments: args)
                print(String(decoding: try result.encoded(), as: UTF8.self)); return
            }
            let server = Server(name: "Cliprill", version: "0.1.0", capabilities: .init(tools: .init(listChanged: false)))
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: specs.map(\.tool)) }
            await server.withMethodHandler(CallTool.self) { params in
                do {
                    let args = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(params.arguments ?? [:]))
                    let result = try await dispatch(name: params.name, arguments: args)
                    let data = try result.encoded()
                    return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: Optional<Value>.some(try JSONDecoder().decode(Value.self, from: data)), isError: false)
                } catch {
                    let result = JSONValue.object(["code": .string((error as? CoreError)?.code ?? "internal_error"), "message": .string(error.localizedDescription)])
                    return .init(content: [.text(text: String(decoding: try result.encoded(), as: UTF8.self), annotations: nil, _meta: nil)], isError: true)
                }
            }
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            FileHandle.standardError.write(Data("Cliprill: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func dispatch(name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let spec = specs.first(where: { $0.name == name }) else { throw CoreError("unknown_method", "Unknown tool: \(name)") }
        guard spec.required.allSatisfy({ arguments[$0] != nil }), arguments.keys.allSatisfy({ spec.properties[$0] != nil }) else {
            throw CoreError("invalid_arguments", "Missing required fields or unexpected arguments for \(name).")
        }
        for (key, value) in arguments {
            let property = spec.properties[key]!
            let valid: Bool
            switch property["type"].string {
            case "string": valid = value.string != nil && (property["minLength"].int == nil || !value.string!.isEmpty)
            case "boolean": valid = value.bool != nil
            case "array": valid = value.array != nil
            case "integer": valid = value.int != nil && value.int! >= (property["minimum"].int ?? 0) && value.int! <= (property["maximum"].int ?? Int.max)
            default: valid = true
            }
            guard valid else { throw CoreError("invalid_arguments", "Invalid value for \(key).") }
        }
        let request = IPCRequest(method: name, arguments: arguments)
        do { return try IPCClient.send(request) }
        catch let error as CoreError where error.code == "app_unavailable" {
            guard ProcessInfo.processInfo.environment["CLIPRILL_NO_AUTOSTART"] != "1" else { throw error }
            try startApplication()
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if (try? IPCClient.send(IPCRequest(method: "queue_list"))) != nil { return try IPCClient.send(request) }
            }
            throw CoreError("app_unavailable", "Cliprill did not start within 5 seconds. Open Cliprill.app and retry.")
        }
    }
    private static func startApplication() throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let app = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app" else { throw CoreError("app_unavailable", "Run the helper embedded in Cliprill.app, or open the app before using a development build.") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", app.path, "--args", "--background", "--data-dir", CliprillPaths.dataDirectory.path]
        if ProcessInfo.processInfo.environment["CLIPRILL_NO_CAPTURE"] == "1" { process.arguments?.append("--no-capture") }
        process.standardOutput = FileHandle.standardError; process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CoreError("app_unavailable", "macOS could not launch Cliprill.") }
    }
}
