import Foundation
import CoreGraphics
import CoreImage
import AppKit

public struct AnnotationRenderResult: Sendable {
    public let image: CGImage
    public let appliedOperations: Int
    public let counterCount: Int
    public let warnings: [String]

    public init(image: CGImage, appliedOperations: Int, counterCount: Int, warnings: [String]) {
        self.image = image
        self.appliedOperations = appliedOperations
        self.counterCount = counterCount
        self.warnings = warnings
    }
}


struct ArrowGeometry {
    let shaftEnd: CGPoint
    let headBaseLeading: CGPoint
    let headBaseTrailing: CGPoint
}

func arrowGeometry(from start: CGPoint, to end: CGPoint, strokeWidth: CGFloat) -> ArrowGeometry {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = max(1, hypot(dx, dy))
    let ux = dx / length
    let uy = dy / length
    let headLength = min(max(14, strokeWidth * 3), max(8, length * 0.8))
    let headAngle = CGFloat.pi / 6
    let baseDistance = headLength * cos(headAngle)
    let baseCenter = CGPoint(x: end.x - ux * baseDistance, y: end.y - uy * baseDistance)
    let shaftDistance = max(0, length - baseDistance)
    let shaftEnd = CGPoint(x: start.x + ux * shaftDistance, y: start.y + uy * shaftDistance)
    let halfWidth = headLength * sin(headAngle)
    let perpendicular = CGPoint(x: -uy, y: ux)
    return ArrowGeometry(
        shaftEnd: shaftEnd,
        headBaseLeading: CGPoint(x: baseCenter.x + perpendicular.x * halfWidth, y: baseCenter.y + perpendicular.y * halfWidth),
        headBaseTrailing: CGPoint(x: baseCenter.x - perpendicular.x * halfWidth, y: baseCenter.y - perpendicular.y * halfWidth)
    )
}

public enum AnnotationRenderer {
    public static func render(image input: CGImage, operationsJSON data: Data) throws -> AnnotationRenderResult {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let operations = object as? [[String: Any]] else {
            throw AgentshotError("invalid-ops", "Annotation operations must be a JSON array of objects")
        }
        return try render(image: input, operations: operations)
    }

    public static func render(image input: CGImage, operations: [[String: Any]]) throws -> AnnotationRenderResult {
        var warnings: [String] = []
        var image = input

        if let cropOperation = operations.first(where: { ($0["type"] as? String) == "crop" }),
           let cropRect = parseRectArray(cropOperation["rect"]) {
            let converted = cropRect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if converted.width > 0, converted.height > 0, let cropped = image.cropping(to: converted) {
                image = cropped
            } else {
                warnings.append("crop-operation-was-outside-image-and-was-ignored")
            }
        }

        let redactionOperations = operations.filter { ($0["type"] as? String) == "redact" }
        if !redactionOperations.isEmpty {
            image = try applyRedactions(to: image, operations: redactionOperations)
        }

        guard let context = makeBitmapContext(width: image.width, height: image.height) else {
            throw AgentshotError("render-failed", "Could not create annotation rendering context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var applied = 0
        var counter = 0
        let imageHeight = CGFloat(image.height)

        for operation in operations {
            guard let type = operation["type"] as? String else { continue }
            switch type {
            case "crop", "redact":
                continue

            case "rect":
                guard let rect = parseRectArray(operation["rect"]) else {
                    warnings.append("skipped-rect-with-invalid-rect")
                    continue
                }
                let cgRect = topLeftRectToCG(rect, imageHeight: imageHeight)
                let stroke = colorFromHex(operation["stroke"] as? String, fallback: .systemRed)
                let strokeWidth = CGFloat(number(operation["strokeWidth"]) ?? 4)
                if let fillHex = operation["fill"] as? String, fillHex.lowercased() != "none" {
                    context.setFillColor(cgColor(colorFromHex(fillHex, fallback: .clear)))
                    context.fill(cgRect)
                }
                context.setStrokeColor(cgColor(stroke))
                context.setLineWidth(strokeWidth)
                context.stroke(cgRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
                applied += 1

            case "highlight":
                guard let rect = parseRectArray(operation["rect"]) else {
                    warnings.append("skipped-highlight-with-invalid-rect")
                    continue
                }
                let color = colorFromHex(operation["color"] as? String, fallback: .systemYellow)
                let alpha = CGFloat(number(operation["opacity"]) ?? 0.45)
                context.setFillColor(cgColor(color.withAlphaComponent(alpha)))
                context.fill(topLeftRectToCG(rect, imageHeight: imageHeight))
                applied += 1

            case "arrow":
                guard let from = parsePointArray(operation["from"]), let to = parsePointArray(operation["to"]) else {
                    warnings.append("skipped-arrow-with-invalid-endpoints")
                    continue
                }
                let start = topLeftPointToCG(from, imageHeight: imageHeight)
                let end = topLeftPointToCG(to, imageHeight: imageHeight)
                let color = colorFromHex(operation["stroke"] as? String, fallback: .systemRed)
                let width = CGFloat(number(operation["strokeWidth"]) ?? 6)
                let geometry = arrowGeometry(from: start, to: end, strokeWidth: width)
                context.setStrokeColor(cgColor(color))
                context.setFillColor(cgColor(color))
                context.setLineWidth(width)
                context.setLineCap(.round)
                context.move(to: start)
                context.addLine(to: geometry.shaftEnd)
                context.strokePath()

                context.move(to: end)
                context.addLine(to: geometry.headBaseLeading)
                context.addLine(to: geometry.headBaseTrailing)
                context.closePath()
                context.fillPath()
                applied += 1

            case "text":
                guard let at = parsePointArray(operation["at"]), let text = operation["text"] as? String else {
                    warnings.append("skipped-text-with-invalid-position-or-text")
                    continue
                }
                drawTextLabel(text, at: at, operation: operation, context: context, imageHeight: imageHeight)
                applied += 1

            case "counter":
                guard let at = parsePointArray(operation["at"]) else {
                    warnings.append("skipped-counter-with-invalid-position")
                    continue
                }
                counter += 1
                drawCounter(value: counter, at: at, operation: operation, context: context, imageHeight: imageHeight)
                applied += 1

            default:
                warnings.append("unsupported-operation-\(type)")
            }
        }

        guard let output = context.makeImage() else {
            throw AgentshotError("render-failed", "Could not produce annotated image")
        }
        return AnnotationRenderResult(image: output, appliedOperations: applied, counterCount: counter, warnings: warnings)
    }

    public static func applyRedactions(to image: CGImage, operations: [[String: Any]]) throws -> CGImage {
        guard let context = makeBitmapContext(width: image.width, height: image.height) else {
            throw AgentshotError("render-failed", "Could not create redaction rendering context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for operation in operations {
            guard let topLeftRect = parseRectArray(operation["rect"]) else { continue }
            let method = (operation["method"] as? String ?? "blur").lowercased()
            drawRedaction(in: context, image: image, topLeftRect: topLeftRect.integral, method: method)
        }
        guard let output = context.makeImage() else {
            throw AgentshotError("render-failed", "Could not produce redacted image")
        }
        return output
    }

    public static func redactionOperations(rects: [CGRect], method: String) -> [[String: Any]] {
        rects.map { rect in
            [
                "type": "redact",
                "rect": [rect.origin.x, rect.origin.y, rect.width, rect.height],
                "method": method
            ]
        }
    }

    private static func drawRedaction(in context: CGContext, image: CGImage, topLeftRect: CGRect, method: String) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = topLeftRect.intersection(bounds).integral
        let drawRect = topLeftRectToCG(clipped, imageHeight: CGFloat(image.height)).integral
        guard clipped.width > 0, clipped.height > 0, let crop = image.cropping(to: clipped) else { return }

        switch method {
        case "pixelate", "pixelate-text":
            if let processed = pixelated(crop) {
                context.saveGState()
                context.interpolationQuality = .none
                context.draw(processed, in: drawRect)
                context.restoreGState()
            }
        case "erase", "erase-text", "inpaint":
            let color = averageColor(of: crop)
            context.setFillColor(color)
            context.fill(drawRect)
        case "solid", "mask", "black":
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(drawRect)
        default:
            if let processed = blurred(crop) {
                context.draw(processed, in: drawRect)
            } else if let processed = pixelated(crop) {
                context.draw(processed, in: drawRect)
            }
        }
    }

    private static func blurred(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let clamp = CIFilter(name: "CIAffineClamp", parameters: [kCIInputImageKey: input])?.outputImage,
              let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: clamp, "inputRadius": 14])?.outputImage else {
            return nil
        }
        let cropped = blur.cropped(to: input.extent)
        return CIContext().createCGImage(cropped, from: input.extent)
    }

    private static func pixelated(_ image: CGImage) -> CGImage? {
        let factor = max(6, min(24, max(image.width, image.height) / 10))
        let smallWidth = max(1, image.width / factor)
        let smallHeight = max(1, image.height / factor)
        guard let smallContext = makeBitmapContext(width: smallWidth, height: smallHeight) else { return nil }
        smallContext.interpolationQuality = .none
        smallContext.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let small = smallContext.makeImage(),
              let largeContext = makeBitmapContext(width: image.width, height: image.height) else { return nil }
        largeContext.interpolationQuality = .none
        largeContext.draw(small, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return largeContext.makeImage()
    }

    private static func averageColor(of image: CGImage) -> CGColor {
        guard let context = makeBitmapContext(width: 1, height: 1),
              let data = context.data else {
            return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return CGColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
    }

    private static func drawTextLabel(_ text: String, at topLeft: CGPoint, operation: [String: Any], context: CGContext, imageHeight: CGFloat) {
        let fontSize = CGFloat(number(operation["fontSize"]) ?? 18)
        let foreground = colorFromHex(operation["foreground"] as? String, fallback: .white)
        let background = colorFromHex(operation["background"] as? String, fallback: .systemRed)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let padding = max(6, fontSize * 0.35)
        let labelWidth = textSize.width + padding * 2
        let labelHeight = textSize.height + padding * 1.4
        let topLeftRect = CGRect(x: topLeft.x, y: topLeft.y, width: labelWidth, height: labelHeight)
        let cgRect = topLeftRectToCG(topLeftRect, imageHeight: imageHeight)

        context.setFillColor(cgColor(background))
        let path = CGPath(roundedRect: cgRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        context.addPath(path)
        context.fillPath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(at: CGPoint(x: cgRect.minX + padding, y: cgRect.minY + padding * 0.65))
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCounter(value: Int, at topLeft: CGPoint, operation: [String: Any], context: CGContext, imageHeight: CGFloat) {
        let radius = CGFloat(number(operation["radius"]) ?? 17)
        let center = topLeftPointToCG(topLeft, imageHeight: imageHeight)
        let background = colorFromHex(operation["background"] as? String, fallback: .systemRed)
        let foreground = colorFromHex(operation["foreground"] as? String, fallback: .white)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(cgColor(background))
        context.fillEllipse(in: rect)

        let font = NSFont.systemFont(ofSize: radius * 1.15, weight: .bold)
        let attributed = NSAttributedString(string: "\(value)", attributes: [
            .font: font,
            .foregroundColor: foreground
        ])
        let size = attributed.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    public static func topLeftRectToCG(_ rect: CGRect, imageHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: imageHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }

    public static func topLeftPointToCG(_ point: CGPoint, imageHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: imageHeight - point.y)
    }
}
