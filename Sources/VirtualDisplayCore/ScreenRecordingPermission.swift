import AppKit
import CoreGraphics

/// The Screen Recording grant: reading it, asking for it, and pointing at Settings when
/// macOS will not ask again.
@MainActor
public enum ScreenRecordingPermission {

    /// Non-prompting. Safe to call as often as you like, including on every menu open.
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    public enum RequestOutcome {
        /// The system dialog is now on screen. Showing anything of our own on top of it
        /// is what made this look like being asked for permission twice.
        case systemPromptShown
        case granted
        case denied
    }

    /// `CGRequestScreenCaptureAccess` returns the status from *before* the user answers,
    /// so a false result does not mean denied on the first call.
    public static func request() -> RequestOutcome {
        if isGranted { return .granted }

        if !Preferences.didRequestScreenRecordingAccess {
            Preferences.didRequestScreenRecordingAccess = true
            _ = CGRequestScreenCaptureAccess()
            return isGranted ? .granted : .systemPromptShown
        }
        return isGranted ? .granted : .denied
    }

    /// Shown only once macOS has stopped prompting, when this is the only thing that can
    /// point anywhere useful.
    public static func showDeniedAlert(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Virtual Display needs Screen Recording access"
        alert.informativeText = """
            \(reason)

            Turn on "Virtual Display" under Privacy & Security > \
            Screen & System Audio Recording. macOS will offer to relaunch the app \
            once you do.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        // Stays in the tray either way: quitting a menu bar app out from under the user
        // over a permission they may be about to grant is worse than waiting.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    public static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
