import XCTest
@testable import KongSeekCore

final class MCPServerTests: XCTestCase {
    private func server() -> MCPServer {
        MCPServer(name: "kongseek", version: "0.11.0", instructions: "Search files.", tools: [
            MCPServer.Tool(name: "search_files", description: "Search", inputSchema: ["type": "object"]) { arguments in
                guard let query = arguments["query"] as? String, !query.isEmpty else { throw MCPServer.ToolError("query is required") }
                return "found: " + query
            },
        ])
    }

    private func object(_ line: String?) -> [String: Any] {
        guard let line, let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        XCTAssertFalse(line.contains("\n"), "one message per line")
        return value
    }

    func testHandshakeAndTools() {
        let server = server()
        let initialize = object(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#))
        let result = initialize["result"] as? [String: Any]
        XCTAssertEqual(initialize["id"] as? Int, 1)
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "kongseek")
        XCTAssertEqual(((result?["capabilities"] as? [String: Any])?["tools"] as? [String: Any])?["listChanged"] as? Bool, true)
        XCTAssertEqual(object(MCPServer.toolsChangedNotification)["method"] as? String, "notifications/tools/list_changed")
        XCTAssertEqual(result?["instructions"] as? String, "Search files.")

        let unknownVersion = object(server.handle(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual((unknownVersion["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.defaultVersion)
        XCTAssertEqual(unknownVersion["id"] as? String, "a")

        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "notifications get no reply")
        XCTAssertNil(server.handle("   "))

        let list = object(server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = (list["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["name"] as? String, "search_files")
        XCTAssertNotNil(tools?.first?["inputSchema"])

        let call = object(server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_files","arguments":{"query":"合同 ext:pdf"}}}"#))
        let callResult = call["result"] as? [String: Any]
        XCTAssertEqual(callResult?["isError"] as? Bool, false)
        XCTAssertEqual(((callResult?["content"] as? [[String: Any]])?.first)?["text"] as? String, "found: 合同 ext:pdf")

        let failed = object(server.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_files","arguments":{}}}"#))
        XCTAssertEqual((failed["result"] as? [String: Any])?["isError"] as? Bool, true)

        let ping = object(server.handle(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#))
        XCTAssertEqual((ping["result"] as? [String: Any])?.count, 0)
    }

    func testErrors() {
        let server = server()
        let parse = object(server.handle("{not json"))
        XCTAssertEqual((parse["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(parse["id"] is NSNull)
        let unknown = object(server.handle(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let badTool = object(server.handle(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"nope"}}"#))
        XCTAssertEqual((badTool["error"] as? [String: Any])?["code"] as? Int, -32602)
        let notObject = object(server.handle("[1]"))
        XCTAssertTrue(notObject.isEmpty, "a batch of non-objects gets no reply")
    }
}
