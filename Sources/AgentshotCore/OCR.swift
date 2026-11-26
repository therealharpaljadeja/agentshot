import Foundation
import CoreGraphics
import Vision

public struct OCRLine: Sendable {
    public let text: String
    public let confidence: Float
    /// Rectangle in top-left image pixel coordinates.
    public let rect: CGRect

    public init(text: String, confidence: Float, rect: CGRect) {
        self.text = text
        self.confidence = confidence
        self.rect = rect
    }

    public var json: [String: Any] {
        [
            "text": text,
            "confidence": confidence,
            "rect": [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.width,
                "height": rect.height,
                "units": "image-pixels-top-left"
            ]
        ]
    }
}

public enum OCRService {
    public static func recognize(image: CGImage, languages: [String] = ["en-US"]) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let width = box.width * CGFloat(image.width)
            let height = box.height * CGFloat(image.height)
            let x = box.minX * CGFloat(image.width)
            let yTop = (1 - box.maxY) * CGFloat(image.height)
            return OCRLine(
                text: candidate.string,
                confidence: candidate.confidence,
                rect: CGRect(x: x, y: yTop, width: width, height: height).integral
            )
        }
    }

    public static func json(lines: [OCRLine]) -> [String: Any] {
        [
            "ok": true,
            "text": lines.map(\.text).joined(separator: "\n"),
            "lines": lines.map(\.json),
            "warnings": []
        ]
    }
}

public enum RedactionService {
    public static func redact(image: CGImage, rects: [CGRect], method: String) throws -> AnnotationRenderResult {
        let operations = AnnotationRenderer.redactionOperations(rects: rects, method: method)
        return try AnnotationRenderer.render(image: image, operations: operations)
    }

    public static func rectsMatchingRegex(_ pattern: String, in lines: [OCRLine], padding: CGFloat = 3) throws -> (rects: [CGRect], matches: [[String: Any]]) {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw AgentshotError("invalid-regex", "Could not compile regex: \(error.localizedDescription)")
        }

        var rects: [CGRect] = []
        var matches: [[String: Any]] = []
        for line in lines {
            let range = NSRange(line.text.startIndex..<line.text.endIndex, in: line.text)
            let found = regex.matches(in: line.text, range: range)
            if !found.isEmpty {
                let expanded = line.rect.insetBy(dx: -padding, dy: -padding).integral
                rects.append(expanded)
                matches.append([
                    "matchCount": found.count,
                    "rect": [
                        "x": expanded.origin.x,
                        "y": expanded.origin.y,
                        "width": expanded.width,
                        "height": expanded.height,
                        "units": "image-pixels-top-left"
                    ]
                ])
            }
        }
        return (rects, matches)
    }
}
