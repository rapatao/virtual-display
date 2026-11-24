import AppKit
import CVirtualDisplay

/// A virtual display backed by private CoreGraphics API. Creation fails (nil) outside the
/// supported macOS range or when the API is missing, and callers fall back to a window.
@MainActor
public final class VirtualScreen {
    /// Inclusive range of macOS major versions the private API is used on.
    nonisolated static let supportedMajorVersions = 14...27

    struct Mode: Equatable {
        let width: UInt32
        let height: UInt32
        let refreshRate: Double
        let sizeInMillimeters: CGSize
    }

    static let displayName = "Virtual Display"
    nonisolated static let vendorID: UInt32 = 0x5644
    nonisolated static let productID: UInt32 = 0x0001
    static let serialNumber: UInt32 = 1
    static let refreshRate = 60.0
    static let pixelsPerInch = 110.0

    nonisolated static func isSupported(version: OperatingSystemVersion) -> Bool {
        supportedMajorVersions.contains(version.majorVersion)
    }

    static func mode(for canvas: CGSize) -> Mode? {
        guard let width = UInt32(exactly: canvas.width.rounded(.down)),
              let height = UInt32(exactly: canvas.height.rounded(.down)),
              width > 0, height > 0 else { return nil }
        let millimetersPerPixel = 25.4 / pixelsPerInch
        return Mode(width: width, height: height,
                    refreshRate: refreshRate,
                    sizeInMillimeters: CGSize(width: Double(width) * millimetersPerPixel,
                                              height: Double(height) * millimetersPerPixel))
    }

    public let displayID: CGDirectDisplayID
    private var handle: UnsafeMutableRawPointer?

    public init?(canvas: CGSize) {
        guard Self.isSupported(version: ProcessInfo.processInfo.operatingSystemVersion) else { return nil }
        guard let mode = Self.mode(for: canvas) else { return nil }
        let limit = UInt32(Config.maxCanvasDimension)
        var id: CGDirectDisplayID = 0
        guard let handle = VDVirtualDisplayCreate(
            Self.displayName, Self.vendorID, Self.productID, Self.serialNumber,
            limit, limit, mode.sizeInMillimeters.width, mode.sizeInMillimeters.height,
            mode.width, mode.height, mode.refreshRate, &id) else { return nil }
        self.handle = handle
        displayID = id
    }

    deinit {
        if let handle { VDVirtualDisplayRelease(handle) }
    }

    /// Releases the display now instead of at deinit.
    public func stop() {
        guard let handle else { return }
        self.handle = nil
        VDVirtualDisplayRelease(handle)
    }

    @discardableResult
    public func apply(canvas: CGSize) -> Bool {
        guard let handle, let mode = Self.mode(for: canvas) else { return false }
        return VDVirtualDisplayApplyMode(handle, mode.width, mode.height, mode.refreshRate)
    }

    /// The display's NSScreen, once the system has published it. Nil after about 2 seconds.
    public func screen() async -> NSScreen? {
        let deadline = Date().addingTimeInterval(2)
        while Self.screen(for: displayID) == nil, deadline.timeIntervalSinceNow > 0 {
            await Self.nextScreenChange(within: deadline.timeIntervalSinceNow)
        }
        return Self.screen(for: displayID)
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    /// The screen capture should target: the given one, unless it is the virtual display,
    /// which would feed the mirror its own output.
    static func capturable(_ screen: NSScreen?, excluding virtualID: CGDirectDisplayID?) -> NSScreen? {
        isVirtual(screen?.displayID, virtualID: virtualID) ? nil : screen
    }

    static func isVirtual(_ id: CGDirectDisplayID?, virtualID: CGDirectDisplayID?) -> Bool {
        id != nil && id == virtualID
    }

    /// Index of the display a region should move to: the main one when it is real, else the
    /// first that is not virtual.
    static func realDisplayIndex(of ids: [CGDirectDisplayID?], virtualID: CGDirectDisplayID?,
                                 mainID: CGDirectDisplayID) -> Int? {
        let real = ids.indices.filter { !isVirtual(ids[$0], virtualID: virtualID) }
        return real.first { ids[$0] == mainID } ?? real.first
    }

    /// A display that is offline or mirrors another no longer has a screen of its own, so a
    /// window pinned to it would end up over a real one.
    /// Being the main display counts too: with no real display left, capture would mirror
    /// the virtual display's own output.
    static func isLost(isOnline: Bool, isInMirrorSet: Bool, isMain: Bool) -> Bool {
        !isOnline || isInMirrorSet || isMain
    }

    var isLost: Bool {
        Self.isLost(isOnline: CGDisplayIsOnline(displayID) != 0,
                    isInMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0,
                    isMain: CGMainDisplayID() == displayID)
    }

    enum Start {
        case window
        case display(VirtualScreen)
        case failed
    }

    /// What mirroring should open: `failed` is a window the user asked to replace and could
    /// not have, which is worth telling them about once.
    static func start(wanted: Bool, canvas: CGSize, make: (CGSize) -> VirtualScreen?) -> Start {
        guard wanted else { return .window }
        return make(canvas).map(Start.display) ?? .failed
    }

    private static func nextScreenChange(within seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pending = Pending(continuation)
            pending.token = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { _ in pending.finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { pending.finish() }
        }
    }

    private final class Pending: @unchecked Sendable {
        var token: NSObjectProtocol?
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            if let token { NotificationCenter.default.removeObserver(token) }
            continuation.resume()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
