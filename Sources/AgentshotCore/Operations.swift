import Foundation
import CoreGraphics

public enum AgentshotOperations {
    public static func captureFullscreen(out: URL, displayIndex: Int = 0) async throws -> [String: Any] {
        let result = try await CaptureService.fullscreen(displayIndex: displayIndex)
        var output = try CaptureService.write(result, to: out)
        output["capture"] = (output["capture"] as? [String: Any] ?? [:]).merging(["kind": "fullscreen"]) { _, new in new }
        return output
    }

    public static func captureArea(rect: CGRect, out: URL, displayIndex: Int = 0) async throws -> [String: Any] {
        let result = try await CaptureService.area(rect, displayIndex: displayIndex)
        var output = try CaptureService.write(result, to: out)
        output["capture"] = (output["capture"] as? [String: Any] ?? [:]).merging(["kind": "area"]) { _, new in new }
        return output
    }

    public static func annotate(input: URL, operationsJSON: Data, out: URL) throws -> [String: Any] {
        let image = try readCGImage(input)
        let result = try AnnotationRenderer.render(image: image, operationsJSON: operationsJSON)
        try writeCGImage(result.image, to: out)
        return [
            "ok": true,
            "artifacts": [imageArtifact(out, width: result.image.width, height: result.image.height)],
            "annotation": [
                "appliedOperations": result.appliedOperations,
                "counterCount": result.counterCount,
                "input": input.path
            ],
            "warnings": result.warnings
        ]
    }

    public static func ocr(input: URL) throws -> [String: Any] {
        let image = try readCGImage(input)
        let lines = try OCRService.recognize(image: image)
        var output = OCRService.json(lines: lines)
        output["input"] = input.path
        return output
    }

    public static func redact(input: URL, out: URL, method: String, regex: String?, rects: [CGRect]) throws -> [String: Any] {
        let image = try readCGImage(input)
        var allRects = rects
        var matches: [[String: Any]] = []
        var warnings: [String] = []
        if let regex {
            let lines = try OCRService.recognize(image: image)
            let result = try RedactionService.rectsMatchingRegex(regex, in: lines)
            allRects.append(contentsOf: result.rects)
            matches = result.matches
            if result.rects.isEmpty { warnings.append("regex-matched-no-ocr-lines") }
        }
        guard !allRects.isEmpty else {
            throw AgentshotError("nothing-to-redact", "Provide at least one --rect or a --regex that matches OCR text")
        }
        let rendered = try RedactionService.redact(image: image, rects: allRects, method: method)
        try writeCGImage(rendered.image, to: out)
        warnings.append(contentsOf: rendered.warnings)
        return [
            "ok": true,
            "artifacts": [imageArtifact(out, width: rendered.image.width, height: rendered.image.height)],
            "redaction": [
                "method": method,
                "regions": allRects.count,
                "regexMatches": matches
            ],
            "warnings": warnings
        ]
    }

    public static func beautify(input: URL, out: URL, options: BeautifyOptions) throws -> [String: Any] {
        let image = try readCGImage(input)
        let outputImage = try Beautifier.beautify(image: image, options: options)
        try writeCGImage(outputImage, to: out)
        return [
            "ok": true,
            "artifacts": [imageArtifact(out, width: outputImage.width, height: outputImage.height)],
            "beautify": [
                "padding": options.padding,
                "radius": options.radius,
                "shadowOpacity": options.shadowOpacity,
                "background": options.background
            ],
            "warnings": []
        ]
    }

    public static func scrollStart(rect: CGRect, displayIndex: Int, session requestedID: String?) throws -> [String: Any] {
        let id = try ScrollSessionStore.create(rect: rect, displayIndex: displayIndex, requestedID: requestedID)
        return [
            "ok": true,
            "scrollSession": [
                "id": id,
                "rect": ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height, "units": "screen-points-top-left"],
                "displayIndex": displayIndex,
                "state": "started"
            ],
            "warnings": []
        ]
    }

    public static func scrollFrame(session id: String) async throws -> [String: Any] {
        let rect = try ScrollSessionStore.rect(id: id)
        let displayIndex = try ScrollSessionStore.displayIndex(id: id)
        let capture = try await CaptureService.area(rect, displayIndex: displayIndex)
        let frame = try ScrollSessionStore.appendFrame(id: id, image: capture.image)
        return [
            "ok": true,
            "scrollSession": [
                "id": id,
                "frameIndex": frame.index,
                "framePath": frame.url.path,
                "frameCount": frame.index
            ],
            "warnings": []
        ]
    }

    public static func scrollFinish(session id: String, out: URL) throws -> [String: Any] {
        let urls = try ScrollSessionStore.frameURLs(id: id)
        guard !urls.isEmpty else {
            throw AgentshotError("nothing-to-stitch", "Scrolling capture session '\(id)' has no frames")
        }
        let images = try urls.map { try readCGImage($0) }
        let stitched = try ScrollStitcher.stitch(images: images)
        try writeCGImage(stitched.image, to: out)
        return [
            "ok": true,
            "artifacts": [imageArtifact(out, width: stitched.image.width, height: stitched.image.height)],
            "scrollSession": [
                "id": id,
                "frameCount": stitched.frameCount,
                "overlaps": stitched.overlaps,
                "confidence": stitched.confidence
            ],
            "warnings": stitched.warnings
        ]
    }
}
