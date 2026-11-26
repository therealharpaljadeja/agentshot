import XCTest
import CoreGraphics
import ImageIO
@testable import AgentshotCore

final class AgentshotCoreTests: XCTestCase {
    func testParseRect() throws {
        let rect = try parseRect("10,20,300,400")
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 300, height: 400))
    }

    func testAnnotationRendererAddsCountersAndOperations() throws {
        let image = try XCTUnwrap(makeSolidImage(width: 240, height: 160, red: 240, green: 240, blue: 240))
        let operations: [[String: Any]] = [
            ["type": "rect", "rect": [10, 10, 80, 50], "stroke": "#ff0000", "strokeWidth": 3],
            ["type": "arrow", "from": [150, 100], "to": [95, 40], "stroke": "#ff0000"],
            ["type": "text", "at": [20, 100], "text": "Hello"],
            ["type": "highlight", "rect": [12, 14, 50, 15]],
            ["type": "counter", "at": [160, 40]],
            ["type": "counter", "at": [190, 70]]
        ]
        let result = try AnnotationRenderer.render(image: image, operations: operations)
        XCTAssertEqual(result.appliedOperations, 6)
        XCTAssertEqual(result.counterCount, 2)
        XCTAssertEqual(result.image.width, 240)
        XCTAssertEqual(result.image.height, 160)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testArrowShaftStopsAtArrowheadBase() throws {
        let geometry = arrowGeometry(
            from: CGPoint(x: 100, y: 50),
            to: CGPoint(x: 20, y: 50),
            strokeWidth: 8
        )
        XCTAssertEqual(geometry.shaftEnd.x, geometry.headBaseLeading.x, accuracy: 0.001)
        XCTAssertEqual(geometry.shaftEnd.x, geometry.headBaseTrailing.x, accuracy: 0.001)
        XCTAssertGreaterThan(geometry.shaftEnd.x, 20)
        XCTAssertLessThan(geometry.shaftEnd.x, 100)
        XCTAssertEqual(abs(geometry.headBaseLeading.y - geometry.headBaseTrailing.y), 24, accuracy: 0.001)
    }

    func testCropOperationChangesOutputSize() throws {
        let image = try XCTUnwrap(makeSolidImage(width: 200, height: 100, red: 255, green: 255, blue: 255))
        let result = try AnnotationRenderer.render(image: image, operations: [
            ["type": "crop", "rect": [20, 10, 100, 50]]
        ])
        XCTAssertEqual(result.image.width, 100)
        XCTAssertEqual(result.image.height, 50)
    }

    func testCropUsesTopLeftImageCoordinates() throws {
        let image = try XCTUnwrap(makeStripedFrame(width: 4, height: 4, startRow: 0))
        let result = try AnnotationRenderer.render(image: image, operations: [
            ["type": "crop", "rect": [0, 1, 4, 1]]
        ])
        let bitmap = try XCTUnwrap(RGBABitmap(image: result.image))
        XCTAssertEqual(bitmap.sample(x: 0, visualTopRow: 0).0, 9)
    }

    func testScrollStitcherFindsVerticalOverlap() throws {
        let width = 24
        let height = 40
        let shift = 15
        let first = try XCTUnwrap(makeStripedFrame(width: width, height: height, startRow: 0))
        let second = try XCTUnwrap(makeStripedFrame(width: width, height: height, startRow: shift))
        let result = try ScrollStitcher.stitch(images: [first, second])
        XCTAssertEqual(result.overlaps, [height - shift])
        XCTAssertEqual(result.image.width, width)
        XCTAssertEqual(result.image.height, height + shift)
        XCTAssertEqual(result.confidence.first ?? 0, 1, accuracy: 0.05)
    }

    func testMCPFrameExtraction() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.data(using: .utf8)!
        var frame = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8)!
        frame.append(body)
        let message = MCPFraming.extract(from: &frame)
        XCTAssertEqual(message?["method"] as? String, "ping")
        XCTAssertEqual(frame.count, 0)
    }

    func testRegexRedactionRectsUseOCRLines() throws {
        let line = OCRLine(text: "token sk-test-123", confidence: 1, rect: CGRect(x: 10, y: 20, width: 100, height: 20))
        let result = try RedactionService.rectsMatchingRegex("sk-[a-z0-9-]+", in: [line], padding: 3)
        XCTAssertEqual(result.rects.count, 1)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.rects[0].origin.x, 7)
        XCTAssertEqual(result.rects[0].origin.y, 17)
    }


    func testBitmapExtractionOrientation() throws {
        let image = try XCTUnwrap(makeStripedFrame(width: 4, height: 4, startRow: 0))
        let bitmap = try XCTUnwrap(RGBABitmap(image: image))
        XCTAssertEqual(bitmap.sample(x: 0, visualTopRow: 0).0, 0)
        XCTAssertEqual(bitmap.sample(x: 0, visualTopRow: 3).0, 27)
    }

    private func makeSolidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = red
            bytes[index + 1] = green
            bytes[index + 2] = blue
            bytes[index + 3] = 255
        }
        return makeRGBAImage(width: width, height: height, bytes: bytes)
    }

    /// Creates a frame whose visual rows encode an absolute row number. A scrolled frame can
    /// then be generated by starting at a different absolute row.
    private func makeStripedFrame(width: Int, height: Int, startRow: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let absolute = startRow + y
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((absolute * 9 + x) % 251)
                bytes[offset + 1] = UInt8((absolute * 17 + x * 3) % 239)
                bytes[offset + 2] = UInt8((absolute * 29 + x * 7) % 223)
                bytes[offset + 3] = 255
            }
        }
        return makeRGBAImage(width: width, height: height, bytes: bytes)
    }

    private func makeRGBAImage(width: Int, height: Int, bytes: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
