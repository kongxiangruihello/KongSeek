import Foundation

/// A minimal Model Context Protocol server over newline-delimited JSON-RPC 2.0
/// (the stdio transport), offering tools only. `ks mcp` uses it so Claude can
/// search the files KongSeek indexes. Spec: https://modelcontextprotocol.io
public final class MCPServer {
    public struct Tool {
        public var name: String
        public var description: String
        /// JSON Schema of the arguments object.
        public var inputSchema: [String: Any]
        /// Returns the text result; throw `ToolError` for a failure the model should see.
        public var run: ([String: Any]) throws -> String

        public init(name: String, description: String, inputSchema: [String: Any], run: @escaping ([String: Any]) throws -> String) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.run = run
        }
    }

    public struct ToolError: Error {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    /// Protocol revisions this server speaks; the client's choice is echoed when known,
    /// otherwise `defaultVersion` is offered (the client may then disconnect).
    public static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    public static let defaultVersion = "2025-06-18"

    let name: String
    let version: String
    let instructions: String?
    let tools: [Tool]

    public init(name: String, version: String, instructions: String? = nil, tools: [Tool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// Tells the client to fetch the tool list again (sent after an update brings new tools).
    public static let toolsChangedNotification = #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#

    /// Handles one line from the client; returns the response line, or nil for
    /// notifications (and blank lines).
    public func handle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            return encode(error: -32700, "Parse error", id: NSNull())
        }
        // Batches (2025-03-26 allowed them) are answered element by element.
        if let batch = object as? [Any] {
            let replies = batch.compactMap { $0 as? [String: Any] }.compactMap(reply(to:))
            guard !replies.isEmpty else { return nil }
            return serialize(replies)
        }
        guard let message = object as? [String: Any] else {
            return encode(error: -32600, "Invalid Request", id: NSNull())
        }
        return reply(to: message).map(serialize)
    }

    private func reply(to message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response from the client (we send no requests) or garbage.
            return id == nil ? nil : errorObject(-32600, "Invalid Request", id: id!)
        }
        guard let id else { return nil } // notification: initialized, cancelled …
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.defaultVersion
            var result: [String: Any] = [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": name, "version": self.version],
            ]
            if let instructions { result["instructions"] = instructions }
            return success(result, id: id)
        case "ping":
            return success([:], id: id)
        case "tools/list":
            return success(["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] as [String: Any] }], id: id)
        case "tools/call":
            guard let toolName = params["name"] as? String else { return errorObject(-32602, "Missing tool name", id: id) }
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                return errorObject(-32602, "Unknown tool: \(toolName)", id: id)
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try tool.run(arguments)
                return success(["content": [["type": "text", "text": text]], "isError": false], id: id)
            } catch let error as ToolError {
                return success(["content": [["type": "text", "text": error.message]], "isError": true], id: id)
            } catch {
                return success(["content": [["type": "text", "text": "\(error)"]], "isError": true], id: id)
            }
        default:
            return errorObject(-32601, "Method not found: \(method)", id: id)
        }
    }

    private func success(_ result: [String: Any], id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorObject(_ code: Int, _ message: String, id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]]
    }

    private func encode(error code: Int, _ message: String, id: Any) -> String {
        serialize(errorObject(code, message, id: id))
    }

    /// One line of JSON (JSONSerialization never emits raw newlines without .prettyPrinted).
    private func serialize(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
