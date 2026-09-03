import CoreGraphics

/// Coordinate conversions between the two spaces macOS uses for screen rectangles.
///
/// AppKit global space: y-up, origin at the PRIMARY screen's bottom-left.
/// CG display space:    y-down, origin at the PRIMARY screen's top-left.
///
/// Deliberately free of AppKit and ScreenCaptureKit so it stays unit testable.
public enum Geometry {

    /// Converts a region frame into the rectangle `SCStreamConfiguration.sourceRect`
    /// wants: points relative to the captured display's own origin.
    public static func sourceRect(appKitRect r: CGRect,
                                  primaryHeight: CGFloat,
                                  displayOrigin: CGPoint) -> CGRect {
        CGRect(x: r.minX - displayOrigin.x,
               y: primaryHeight - r.maxY - displayOrigin.y,
               width: r.width,
               height: r.height)
    }

    /// Inverse of `sourceRect` with a zero display origin: CGWindowList reports window
    /// bounds in display space, and `NSWindow.setFrame` wants AppKit space.
    public static func appKitRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX,
               y: primaryHeight - r.maxY,
               width: r.width,
               height: r.height)
    }

    /// Keeps a proposed region frame fully inside the given screen area, shrinking it
    /// first if it is larger than the screen so the origin clamp cannot go negative.
    public static func clamp(_ proposed: CGRect, into visible: CGRect) -> CGRect {
        var f = proposed
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    /// Resizes around the top edge. Resizing around AppKit's bottom-left origin instead
    /// makes the frame appear to jump upward.
    public static func resizedFromTop(_ frame: CGRect, to size: CGSize) -> CGRect {
        CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Where a frame of the given size sits for each anchor, within `visible`.
    public static func origin(for spot: RegionSpot, size: CGSize, in visible: CGRect) -> CGPoint {
        switch spot {
        case .center:      return CGPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2)
        case .topLeft:     return CGPoint(x: visible.minX, y: visible.maxY - size.height)
        case .topRight:    return CGPoint(x: visible.maxX - size.width, y: visible.maxY - size.height)
        case .bottomLeft:  return visible.origin
        case .bottomRight: return CGPoint(x: visible.maxX - size.width, y: visible.minY)
        }
    }
}

/// Anchor positions offered by the region presets.
public enum RegionSpot: Int, CaseIterable, Sendable {
    case center, topLeft, topRight, bottomLeft, bottomRight

    public var name: String {
        switch self {
        case .center: return "Center"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

/// A region size offered by the presets. `nil` size means "computed from the screen".
public struct RegionSize: Sendable {
    public let name: String
    public let size: CGSize?

    public init(name: String, size: CGSize?) {
        self.name = name
        self.size = size
    }

    /// On a 2x display 960x540 pt is exactly the 1920x1080 px output canvas, so it
    /// mirrors 1:1 with no resampling.
    public static let presets: [RegionSize] = [
        RegionSize(name: "960 x 540  (1:1 on Retina)", size: CGSize(width: 960, height: 540)),
        RegionSize(name: "1280 x 720", size: CGSize(width: 1280, height: 720)),
        RegionSize(name: "1920 x 1080", size: CGSize(width: 1920, height: 1080)),
        RegionSize(name: "Half Screen", size: nil),
    ]

    /// Half the screen width at 16:9 when the preset has no fixed size.
    public func resolved(in visible: CGRect) -> CGSize {
        if let size { return size }
        let width = visible.width / 2
        return CGSize(width: width, height: width * 9 / 16)
    }
}
