import AppKit

/// One thing drawn on top of the mirrored image: a line of text, an image, or a filled
/// rectangle. Everything is expressed against a 1920x1080 reference canvas, so an overlay
/// keeps its place and its proportions whatever size the output window is dragged to.
///
/// Positions are fractions of the window, `0,0` top left, `1,1` bottom right, because
/// that is how anyone placing a watermark thinks about it.
public struct OverlayItem {
    public var text: String?
    public var image: NSImage?
    public var x: CGFloat = 0
    public var y: CGFloat = 0
    /// Fractions of the window. Optional for text and images, required for a plain rect.
    public var width: CGFloat?
    public var height: CGFloat?
    /// Font size in points on the 1080-tall reference canvas.
    public var size: CGFloat = 32
    public var color: NSColor = .white
    public var background: NSColor?
    public var alignment: NSTextAlignment = .left
    public var alpha: CGFloat = 1
    /// Draw order; equal values keep the order they were added in.
    public var z: Int = 0

    public init() {}
}

extension OverlayItem {
    /// Built from the string pairs a command carries, so `virtualdisplay://set-overlay`,
    /// `vd.overlay` in Lua and a test all go through the same parsing and the same
    /// complaints.
    public init(_ args: CommandCenter.Arguments) throws {
        self.init()
        text = args["text"]

        if let path = args["image"] {
            let expanded = (path as NSString).expandingTildeInPath
            guard let loaded = NSImage(contentsOfFile: expanded) else {
                throw CommandCenter.Failure.badArgument("image", "cannot read an image at \(expanded)")
            }
            image = loaded
        }

        x = try fraction(args, "x") ?? 0
        y = try fraction(args, "y") ?? 0
        width = try fraction(args, "w")
        height = try fraction(args, "h")
        if let value = args["size"] { size = try positive(value, "size") }
        if let value = args["alpha"] { alpha = try fraction(value, "alpha") }
        if let value = args["z"] {
            guard let z = Int(value) else {
                throw CommandCenter.Failure.badArgument("z", "expected a whole number")
            }
            self.z = z
        }
        if let value = args["color"] { color = try Self.color(value, "color") }
        if let value = args["background"] { background = try Self.color(value, "background") }
        if let value = args["align"] {
            switch value.lowercased() {
            case "left": alignment = .left
            case "center", "centre": alignment = .center
            case "right": alignment = .right
            default: throw CommandCenter.Failure.badArgument("align", "expected left, center or right")
            }
        }

        // A rectangle is the one shape with nothing to measure itself from.
        if text == nil, image == nil {
            guard background != nil, width != nil, height != nil else {
                throw CommandCenter.Failure.failed(
                    "an overlay needs text, an image, or a background with w and h")
            }
        }
    }

    private func fraction(_ args: CommandCenter.Arguments, _ key: String) throws -> CGFloat? {
        guard let value = args[key] else { return nil }
        return try fraction(value, key)
    }

    /// Clamped rather than rejected: a plugin computing a position from a window frame
    /// will overshoot at the edges, and clipping there is what it meant anyway.
    private func fraction(_ value: String, _ key: String) throws -> CGFloat {
        guard let number = Double(value) else {
            throw CommandCenter.Failure.badArgument(key, "expected a number between 0 and 1")
        }
        return CGFloat(min(max(number, 0), 1))
    }

    private func positive(_ value: String, _ key: String) throws -> CGFloat {
        guard let number = Double(value), number > 0 else {
            throw CommandCenter.Failure.badArgument(key, "expected a positive number")
        }
        return CGFloat(number)
    }

    /// `#rgb`, `#rrggbb` or `#rrggbbaa`, plus the handful of names worth not looking up.
    static func color(_ value: String, _ key: String) throws -> NSColor {
        let named: [String: NSColor] = [
            "white": .white, "black": .black, "red": .systemRed, "green": .systemGreen,
            "blue": .systemBlue, "yellow": .systemYellow, "orange": .systemOrange,
            "clear": .clear,
        ]
        if let match = named[value.lowercased()] { return match }

        var hex = value
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let packed = UInt32(hex, radix: 16) else {
            throw CommandCenter.Failure.badArgument(key, "expected #rrggbb, #rrggbbaa or a colour name")
        }
        let bytes = hex.count == 8
            ? [packed >> 24 & 0xFF, packed >> 16 & 0xFF, packed >> 8 & 0xFF, packed & 0xFF]
            : [packed >> 16 & 0xFF, packed >> 8 & 0xFF, packed & 0xFF, 255]
        let channel = { (index: Int) in CGFloat(bytes[index]) / 255 }
        return NSColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: channel(3))
    }
}

/// Draws the overlay items over the mirrored image, inside the window a meeting shares.
///
/// Deliberately a sibling view of the video layer rather than something composited into
/// the capture pipeline: what is shared is this window, so drawing in it is all it takes,
/// and the ScreenCaptureKit path stays untouched.
@MainActor
public final class OverlayView: NSView {

    /// Insertion order preserved, so `z` only has to break ties.
    private var items: [(id: String, item: OverlayItem)] = []

    public override var isFlipped: Bool { true }   // y grows downward, like a screen

    /// Never take a click: the window under the pointer must keep behaving normally.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true   // everything is sized from the bounds
    }

    /// `nil` removes. Setting an existing id replaces it in place, keeping its position in
    /// the drawing order, so a clock updating every second does not climb over its
    /// neighbours.
    public func set(_ id: String, _ item: OverlayItem?) {
        let existing = items.firstIndex { $0.id == id }
        switch (existing, item) {
        case (let index?, let item?): items[index].item = item
        case (let index?, nil): items.remove(at: index)
        case (nil, let item?): items.append((id: id, item: item))
        case (nil, nil): return
        }
        needsDisplay = true
    }

    public func removeAll() {
        guard !items.isEmpty else { return }
        items = []
        needsDisplay = true
    }

    public var ids: [String] { items.map(\.id) }

    public override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty, bounds.height > 0 else { return }
        // One scale for everything: sizes are authored against a 1080-tall canvas.
        let scale = bounds.height / 1080
        for entry in items.enumerated().sorted(by: { ($0.element.item.z, $0.offset) < ($1.element.item.z, $1.offset) }) {
            draw(entry.element.item, scale: scale)
        }
    }

    private func draw(_ item: OverlayItem, scale: CGFloat) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        context.cgContext.setAlpha(item.alpha)

        let content = contentRect(for: item, scale: scale)
        if let background = item.background {
            let padding = (item.text == nil ? 0 : 8 * scale)
            background.setFill()
            content.insetBy(dx: -padding, dy: -padding).fill()
        }
        if let image = item.image {
            image.draw(in: content)
        }
        if let text = item.text {
            attributed(text, item, scale: scale).draw(in: content)
        }
    }

    /// Where the item lands: `x`/`y` is its top edge, and its left, centre or right edge
    /// according to the alignment.
    private func contentRect(for item: OverlayItem, scale: CGFloat) -> CGRect {
        let anchor = CGPoint(x: item.x * bounds.width, y: item.y * bounds.height)
        var size = CGSize(
            width: (item.width ?? 0) * bounds.width,
            height: (item.height ?? 0) * bounds.height)

        if let image = item.image {
            let natural = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            if size.width == 0 && size.height == 0 {
                size = natural
            } else if size.width == 0 {
                size.width = size.height * (natural.width / max(natural.height, 1))
            } else if size.height == 0 {
                size.height = size.width * (natural.height / max(natural.width, 1))
            }
        } else if let text = item.text {
            let measured = attributed(text, item, scale: scale)
                .boundingRect(with: CGSize(width: size.width > 0 ? size.width : .greatestFiniteMagnitude,
                                           height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin])
            if size.width == 0 { size.width = ceil(measured.width) }
            size.height = ceil(measured.height)
        }

        let left: CGFloat
        switch item.alignment {
        case .center: left = anchor.x - size.width / 2
        case .right: left = anchor.x - size.width
        default: left = anchor.x
        }
        return CGRect(x: left, y: anchor.y, width: size.width, height: size.height)
    }

    private func attributed(_ text: String, _ item: OverlayItem, scale: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = item.alignment
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: item.size * scale, weight: .semibold),
            .foregroundColor: item.color,
            .paragraphStyle: paragraph,
        ])
    }
}
