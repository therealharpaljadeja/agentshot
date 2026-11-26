import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
import AppKit
@preconcurrency import ScreenCaptureKit

struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

public struct CaptureResult: Sendable {
    public let image: CGImage
    public let displayID: UInt32
    public let scale: CGFloat
    public let sourceRect: CGRect?

    public init(image: CGImage, displayID: UInt32, scale: CGFloat, sourceRect: CGRect?) {
        self.image = image
        self.displayID = displayID
        self.scale = scale
        self.sourceRect = sourceRect
    }
}

final class OneShotFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var firstFrame: CVPixelBuffer?

    func nextFrame(timeoutSeconds: TimeInterval = 5) throws -> UnsafeSendableBox<CVPixelBuffer> {
        lock.lock()
        if let firstFrame {
            lock.unlock()
            return UnsafeSendableBox(value: firstFrame)
        }
        lock.unlock()

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw AgentshotError("capture-timeout", "Timed out waiting for the first screen frame")
        }

        lock.lock()
        defer { lock.unlock() }
        guard let firstFrame else {
            throw AgentshotError("capture-frame-missing", "Capture signaled completion without a frame")
        }
        return UnsafeSendableBox(value: firstFrame)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        if firstFrame == nil {
            firstFrame = pixelBuffer
            semaphore.signal()
        }
        lock.unlock()
    }
}

public enum CaptureService {
    public static func fullscreen(displayIndex: Int = 0) async throws -> CaptureResult {
        try await capture(displayIndex: displayIndex, rect: nil)
    }

    public static func area(_ rect: CGRect, displayIndex: Int = 0) async throws -> CaptureResult {
        try await capture(displayIndex: displayIndex, rect: rect)
    }

    private static func capture(displayIndex: Int, rect: CGRect?) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw AgentshotError(
                "missing-screen-recording-permission",
                "Screen Recording permission is not granted to this process or its parent terminal.",
                recovery: "Grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording, then retry."
            )
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard content.displays.indices.contains(displayIndex) else {
            throw AgentshotError("display-not-found", "Display index \(displayIndex) does not exist; \(content.displays.count) display(s) available")
        }
        let display = content.displays[displayIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = backingScale(for: display)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(CGFloat(display.width) * scale))
        configuration.height = max(1, Int(CGFloat(display.height) * scale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let output = OneShotFrameOutput()
        let queue = DispatchQueue(label: "agentshot.capture")
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let pixelBuffer = try output.nextFrame().value
        try await stream.stopCapture()

        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard status == noErr, var image = cgImage else {
            throw AgentshotError("capture-decode-failed", "Could not convert captured frame to an image")
        }

        if let rect {
            image = try cropImage(image, screenRectTopLeft: rect, display: display, scale: scale)
        }
        return CaptureResult(image: image, displayID: display.displayID, scale: scale, sourceRect: rect)
    }

    private static func backingScale(for display: SCDisplay) -> CGFloat {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               number.uint32Value == display.displayID {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private static func cropImage(_ image: CGImage, screenRectTopLeft rect: CGRect, display: SCDisplay, scale: CGFloat) throws -> CGImage {
        let pixelRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = pixelRect.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            throw AgentshotError("rect-outside-display", "Requested rectangle does not intersect the captured display")
        }
        guard let cropped = image.cropping(to: clipped) else {
            throw AgentshotError("crop-failed", "Could not crop captured image")
        }
        return cropped
    }

    public static func write(_ result: CaptureResult, to out: URL) throws -> [String: Any] {
        try writeCGImage(result.image, to: out)
        var capture: [String: Any] = [
            "displayId": result.displayID,
            "backingScaleFactor": result.scale
        ]
        if let rect = result.sourceRect {
            capture["screenRect"] = [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.width,
                "height": rect.height,
                "units": "screen-points-top-left"
            ]
        }
        return [
            "ok": true,
            "artifacts": [imageArtifact(out, width: result.image.width, height: result.image.height)],
            "capture": capture,
            "warnings": []
        ]
    }

    public static func doctor() -> [String: Any] {
        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        return [
            "ok": screenRecording,
            "permissions": [
                "screenRecording": screenRecording,
                "accessibility": accessibility,
                "accessibilityRequiredForMVP": false
            ],
            "notes": [
                "MVP agent-driven scrolling does not require Accessibility permission because agentshot does not inject scroll events.",
                "Screen Recording permission may belong to the terminal or host application that launches the CLI."
            ]
        ]
    }
}
