import Foundation
import CoreGraphics

public enum ScrollSessionStore {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentshot", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public static func create(rect: CGRect, displayIndex: Int, requestedID: String?) throws -> String {
        let id = requestedID ?? UUID().uuidString.lowercased().prefix(8).description
        try validateSessionID(id)
        let url = sessionURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            throw AgentshotError("session-exists", "Scrolling capture session '\(id)' already exists")
        }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("frames", isDirectory: true), withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "id": id,
            "rect": [rect.origin.x, rect.origin.y, rect.width, rect.height],
            "rectUnits": "screen-points-top-left",
            "displayIndex": displayIndex,
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url.appendingPathComponent("session.json"))
        return id
    }

    public static func metadata(id: String) throws -> [String: Any] {
        try validateSessionID(id)
        let url = sessionURL(id).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentshotError("session-not-found", "Scrolling capture session '\(id)' was not found")
        }
        return object
    }

    public static func rect(id: String) throws -> CGRect {
        let metadata = try metadata(id: id)
        guard let values = metadata["rect"] as? [Double], values.count == 4 else {
            throw AgentshotError("session-invalid", "Scrolling capture session metadata is invalid")
        }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    public static func displayIndex(id: String) throws -> Int {
        let metadata = try metadata(id: id)
        return (metadata["displayIndex"] as? Int) ?? 0
    }

    public static func appendFrame(id: String, image: CGImage) throws -> (index: Int, url: URL) {
        try validateSessionID(id)
        let framesURL = sessionURL(id).appendingPathComponent("frames", isDirectory: true)
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw AgentshotError("session-not-found", "Scrolling capture session '\(id)' was not found")
        }
        let existing = try frameURLs(id: id)
        let index = existing.count + 1
        let url = framesURL.appendingPathComponent(String(format: "frame-%04d.png", index))
        try writeCGImage(image, to: url, format: .png)
        return (index, url)
    }

    public static func frameURLs(id: String) throws -> [URL] {
        try validateSessionID(id)
        let framesURL = sessionURL(id).appendingPathComponent("frames", isDirectory: true)
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw AgentshotError("session-not-found", "Scrolling capture session '\(id)' was not found")
        }
        return try FileManager.default.contentsOfDirectory(at: framesURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func sessionURL(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private static func validateSessionID(_ id: String) throws {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw AgentshotError("invalid-session-id", "Session IDs may only contain letters, numbers, '-' and '_'")
        }
    }
}
