import Foundation
import CoreGraphics
import AppKit

public struct BeautifyOptions: Sendable {
    public var padding: CGFloat = 64
    public var radius: CGFloat = 24
    public var shadowOpacity: CGFloat = 0.25
    public var shadowBlur: CGFloat = 30
    public var background: String = "#dceeff"

    public init(padding: CGFloat = 64, radius: CGFloat = 24, shadowOpacity: CGFloat = 0.25, shadowBlur: CGFloat = 30, background: String = "#dceeff") {
        self.padding = padding
        self.radius = radius
        self.shadowOpacity = shadowOpacity
        self.shadowBlur = shadowBlur
        self.background = background
    }
}

public enum Beautifier {
    public static func beautify(image: CGImage, options: BeautifyOptions) throws -> CGImage {
        guard options.padding.isFinite, options.radius.isFinite, options.shadowOpacity.isFinite, options.shadowBlur.isFinite,
              options.padding >= 0, options.radius >= 0, options.shadowOpacity >= 0, options.shadowBlur >= 0 else {
            throw AgentshotError("invalid-beautify-options", "Padding, radius, shadow opacity, and shadow blur must be finite non-negative numbers")
        }
        let paddingPixels = options.padding * 2
        guard paddingPixels.isFinite,
              paddingPixels <= CGFloat(Int.max - image.width),
              paddingPixels <= CGFloat(Int.max - image.height) else {
            throw AgentshotError("invalid-beautify-options", "Padding is too large for the input image")
        }
        let width = image.width + Int(paddingPixels)
        let height = image.height + Int(paddingPixels)
        guard let context = makeBitmapContext(width: width, height: height) else {
            throw AgentshotError("render-failed", "Could not create beautify rendering context")
        }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        drawBackground(in: context, rect: canvas, backgroundSpec: options.background)

        let imageRect = CGRect(x: options.padding, y: options.padding, width: CGFloat(image.width), height: CGFloat(image.height))
        let rounded = CGPath(roundedRect: imageRect, cornerWidth: options.radius, cornerHeight: options.radius, transform: nil)

        if options.shadowOpacity > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -options.shadowBlur * 0.25), blur: options.shadowBlur, color: CGColor(red: 0, green: 0, blue: 0, alpha: options.shadowOpacity))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.addPath(rounded)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(rounded)
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()

        guard let output = context.makeImage() else {
            throw AgentshotError("render-failed", "Could not produce beautified image")
        }
        return output
    }

    private static func drawBackground(in context: CGContext, rect: CGRect, backgroundSpec: String) {
        let parts = backgroundSpec.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count >= 2 {
            let colors = parts.map { cgColor(colorFromHex($0, fallback: .white)) }
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) {
                context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
                return
            }
        }
        context.setFillColor(cgColor(colorFromHex(backgroundSpec, fallback: .white)))
        context.fill(rect)
    }
}
