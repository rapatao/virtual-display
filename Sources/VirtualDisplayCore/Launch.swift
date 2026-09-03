import AppKit

/// Process entry point: the command line flags, then the app itself.
public enum Launch {

    public static func main() -> Never {
        let arguments = Set(CommandLine.arguments.dropFirst())

        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            exit(0)
        }

        // Answers "why is it not in the share list" with data instead of guesswork.
        // Same report as the Copy Diagnostics menu item.
        if arguments.contains("--doctor") || arguments.contains("--list-windows") {
            print(Diagnostics.report())
            exit(0)
        }

        runApp()
    }

    private static let usage = """
        Virtual Display - mirror a screen region into a shareable window.

          --doctor          print why the output window is or is not shareable
          --list-windows    alias for --doctor
          --help            this message

        With no arguments the app runs in the menu bar.
        """

    private static func runApp() -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppCoordinator()   // NSApplication.delegate is weak: hold it here
            app.delegate = delegate
            app.setActivationPolicy(.accessory)   // tray-only until there is something to share
            app.run()
            _ = delegate
        }
        exit(0)
    }
}
