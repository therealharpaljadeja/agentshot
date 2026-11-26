import Foundation

public final class MCPServer: @unchecked Sendable {
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput

    public init() {}

    public func run() async throws {
        var buffer = Data()
        while true {
            let chunk = input.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let message = MCPFraming.extract(from: &buffer) {
                if let response = await handle(message) {
                    write(response)
                }
            }
        }
    }

    private func write(_ object: [String: Any]) {
        guard var body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        body.append(0x0a)
        output.write(body)
    }

    private func handle(_ object: [String: Any]) async -> [String: Any]? {
        guard let method = object["method"] as? String else { return nil }
        let id = object["id"]

        if method == "notifications/initialized" || method.hasPrefix("notifications/") {
            return nil
        }

        do {
            switch method {
            case "initialize":
                return response(id: id, result: [
                    "protocolVersion": object["params"] is [String: Any] ? (((object["params"] as? [String: Any])?["protocolVersion"] as? String) ?? "2024-11-05") : "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "agentshot", "version": "0.1.0"]
                ])
            case "ping":
                return response(id: id, result: [:])
            case "tools/list":
                return response(id: id, result: ["tools": MCPToolCatalog.tools])
            case "tools/call":
                guard let params = object["params"] as? [String: Any],
                      let name = params["name"] as? String else {
                    throw AgentshotError("invalid-tool-call", "tools/call requires params.name")
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let result = try await callTool(name: name, arguments: arguments)
                let text = JSONOut.string(result)
                return response(id: id, result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false
                ])
            default:
                return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
            }
        } catch {
            let payload = (error as? AgentshotError)?.json ?? AgentshotError("internal-error", error.localizedDescription).json
            if method == "tools/call" {
                return response(id: id, result: [
                    "content": [["type": "text", "text": JSONOut.string(payload)]],
                    "isError": true
                ])
            }
            return errorResponse(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func response(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        func url(_ key: String) throws -> URL {
            guard let value = arguments[key] as? String, !value.isEmpty else {
                throw AgentshotError("missing-argument", "Tool '\(name)' requires '\(key)'")
            }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        func rect(_ key: String = "rect") throws -> CGRect {
            if let string = arguments[key] as? String { return try parseRect(string) }
            guard let array = arguments[key] as? [Double], array.count == 4 else {
                throw AgentshotError("missing-argument", "Tool '\(name)' requires '\(key)' as x,y,width,height")
            }
            guard array.allSatisfy(\.isFinite), array[2] > 0, array[3] > 0 else {
                throw AgentshotError("invalid-rect", "Rectangle values must be finite and width/height must be positive")
            }
            return CGRect(x: array[0], y: array[1], width: array[2], height: array[3])
        }

        switch name {
        case "doctor":
            return CaptureService.doctor()
        case "capture_fullscreen":
            return try await AgentshotOperations.captureFullscreen(out: try url("out"), displayIndex: arguments["displayIndex"] as? Int ?? 0)
        case "capture_area":
            return try await AgentshotOperations.captureArea(rect: try rect(), out: try url("out"), displayIndex: arguments["displayIndex"] as? Int ?? 0)
        case "annotate":
            guard let ops = arguments["ops"] as? [[String: Any]] else {
                throw AgentshotError("missing-argument", "annotate requires ops as a JSON array")
            }
            let data = try JSONSerialization.data(withJSONObject: ops)
            return try AgentshotOperations.annotate(input: try url("input"), operationsJSON: data, out: try url("out"))
        case "ocr":
            return try AgentshotOperations.ocr(input: try url("input"))
        case "redact":
            var rects: [CGRect] = []
            if let array = arguments["rects"] as? [[Double]] {
                rects = array.compactMap {
                    guard $0.count == 4, $0.allSatisfy(\.isFinite), $0[2] > 0, $0[3] > 0 else { return nil }
                    return CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3])
                }
            }
            return try AgentshotOperations.redact(
                input: try url("input"),
                out: try url("out"),
                method: arguments["method"] as? String ?? "blur",
                regex: arguments["regex"] as? String,
                rects: rects
            )
        case "beautify":
            let options = BeautifyOptions(
                padding: CGFloat((arguments["padding"] as? Double) ?? 64),
                radius: CGFloat((arguments["radius"] as? Double) ?? 24),
                shadowOpacity: CGFloat((arguments["shadowOpacity"] as? Double) ?? 0.25),
                shadowBlur: CGFloat((arguments["shadowBlur"] as? Double) ?? 30),
                background: arguments["background"] as? String ?? "#dceeff"
            )
            return try AgentshotOperations.beautify(input: try url("input"), out: try url("out"), options: options)
        case "scroll_capture_start":
            return try AgentshotOperations.scrollStart(rect: try rect(), displayIndex: arguments["displayIndex"] as? Int ?? 0, session: arguments["session"] as? String)
        case "scroll_capture_add_frame":
            guard let session = arguments["session"] as? String else {
                throw AgentshotError("missing-argument", "scroll_capture_add_frame requires session")
            }
            return try await AgentshotOperations.scrollFrame(session: session)
        case "scroll_capture_finish":
            guard let session = arguments["session"] as? String else {
                throw AgentshotError("missing-argument", "scroll_capture_finish requires session")
            }
            return try AgentshotOperations.scrollFinish(session: session, out: try url("out"))
        default:
            throw AgentshotError("unknown-tool", "Unknown MCP tool '\(name)'")
        }
    }
}

public enum MCPFraming {
    public static func extract(from buffer: inout Data) -> [String: Any]? {
        guard !buffer.isEmpty else { return nil }
        if startsWithContentLengthHeader(buffer) {
            return extractHeaderFrame(from: &buffer)
        }
        if couldBePartialContentLengthHeader(buffer) {
            return nil
        }
        return extractNewlineFrame(from: &buffer)
    }

    private static func startsWithContentLengthHeader(_ buffer: Data) -> Bool {
        String(data: buffer.prefix(15), encoding: .utf8)?.lowercased() == "content-length:"
    }

    private static func couldBePartialContentLengthHeader(_ buffer: Data) -> Bool {
        guard let prefix = String(data: buffer.prefix(15), encoding: .utf8)?.lowercased(), prefix.count < 15 else { return false }
        return "content-length:".hasPrefix(prefix)
    }

    private static func extractNewlineFrame(from buffer: inout Data) -> [String: Any]? {
        guard let newline = buffer.firstIndex(of: 0x0a) else { return nil }
        var body = buffer.subdata(in: 0..<newline)
        buffer.removeSubrange(0...newline)
        if body.last == 0x0d { body.removeLast() }
        guard !body.isEmpty else { return extract(from: &buffer) }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private static func extractHeaderFrame(from buffer: inout Data) -> [String: Any]? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        var contentLength: Int?
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        guard let length = contentLength else { return nil }
        let frameEnd = headerEnd.upperBound + length
        guard buffer.count >= frameEnd else { return nil }
        let body = buffer.subdata(in: headerEnd.upperBound..<frameEnd)
        buffer.removeSubrange(0..<frameEnd)
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

enum MCPToolCatalog {
    static var tools: [[String: Any]] { [
        tool("doctor", "Check agentshot permissions and environment", ["type": "object", "properties": [:]]),
        tool("capture_fullscreen", "Capture a full display", ["type": "object", "properties": ["out": ["type": "string"], "displayIndex": ["type": "integer"]], "required": ["out"]]),
        tool("capture_area", "Capture a rectangular screen area", ["type": "object", "properties": ["rect": rectSchema(), "out": ["type": "string"], "displayIndex": ["type": "integer"]], "required": ["rect", "out"]]),
        tool("annotate", "Annotate an image with rectangles, arrows, text, highlights, counters, and crop", ["type": "object", "properties": ["input": ["type": "string"], "ops": ["type": "array"], "out": ["type": "string"]], "required": ["input", "ops", "out"]]),
        tool("redact", "Redact explicit rectangles or OCR regex matches", ["type": "object", "properties": ["input": ["type": "string"], "regex": ["type": "string"], "rects": ["type": "array"], "method": ["type": "string"], "out": ["type": "string"]], "required": ["input", "out"]]),
        tool("ocr", "Recognize image text and return bounding boxes", ["type": "object", "properties": ["input": ["type": "string"]], "required": ["input"]]),
        tool("beautify", "Add padding, rounded corners, shadow, and a solid or gradient backdrop", ["type": "object", "properties": ["input": ["type": "string"], "out": ["type": "string"], "padding": ["type": "number"], "radius": ["type": "number"], "shadowOpacity": ["type": "number"], "shadowBlur": ["type": "number"], "background": ["type": "string"]], "required": ["input", "out"]]),
        tool("scroll_capture_start", "Start an agent-driven scrolling capture session", ["type": "object", "properties": ["rect": rectSchema(), "session": ["type": "string"], "displayIndex": ["type": "integer"]], "required": ["rect"]]),
        tool("scroll_capture_add_frame", "Capture one frame for an active scrolling capture session", ["type": "object", "properties": ["session": ["type": "string"]], "required": ["session"]]),
        tool("scroll_capture_finish", "Stitch frames and finish a scrolling capture session", ["type": "object", "properties": ["session": ["type": "string"], "out": ["type": "string"]], "required": ["session", "out"]])
    ]
    }

    private static func rectSchema() -> [String: Any] {
        ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4]
    }

    private static func tool(_ name: String, _ description: String, _ schema: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": schema]
    }
}
