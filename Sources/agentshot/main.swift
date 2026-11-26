import Foundation
import CoreGraphics
import AgentshotCore

struct ParsedArguments {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") {
                    options[key, default: []].append(arguments[index + 1])
                    index += 2
                } else {
                    flags.insert(key)
                    index += 1
                }
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    func value(_ key: String) -> String? { options[key]?.last }
    func values(_ key: String) -> [String] { options[key] ?? [] }
}

func requiredOut(_ parsed: ParsedArguments) throws -> URL {
    guard let out = parsed.value("out"), !out.isEmpty else {
        throw AgentshotError("missing-out", "Provide an explicit output path with --out")
    }
    return URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
}

func inputURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}

func parseRectValues(_ values: [String]) throws -> [CGRect] {
    try values.map { try parseRect($0) }
}

func readOperations(_ value: String?) throws -> Data {
    guard let value else {
        throw AgentshotError("missing-ops", "Provide annotation operations with --ops <file-or-json>")
    }
    let path = (value as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: path) {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
    guard let data = value.data(using: .utf8) else {
        throw AgentshotError("invalid-ops", "Could not read --ops as JSON or as a file path")
    }
    return data
}

func runCLI(arguments: [String]) async throws -> [String: Any]? {
    guard let command = arguments.first else {
        throw AgentshotError("missing-command", usage, recovery: "Run: agentshot help")
    }
    if command == "help" || command == "--help" || command == "-h" {
        return ["ok": true, "usage": usage]
    }

    let parsed = ParsedArguments(Array(arguments.dropFirst()))

    switch command {
    case "doctor":
        return CaptureService.doctor()

    case "capture":
        guard let mode = parsed.positional.first else {
            throw AgentshotError("missing-capture-mode", "Use capture fullscreen or capture area")
        }
        let out = try requiredOut(parsed)
        let displayIndex = Int(parsed.value("display") ?? "0") ?? 0
        switch mode {
        case "fullscreen":
            return try await AgentshotOperations.captureFullscreen(out: out, displayIndex: displayIndex)
        case "area":
            guard let rectValue = parsed.value("rect") else {
                throw AgentshotError("missing-rect", "Area capture requires --rect x,y,width,height")
            }
            return try await AgentshotOperations.captureArea(rect: parseRect(rectValue), out: out, displayIndex: displayIndex)
        default:
            throw AgentshotError("unknown-capture-mode", "Unknown capture mode '\(mode)'")
        }

    case "annotate":
        guard let input = parsed.positional.first else {
            throw AgentshotError("missing-input", "annotate requires an input image path")
        }
        let out = try requiredOut(parsed)
        return try AgentshotOperations.annotate(input: inputURL(input), operationsJSON: readOperations(parsed.value("ops")), out: out)

    case "ocr":
        guard let input = parsed.positional.first else {
            throw AgentshotError("missing-input", "ocr requires an input image path")
        }
        return try AgentshotOperations.ocr(input: inputURL(input))

    case "redact":
        guard let input = parsed.positional.first else {
            throw AgentshotError("missing-input", "redact requires an input image path")
        }
        let out = try requiredOut(parsed)
        let method = parsed.value("method") ?? "blur"
        return try AgentshotOperations.redact(
            input: inputURL(input),
            out: out,
            method: method,
            regex: parsed.value("regex"),
            rects: parseRectValues(parsed.values("rect"))
        )

    case "beautify":
        guard let input = parsed.positional.first else {
            throw AgentshotError("missing-input", "beautify requires an input image path")
        }
        let out = try requiredOut(parsed)
        let options = BeautifyOptions(
            padding: CGFloat(Double(parsed.value("padding") ?? "64") ?? 64),
            radius: CGFloat(Double(parsed.value("radius") ?? "24") ?? 24),
            shadowOpacity: CGFloat(Double(parsed.value("shadow") ?? "0.25") ?? 0.25),
            shadowBlur: CGFloat(Double(parsed.value("shadow-blur") ?? "30") ?? 30),
            background: parsed.value("background") ?? "#dceeff"
        )
        return try AgentshotOperations.beautify(input: inputURL(input), out: out, options: options)

    case "scrollcap":
        guard let action = parsed.positional.first else {
            throw AgentshotError("missing-scrollcap-action", "Use scrollcap start, frame, or finish")
        }
        switch action {
        case "start":
            guard let rectValue = parsed.value("rect") else {
                throw AgentshotError("missing-rect", "scrollcap start requires --rect x,y,width,height")
            }
            let displayIndex = Int(parsed.value("display") ?? "0") ?? 0
            return try AgentshotOperations.scrollStart(rect: parseRect(rectValue), displayIndex: displayIndex, session: parsed.value("session"))
        case "frame":
            guard let session = parsed.value("session") else {
                throw AgentshotError("missing-session", "scrollcap frame requires --session <id>")
            }
            return try await AgentshotOperations.scrollFrame(session: session)
        case "finish":
            guard let session = parsed.value("session") else {
                throw AgentshotError("missing-session", "scrollcap finish requires --session <id>")
            }
            return try AgentshotOperations.scrollFinish(session: session, out: try requiredOut(parsed))
        default:
            throw AgentshotError("unknown-scrollcap-action", "Unknown scrollcap action '\(action)'")
        }

    case "mcp":
        try await MCPServer().run()
        return nil

    default:
        throw AgentshotError("unknown-command", "Unknown command '\(command)'", recovery: "Run: agentshot help")
    }
}

let usage = """
agentshot — agent-first screenshot tooling

Commands:
  doctor
  capture fullscreen --out screen.png [--display 0]
  capture area --rect x,y,w,h --out area.png [--display 0]
  annotate input.png --ops ops.json --out annotated.png
  redact input.png [--regex pattern] [--rect x,y,w,h ...] [--method blur|pixelate|erase|solid] --out safe.png
  ocr input.png
  beautify input.png --out final.png [--padding 64] [--radius 24] [--shadow 0.25] [--background '#dceeff']
  scrollcap start --rect x,y,w,h [--session id]
  scrollcap frame --session id
  scrollcap finish --session id --out tall.png
  mcp

Coordinate inputs are top-left screen points or top-left image pixels as documented per command.
"""

func errorJSON(_ error: Error) -> [String: Any] {
    if let error = error as? AgentshotError { return error.json }
    return AgentshotError("internal-error", error.localizedDescription).json
}

do {
    if let result = try await runCLI(arguments: Array(CommandLine.arguments.dropFirst())) {
        JSONOut.print(result)
    }
} catch {
    JSONOut.print(errorJSON(error))
    exit(1)
}
