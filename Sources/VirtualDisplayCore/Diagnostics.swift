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
                // Layer 0 is the output window, the only one a picker can ever offer.
                // The region frame is .floating, so it sits at layer 3.
                let layer = w[kCGWindowLayer as String] as? Int ?? -1
                let role = layer == 0 ? "OUTPUT WINDOW (the shareable one)"
                                      : "region frame (never shareable)"
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
            out.append("  \(s.frame) visible \(s.visibleFrame)")
        }
        return out.joined(separator: "\n")
    }
}

