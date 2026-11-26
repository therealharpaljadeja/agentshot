import Foundation
import CoreGraphics

public struct StitchSummary: Sendable {
    public let image: CGImage
    public let frameCount: Int
    public let overlaps: [Int]
    public let confidence: [Double]
    public let warnings: [String]

    public init(image: CGImage, frameCount: Int, overlaps: [Int], confidence: [Double], warnings: [String]) {
        self.image = image
        self.frameCount = frameCount
        self.overlaps = overlaps
        self.confidence = confidence
        self.warnings = warnings
    }
}

struct RGBABitmap {
    let width: Int
    let height: Int
    /// Row-major RGBA bytes, row 0 is treated as the visual top row.
    var bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init?(image: CGImage) {
        guard let context = makeBitmapContext(width: image.width, height: image.height) else { return nil }
        // CGBitmapContext rows are top-to-bottom for a directly drawn image in this configuration.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        var output = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let source = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height)
        for row in 0..<image.height {
            let sourceOffset = row * context.bytesPerRow
            let outputOffset = row * image.width * 4
            for index in 0..<(image.width * 4) {
                output[outputOffset + index] = source[sourceOffset + index]
            }
        }
        self.init(width: image.width, height: image.height, bytes: output)
    }

    func makeImage() -> CGImage? {
        guard let context = makeBitmapContext(width: width, height: height), let data = context.data else { return nil }
        let destination = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for row in 0..<height {
            let sourceOffset = row * width * 4
            let destinationOffset = row * context.bytesPerRow
            for index in 0..<(width * 4) {
                destination[destinationOffset + index] = bytes[sourceOffset + index]
            }
        }
        return context.makeImage()
    }

    func sample(x: Int, visualTopRow y: Int) -> (UInt8, UInt8, UInt8) {
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}

public enum ScrollStitcher {
    public static func stitch(images: [CGImage]) throws -> StitchSummary {
        guard let bitmaps = images.first.flatMap({ RGBABitmap(image: $0) }), !images.isEmpty else {
            throw AgentshotError("nothing-to-stitch", "Scrolling capture session has no frames")
        }
        if images.count == 1 {
            guard let image = bitmaps.makeImage() else {
                throw AgentshotError("stitch-failed", "Could not reconstruct single frame")
            }
            return StitchSummary(image: image, frameCount: 1, overlaps: [], confidence: [], warnings: ["only-one-frame-captured"])
        }

        var allRows = bitmaps.bytes
        var outputHeight = bitmaps.height
        var overlaps: [Int] = []
        var confidence: [Double] = []
        var warnings: [String] = []
        var previous = bitmaps

        for image in images.dropFirst() {
            guard let next = RGBABitmap(image: image) else {
                throw AgentshotError("stitch-failed", "Could not decode frame pixels")
            }
            guard next.width == bitmaps.width, next.height == bitmaps.height else {
                throw AgentshotError("frame-size-mismatch", "All scrolling capture frames must have the same dimensions")
            }
            guard let match = findOverlap(previous: previous, next: next) else {
                warnings.append("could-not-find-overlap-for-one-frame; it was skipped")
                continue
            }
            overlaps.append(match.overlap)
            confidence.append(match.confidence)
            if match.confidence < 0.82 {
                warnings.append("low-overlap-confidence-\(String(format: "%.2f", match.confidence))")
            }
            if match.overlap == 0 {
                warnings.append("zero-overlap-detected; possible content gap")
            }

            let appendStart = match.overlap
            if appendStart < next.height {
                let rowSize = next.width * 4
                let start = appendStart * rowSize
                allRows.append(contentsOf: next.bytes[start..<(next.height * rowSize)])
                outputHeight += next.height - appendStart
            } else {
                warnings.append("duplicate-frame-skipped")
            }

            previous = next
        }

        let stitched = RGBABitmap(width: bitmaps.width, height: outputHeight, bytes: allRows)
        guard let result = stitched.makeImage() else {
            throw AgentshotError("stitch-failed", "Could not create stitched image")
        }
        return StitchSummary(image: result, frameCount: images.count, overlaps: overlaps, confidence: confidence, warnings: warnings)
    }

    private static func findOverlap(previous: RGBABitmap, next: RGBABitmap) -> (overlap: Int, confidence: Double)? {
        let width = min(previous.width, next.width)
        let height = min(previous.height, next.height)
        guard width > 8, height > 20 else { return nil }

        let minimum = 1
        let maximum = height
        let xStride = max(1, width / 72)
        var bestOverlap = minimum
        var bestError = Double.greatestFiniteMagnitude

        for overlap in minimum...maximum {
            let yStride = max(1, overlap / 80)
            var error = 0.0
            var samples = 0
            var y = 0
            while y < overlap {
                let previousY = previous.height - overlap + y
                var x = 0
                while x < width {
                    let a = previous.sample(x: x, visualTopRow: previousY)
                    let b = next.sample(x: x, visualTopRow: y)
                    error += Double(abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2))) / 765.0
                    samples += 1
                    x += xStride
                }
                y += yStride
            }
            let normalized = samples == 0 ? Double.greatestFiniteMagnitude : error / Double(samples)
            if normalized < bestError - 0.000001 {
                bestError = normalized
                bestOverlap = overlap
            } else if normalized <= bestError + 0.000001, overlap > bestOverlap {
                bestOverlap = overlap
            }
        }

        // Confidence is intentionally conservative. Exact matches are 1.0; noisy matches decay quickly.
        let confidence = max(0, min(1, 1 - bestError * 4))
        if confidence < 0.45 {
            return nil
        }
        return (bestOverlap, confidence)
    }
}
