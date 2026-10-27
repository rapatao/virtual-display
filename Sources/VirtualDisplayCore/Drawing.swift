import AppKit
import AVFoundation
import Carbon.HIToolbox

public enum DrawingTool: String, CaseIterable, Sendable {
    case pen
    case highlighter
    /// Ink that fades shortly after the stroke ends, for pointing at something.
    case laser

    /// The highlighter is a broad marker, so the same width setting draws it wider.
    var widthScale: CGFloat { self == .highlighter ? 4 : 1 }
    var inkAlpha: CGFloat { self == .highlighter ? 0.35 : 1 }
}

/// One line drawn over the region.
///
/// Points are fractions of the region, `0,0` top left, and the width is a fraction of the
/// region's height: the same stroke is drawn over the region on screen and over the
/// picture in the output window, which are different sizes.
public struct Stroke {
    public var tool: DrawingTool
    public var color: NSColor
    public var width: CGFloat
    public var points: [CGPoint]
    public var endedAt: Date?
}

/// A click inside the region, marked in the share by a ring that grows and fades.
public struct Click {
    /// A fraction of the region, like stroke points.
    public var point: CGPoint
    public var at: Date
}

/// The strokes, and the pen they are drawn with. Shared by the view over the region and
/// the one in the output window, which redraw on `onChange`.
@MainActor
public final class Drawing {

    public private(set) var strokes: [Stroke] = []
    public private(set) var clicks: [Click] = []
    public var onChange: (() -> Void)?
    /// Clicks are drawn only in the output window, so they redraw only that.
    public var onClicksChange: (() -> Void)?

    static let laserFade: TimeInterval = 1.5
    static let clickFade: TimeInterval = 0.6
    private var fadeTimer: Timer?

    public var tool = Preferences.drawTool { didSet { Preferences.drawTool = tool } }
    public var color = Preferences.drawColor { didSet { Preferences.drawColor = color } }
    /// Points on screen, at the region's size.
    public var width = Preferences.drawWidth { didSet { Preferences.drawWidth = width } }

    public init() {}

    func begin(_ stroke: Stroke) {
        strokes.append(stroke)
        onChange?()
    }

    func extend(to point: CGPoint) {
        guard let last = strokes.indices.last, strokes[last].endedAt == nil else { return }
        strokes[last].points.append(point)
        onChange?()
    }

    func end(at now: Date = Date()) {
        guard let last = strokes.indices.last, strokes[last].endedAt == nil else { return }
        strokes[last].endedAt = now
        if strokes[last].tool == .laser { startFading() }
    }

    func click(at point: CGPoint, now: Date = Date()) {
        clicks.append(Click(point: point, at: now))
        onClicksChange?()
        startFading()
    }

    /// Where a screen point lands in the region, as fractions from its top left, or nil
    /// outside it. Both are AppKit screen coordinates, origin bottom left.
    static func fraction(of point: CGPoint, in region: CGRect) -> CGPoint? {
        guard region.width > 0, region.height > 0,
              (region.minX...region.maxX).contains(point.x),
              (region.minY...region.maxY).contains(point.y)
        else { return nil }
        return CGPoint(x: (point.x - region.minX) / region.width,
                       y: (region.maxY - point.y) / region.height)
    }

    /// 0 at the click, up to 1 at `clickFade`.
    static func progress(of click: Click, at now: Date) -> CGFloat {
        CGFloat(min(max(now.timeIntervalSince(click.at) / clickFade, 0), 1))
    }

    /// Laser strokes are not undoable: they are gone by the time anyone reaches for undo.
    public func undo() {
        guard let index = strokes.lastIndex(where: { $0.tool != .laser }) else { return }
        strokes.remove(at: index)
        onChange?()
    }

    public func clear() {
        guard !strokes.isEmpty else { return }
        strokes = []
        onChange?()
    }

    /// 1 while a laser stroke is being drawn, then down to 0 over `laserFade`.
    static func opacity(of stroke: Stroke, at now: Date) -> CGFloat {
        guard stroke.tool == .laser, let ended = stroke.endedAt else { return 1 }
        return CGFloat(max(0, 1 - now.timeIntervalSince(ended) / laserFade))
    }

    func removeFaded(at now: Date) {
        let before = strokes.count
        let clicksBefore = clicks.count
        strokes.removeAll { Self.opacity(of: $0, at: now) <= 0 }
        clicks.removeAll { Self.progress(of: $0, at: now) >= 1 }
        if strokes.count != before { onChange?() }
        if clicks.count != clicksBefore { onClicksChange?() }
    }

    /// Runs only while a laser stroke or a click is fading.
    private func startFading() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeTick() }
        }
    }

    private func fadeTick() {
        removeFaded(at: Date())
        let lasersFading = strokes.contains { $0.tool == .laser && $0.endedAt != nil }
        if lasersFading { onChange?() }
        if !clicks.isEmpty { onClicksChange?() }
        if !lasersFading, clicks.isEmpty {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }
}

/// Draws the strokes, and takes the mouse to make new ones while `acceptsInput` is on.
@MainActor
public final class DrawingView: NSView {

    let drawing: Drawing

    /// Shapes the strokes are fitted into, outermost first, each centred in the last. The
    /// output window letterboxes the canvas into the window and the capture letterboxes
    /// the region into the canvas, so the strokes have to land where the region's picture
    /// does. Empty fills the bounds.
    var fitting: () -> [CGSize] = { [] }

    /// Only the output window's copy draws clicks: they are for the meeting, and the
    /// presenter already knows where they clicked.
    var showsClicks = false

    var acceptsInput = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onEscape: (() -> Void)?

    init(drawing: Drawing) {
        self.drawing = drawing
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { acceptsInput }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsInput ? super.hitTest(point) : nil
    }

    public override func resetCursorRects() {
        if acceptsInput { addCursorRect(bounds, cursor: .crosshair) }
    }

    private var contentRect: CGRect {
        fitting().reduce(bounds) { AVMakeRect(aspectRatio: $1, insideRect: $0) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = contentRect
        guard rect.height > 0 else { return }
        let now = Date()
        for stroke in drawing.strokes {
            guard let first = stroke.points.first else { continue }
            let place = { (p: CGPoint) in
                CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
            }
            let path = NSBezierPath()
            path.move(to: place(first))
            stroke.points.dropFirst().forEach { path.line(to: place($0)) }
            if stroke.points.count == 1 { path.line(to: place(first)) }
            path.lineWidth = stroke.width * rect.height
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let alpha = stroke.tool.inkAlpha * Drawing.opacity(of: stroke, at: now)
            stroke.color.withAlphaComponent(stroke.color.alphaComponent * alpha).setStroke()
            path.stroke()
        }
        if showsClicks { drawClicks(in: rect, at: now) }
    }

    /// Sized against the content rect's height, so a ring covers the same share of the
    /// picture at any output size.
    private func drawClicks(in rect: CGRect, at now: Date) {
        for click in drawing.clicks {
            let progress = Drawing.progress(of: click, at: now)
            let radius = rect.height * (0.012 + 0.03 * progress)
            let center = CGPoint(x: rect.minX + click.point.x * rect.width,
                                 y: rect.minY + click.point.y * rect.height)
            let ring = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = rect.height * 0.006
            NSColor.systemYellow.withAlphaComponent(0.9 * (1 - progress)).setStroke()
            ring.stroke()
        }
    }

    private func fraction(of event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x / bounds.width, 0), 1),
                       y: min(max(p.y / bounds.height, 0), 1))
    }

    public override func mouseDown(with event: NSEvent) {
        guard acceptsInput, bounds.height > 0 else { return }
        drawing.begin(Stroke(tool: drawing.tool, color: drawing.color,
                             width: drawing.width * drawing.tool.widthScale / bounds.height,
                             points: [fraction(of: event)]))
    }

    public override func mouseDragged(with event: NSEvent) {
        guard acceptsInput else { return }
        drawing.extend(to: fraction(of: event))
    }

    public override func mouseUp(with event: NSEvent) {
        guard acceptsInput else { return }
        drawing.end()
    }

    public override func keyDown(with event: NSEvent) {
        if acceptsInput, event.keyCode == kVK_Escape {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// The app has no Edit menu to carry cmd-z, so the view answers it itself.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard acceptsInput,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "z"
        else { return super.performKeyEquivalent(with: event) }
        drawing.undo()
        return true
    }
}

/// A dot as wide as the next stroke will be, in its colour, so the width can be judged
/// before drawing anything. Clipped to its box for the widest highlighter.
final class InkPreview: NSView {
    var tool = DrawingTool.pen { didSet { needsDisplay = true } }
    var color = NSColor.systemRed { didSet { needsDisplay = true } }
    var width: CGFloat = 4 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 40) }

    override func draw(_ dirtyRect: NSRect) {
        let side = width * tool.widthScale
        color.withAlphaComponent(color.alphaComponent * tool.inkAlpha).setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                    width: side, height: side)).fill()
    }
}

/// The floating palette shown next to the region while drawing. It belongs to this app,
/// so the capture leaves it out like every other window of ours.
@MainActor
public final class DrawingToolbar: NSPanel {

    private let drawing: Drawing
    var onDone: (() -> Void)?
    /// Typing a width takes the keyboard from the region; this hands it back.
    var onFinishedTyping: (() -> Void)?

    private let tools: NSSegmentedControl
    private let well = NSColorWell(style: .minimal)
    private let slider = NSSlider(value: 4, minValue: 1, maxValue: 20, target: nil, action: nil)
    private let field = NSTextField()
    private let preview = InkPreview()

    static let swatches: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]

    init(drawing: Drawing) {
        self.drawing = drawing
        let symbols = ["pencil.tip", "highlighter", "cursorarrow.rays"]
        tools = NSSegmentedControl(
            images: symbols.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage() },
            trackingMode: .selectOne, target: nil, action: nil)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        for (index, tool) in DrawingTool.allCases.enumerated() {
            tools.setToolTip(tool.rawValue.capitalized, forSegment: index)
        }
        tools.target = self
        tools.action = #selector(pickTool)
        well.target = self
        well.action = #selector(pickColor)
        slider.target = self
        slider.action = #selector(pickWidth)
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        slider.toolTip = "Width"
        let format = NumberFormatter()
        format.minimum = 1
        format.maximum = 20
        format.maximumFractionDigits = 0
        field.formatter = format
        field.alignment = .right
        field.controlSize = .small
        field.toolTip = "Width in points, 1 to 20"
        field.widthAnchor.constraint(equalToConstant: 36).isActive = true
        field.target = self
        field.action = #selector(typeWidth)

        let swatchButtons = Self.swatches.enumerated().map { index, color in
            let button = NSButton(image: Self.dot(color), target: self, action: #selector(pickSwatch))
            button.tag = index
            button.isBordered = false
            return button
        }
        let undo = Self.button("arrow.uturn.backward", "Undo", self, #selector(undoStroke))
        let clear = Self.button("trash", "Clear", self, #selector(clearStrokes))
        let done = Self.button("xmark.circle", "Stop drawing", self, #selector(finish))

        let stack = NSStackView(views: [tools] + swatchButtons + [well, preview, slider, field, undo, clear, done])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        setContentSize(stack.fittingSize)
    }

    private static func button(_ symbol: String, _ tip: String, _ target: AnyObject,
                               _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
                                  ?? NSImage(),
                              target: target, action: action)
        button.isBordered = false
        button.toolTip = tip
        return button
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    /// Centred above the region, or just inside its top edge when there is no room above.
    func show(near region: CGRect) {
        tools.selectedSegment = DrawingTool.allCases.firstIndex(of: drawing.tool) ?? 0
        well.color = drawing.color
        showWidth(drawing.width)
        refreshPreview()
        place(near: region)
        orderFront(nil)
    }

    func place(near region: CGRect) {
        let size = frame.size
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.maxY + 8)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame, origin.y + size.height > visible.maxY {
            origin.y = region.maxY - size.height - 8
        }
        setFrameOrigin(origin)
    }

    /// Borderless panels refuse key by default, which leaves the width field untypeable.
    /// `becomesKeyOnlyIfNeeded` keeps every other control from taking the keyboard.
    public override var canBecomeKey: Bool { true }

    private func refreshPreview() {
        preview.tool = drawing.tool
        preview.color = drawing.color
        preview.width = drawing.width
    }

    private func showWidth(_ width: Double) {
        slider.doubleValue = width
        field.integerValue = Int(width.rounded())
    }

    @objc private func pickTool() {
        drawing.tool = DrawingTool.allCases[max(tools.selectedSegment, 0)]
        refreshPreview()
    }

    @objc private func pickColor() {
        drawing.color = well.color
        refreshPreview()
    }

    @objc private func pickSwatch(_ sender: NSButton) {
        drawing.color = Self.swatches[sender.tag]
        well.color = drawing.color
        refreshPreview()
    }

    @objc private func pickWidth() {
        drawing.width = slider.doubleValue.rounded()
        showWidth(drawing.width)
        refreshPreview()
    }

    @objc private func typeWidth() {
        drawing.width = min(max(field.doubleValue, 1), 20)
        showWidth(drawing.width)
        refreshPreview()
        onFinishedTyping?()
    }
    @objc private func undoStroke() { drawing.undo() }
    @objc private func clearStrokes() { drawing.clear() }
    @objc private func finish() { onDone?() }
}

