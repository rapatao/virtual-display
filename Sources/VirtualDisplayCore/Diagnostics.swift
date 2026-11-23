import AppKit
import CoreGraphics

/// Why a window is or is not offered by a conferencing app's share picker. Works both
/// in-process (the Copy Diagnostics menu item) and from a second process launched with
/// --list-windows, because it looks the app up through NSWorkspace either way.
public enum Diagnostics {
    public static func report() -> String {
        var out: [String] = ["Virtual Display diagnostics"]
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        out.append("build: \(version ?? "unknown")")
        out.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("screen recording (this process): \(CGPreflightScreenCaptureAccess())")
        out.append("share as a display: \(Preferences.sharesAsDisplay ? "on" : "off"), "
                   + "virtual display supported here: "
                   + "\(VirtualScreen.isSupported(version: ProcessInfo.processInfo.operatingSystemVersion))")

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.rapatao.virtual-display"
        }
        out.append("")
        if apps.isEmpty {
            out.append("Virtual Display is NOT running.")
        }
        for a in apps {
            let policy: String
            switch a.activationPolicy {
            case .regular: policy = "regular (Dock icon)"
            case .accessory: policy = "accessory (tray only)"
            case .prohibited: policy = "prohibited"
            @unknown default: policy = "unknown"
            }
            out.append("running: pid \(a.processIdentifier), policy: \(policy)")
            out.append("bundle:  \(a.bundleURL?.path ?? "?")")
        }

        let pids = Set(apps.map { $0.processIdentifier })
        func dump(_ label: String, _ options: CGWindowListOption) {
            let all = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
            let mine = all.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }
            out.append("")
            out.append("\(label): \(mine.count)")
            for w in mine {
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let num = { (k: String) in Int((b[k] as? Double) ?? 0) }
                let layer = w[kCGWindowLayer as String] as? Int ?? -1
                // Titles are not readable without Screen Recording, so the layer and size
                // stand in when there is none: the menu bar strips AppKit keeps per display
                // are layer 0 but only a few dozen points tall.
                let name = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let isOutput = name.map { $0 == "Virtual Display" }
                    ?? (layer == Int(CGWindowLevelForKey(.screenSaverWindow))
                        || (layer == 0 && num("Height") > 100))
                let role: String
                if isOutput {
                    role = "OUTPUT WINDOW (the shareable one)"
                } else if let name {
                    role = "other window \"\(name)\""
                } else {
                    switch layer {
                    case 0: role = "system strip (menu bar or similar)"
                    case 3: role = "region frame (never shareable)"
                    case 4: role = "drawing toolbar"
                    case 25: role = "HUD or status item"
                    default: role = "other window (layer \(layer))"
                    }
                }
                out.append("  \(role)")
                out.append("  layer=\(w[kCGWindowLayer as String] as? Int ?? -1)"
                    + " onscreen=\(w[kCGWindowIsOnscreen as String] as? Bool ?? false)"
                    + " alpha=\(w[kCGWindowAlpha as String] as? Double ?? -1)"
                    + " at \(num("X")),\(num("Y"))"
                    + " size \(num("Width"))x\(num("Height"))"
                    + " title=\(w[kCGWindowName as String] as? String ?? "<not readable>")")
            }
        }
        // A picker only offers the first set. The second tells off-screen apart from absent.
        dump("on-screen normal windows (what a picker lists)", [.optionOnScreenOnly, .excludeDesktopElements])
        dump("all windows incl. off-screen", [.optionAll, .excludeDesktopElements])

        out.append("")
        out.append("screens:")
        for s in NSScreen.screens {
            let isVirtual = s.displayID.map {
                CGDisplayVendorNumber($0) == VirtualScreen.vendorID
                    && CGDisplayModelNumber($0) == VirtualScreen.productID
            } ?? false
            out.append("  \(s.frame) visible \(s.visibleFrame)" + (isVirtual ? " VIRTUAL SCREEN" : ""))
            if isVirtual, let id = s.displayID {
                out.append("    active=\(CGDisplayIsActive(id) != 0) asleep=\(CGDisplayIsAsleep(id) != 0)"
                           + " online=\(CGDisplayIsOnline(id) != 0)"
                           + " mirrored=\(CGDisplayIsInMirrorSet(id) != 0)")
            }
        }
        return out.joined(separator: "\n")
    }
}

