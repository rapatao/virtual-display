import AppKit

/// A line of text on screen for a second, the way the volume keys produce one.
///
/// What the global shortcuts answer with: they fire while another app is focused, where
/// the only other feedback is the menu bar icon.
///
/// It never appears in the share; the capture filter excludes every window of this app.
@MainActor
public final class HUDWindow: NSPanel {

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var dismiss: Timer?

    public init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
                   // .nonactivatingPanel: it must not take focus from whatever the
                   // shortcut was pressed over.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Follows the user rather than the desktop it was created on, so a shortcut
        // pressed in a full-screen app is still answered.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        icon.contentTintColor = .labelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            background.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: 18),
        ])
        contentView = background
    }

    /// Replaces whatever is showing rather than queueing behind it.
    public func show(_ message: String, symbol: String? = nil) {
        label.stringValue = message
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = icon.image == nil

        let width = max(180, (contentView?.fittingSize.width ?? 180))
        setContentSize(NSSize(width: width, height: 56))
        place()

        dismiss?.invalidate()
        alphaValue = 1
        // Regardless: an accessory app is not active, and a plain orderFront would do
        // nothing while another app owns the screen.
        orderFrontRegardless()
        dismiss = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fade() }
        }
    }

    /// Low and centred on the screen the user is working on, where macOS puts its own
    /// HUDs.
    private func place() {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.minY + 120))
    }

    private func fade() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }
}
