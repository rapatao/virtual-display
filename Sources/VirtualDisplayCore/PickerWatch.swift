import AppKit
import CoreGraphics

/// The strip a browser puts up while its window picker is open, seen from outside: no
/// title and no owner name are used, so it does not depend on Screen Recording or on
/// which Chromium browser draws it.
enum PickerBanner {
    static let layer = NSWindow.Level.statusBar.rawValue
    static let widthRange = 300.0...600.0
    static let heightRange = 40.0...100.0

    static func matches(ownerPID: Int32, ownPID: Int32, layer: Int,
                        width: Double, height: Double, onScreen: Bool) -> Bool {
        ownerPID != ownPID && layer == Self.layer && onScreen
            && widthRange.contains(width) && heightRange.contains(height)
    }

    static func isShown(in windows: [[String: Any]], ownPID: Int32) -> Bool {
        windows.contains { window in
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return matches(ownerPID: window[kCGWindowOwnerPID as String] as? Int32 ?? ownPID,
                           ownPID: ownPID,
                           layer: window[kCGWindowLayer as String] as? Int ?? -1,
                           width: bounds["Width"] as? Double ?? 0,
                           height: bounds["Height"] as? Double ?? 0,
                           onScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? true)
        }
    }

    static func currentlyShown() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return isShown(in: windows, ownPID: ProcessInfo.processInfo.processIdentifier)
    }
}

/// Decides when a revealed window may park early: the banner has to be seen, then gone
/// for a couple of polls in a row, and not too soon after the reveal.
struct PickerWatch {
    static let pollInterval: TimeInterval = 0.5
    static let minimumAge: TimeInterval = 2
    static let missesToPark = 2

    private(set) var seen = false
    private var misses = 0

    mutating func poll(bannerShown: Bool, age: TimeInterval) -> Bool {
        if bannerShown {
            seen = true
            misses = 0
            return false
        }
        guard seen else { return false }
        misses += 1
        return misses >= Self.missesToPark && age >= Self.minimumAge
    }
}
