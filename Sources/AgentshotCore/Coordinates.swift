import Foundation
import CoreGraphics

public func topLeftRectToCG(_ rect: CGRect, imageHeight: CGFloat) -> CGRect {
    CGRect(x: rect.origin.x, y: imageHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
}

public func topLeftPointToCG(_ point: CGPoint, imageHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: imageHeight - point.y)
}

public func cgRectToTopLeft(_ rect: CGRect, imageHeight: CGFloat) -> CGRect {
    CGRect(x: rect.origin.x, y: imageHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
}
