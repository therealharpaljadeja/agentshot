import Foundation
import CoreGraphics
import ImageIO
import AppKit
import CryptoKit

public struct AgentshotError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public let recovery: String?

    public init(_ code: String, _ message: String, recovery: String? = nil) {
        self.code = code
        self.message = message
        self.recovery = recovery
    }

    public var description: String { message }

    public var json: [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let recovery { error["recovery"] = recovery }
        return ["ok": false, "error": error]
    }
}

public enum JSONOut {
    public static func string(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"json-encoding-failed\",\"message\":\"Could not encode result JSON\"}}"
        }
        return string
    }

    public static func print(_ object: [String: Any]) {
        Swift.print(string(object))
    }
}


public func sha256Hex(of fileURL: URL) -> String? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}



public func imageArtifact(_ url: URL, width: Int, height: Int, extra: [String: Any] = [:]) -> [String: Any] {
    var artifact: [String: Any] = [
        "kind": "image",
        "path": url.path,
        "width": width,
        "height": height,
        "units": "image-pixels"
    ]
    if let hash = sha256Hex(of: url) { artifact["sha256"] = hash }
    for (key, value) in extra { artifact[key] = value }
    return artifact
}

public func ensureParentDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
}

public enum ImageFormat: String, Sendable {
    case png
    case jpeg

    var utType: CFString {
        switch self {
        case .png: return "public.png" as CFString
        case .jpeg: return "public.jpeg" as CFString
        }
    }
}

public func inferImageFormat(_ url: URL) -> ImageFormat {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return .jpeg
    default: return .png
    }
}

public func writeCGImage(_ image: CGImage, to url: URL, format: ImageFormat? = nil, jpegQuality: CGFloat = 0.92) throws {
    try ensureParentDirectory(url)
    let selected = format ?? inferImageFormat(url)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, selected.utType, 1, nil) else {
        throw AgentshotError("image-write-failed", "Could not create image destination at \(url.path)")
    }
    let options: [CFString: Any] = selected == .jpeg ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] : [:]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw AgentshotError("image-write-failed", "Could not write image to \(url.path)")
    }
}

public func readCGImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw AgentshotError("image-read-failed", "Could not read image at \(url.path)")
    }
    return image
}

public func parseRect(_ string: String) throws -> CGRect {
    let parts = string.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4 else {
        throw AgentshotError("invalid-rect", "Expected rect as x,y,width,height", recovery: "Example: --rect 100,200,800,600")
    }
    guard parts[2] > 0, parts[3] > 0 else {
        throw AgentshotError("invalid-rect", "Rectangle width and height must be positive")
    }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}

public func parsePointArray(_ value: Any?) -> CGPoint? {
    guard let array = value as? [Any], array.count == 2,
          let x = number(array[0]), let y = number(array[1]) else { return nil }
    return CGPoint(x: x, y: y)
}

public func parseRectArray(_ value: Any?) -> CGRect? {
    guard let array = value as? [Any], array.count == 4,
          let x = number(array[0]), let y = number(array[1]),
          let width = number(array[2]), let height = number(array[3]) else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
}

public func number(_ value: Any) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

public func colorFromHex(_ string: String?, fallback: NSColor = .red) -> NSColor {
    guard var hex = string?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else { return fallback }
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return fallback }
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    if hex.count == 6 {
        red = CGFloat((value >> 16) & 0xff) / 255
        green = CGFloat((value >> 8) & 0xff) / 255
        blue = CGFloat(value & 0xff) / 255
        alpha = 1
    } else {
        red = CGFloat((value >> 24) & 0xff) / 255
        green = CGFloat((value >> 16) & 0xff) / 255
        blue = CGFloat((value >> 8) & 0xff) / 255
        alpha = CGFloat(value & 0xff) / 255
    }
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

public func cgColor(_ color: NSColor) -> CGColor {
    color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor
}

public func makeBitmapContext(width: Int, height: Int) -> CGContext? {
    guard width > 0, height > 0,
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

public func renderOpaqueCopy(_ image: CGImage, background: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)) -> CGImage? {
    guard let context = makeBitmapContext(width: image.width, height: image.height) else { return nil }
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
}
