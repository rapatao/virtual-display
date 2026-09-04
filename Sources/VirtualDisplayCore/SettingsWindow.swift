import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The settings window: everything that used to be reachable only by hand-editing
/// `config.json`, plus the plugin switch.
///
/// It writes that same file rather than a parallel store, so hand-editing and the window
/// stay one source of truth. `onChange` hands the coordinator the new config; it decides
/// what to re-register, exactly as it does when the file is read at launch.
@MainActor
public final class SettingsWindow: NSObject, NSWindowDelegate {

    public struct Environment {
        public var config: () -> Config = { Config() }
        public var save: (Config) -> Void = { _ in }
        public var regionSize: () -> CGSize = { .zero }
        public var pluginsEnabled: () -> Bool = { false }
        public var setPluginsEnabled: (Bool) -> Void = { _ in }
        public var reloadPlugins: () -> Void = {}
        public var pluginErrors: () -> [String] = { [] }
        /// Command names to offer as shortcut targets.
        public var commands: () -> [String] = { [] }
        /// Open or closed. The app takes a Dock icon while it is open, so the window can
        /// be found again after it goes behind something.
        public var onVisibilityChanged: (Bool) -> Void = { _ in }
        /// Hands the global shortcuts back to the system while recording one, so Carbon
        /// does not eat the keystroke and run the action instead.
        public var setShortcutsSuspended: (Bool) -> Void = { _ in }
        public init() {}
    }

    private var window: NSWindow?
    private var model: SettingsModel?
    private let environment: Environment

    public init(environment: Environment) {
        self.environment = environment
    }

    public func show(tab: String? = nil) {
        if let window, let model {
            // Already open: switch to the tab asked for rather than ignoring it.
            if let tab = SettingsView.Tab(name: tab) { model.tab = tab }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = SettingsModel(environment: environment)
        model.tab = SettingsView.Tab(name: tab) ?? .presets
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Virtual Display Settings"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        // An accessory app has no menu bar of its own, so without activating, the window
        // opens behind whatever you were using and looks like nothing happened.
        environment.onVisibilityChanged(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil   // rebuilt on next open, so it always shows current state
        model = nil
        environment.setShortcutsSuspended(false)   // in case it closed mid-recording
        environment.onVisibilityChanged(false)
    }
}

/// Owns the edited copy and writes it through on every change. No Save button: a settings
/// window that can be wrong until you press something is a settings window people get
/// wrong.
@MainActor
final class SettingsModel: ObservableObject {
    /// The visible tab. `settings?tab=shortcuts` sets it, whether or not the window is
    /// already open.
    @Published var tab: SettingsView.Tab = .presets
    @Published var config: Config
    @Published var pluginsEnabled: Bool
    @Published var pluginErrors: [String]
    /// Held here rather than in the view, so switching tabs and back does not throw away
    /// a result and start another request.
    @Published var updateStatus: UpdateStatus = .idle

    enum UpdateStatus {
        case idle
        case checking
        case upToDate
        case available(UpdateCheck.Release)
        case failed(String)
    }

    let environment: SettingsWindow.Environment

    init(environment: SettingsWindow.Environment) {
        self.environment = environment
        config = environment.config()
        pluginsEnabled = environment.pluginsEnabled()
        pluginErrors = environment.pluginErrors()
    }

    func commit() {
        environment.save(config)
    }

    func setPlugins(_ on: Bool) {
        pluginsEnabled = on
        environment.setPluginsEnabled(on)
        pluginErrors = environment.pluginErrors()
    }

    func reloadPlugins() {
        environment.reloadPlugins()
        pluginErrors = environment.pluginErrors()
    }

    func addCurrentRegionAsPreset() {
        let size = environment.regionSize()
        guard size.width > 0, size.height > 0 else { return }
        let name = "\(Int(size.width)) x \(Int(size.height))"
        config.presets.append(Config.Preset(name: name,
                                            width: Double(Int(size.width)),
                                            height: Double(Int(size.height))))
        commit()
    }

    /// A blank row to type into. 1280x720 rather than zeros, so a row left untouched is
    /// still a usable preset rather than one the menu quietly ignores.
    func addPreset() {
        config.presets.append(Config.Preset(name: "New preset", width: 1280, height: 720))
        commit()
    }

    func removePresets(_ offsets: IndexSet) {
        config.presets.remove(atOffsets: offsets)
        commit()
    }

    /// Rebinding a command replaces its previous shortcut rather than adding a second.
    func bind(_ spec: String, to command: String) {
        for (existing, bound) in config.hotkeys where bound == command {
            config.hotkeys[existing] = nil
        }
        config.hotkeys[spec] = command
        commit()
    }

    func unbind(_ spec: String) {
        config.hotkeys[spec] = nil
        commit()
    }

    /// The button disables itself while this is in flight, so there is no second request
    /// to guard against.
    func checkForUpdate() {
        updateStatus = .checking
        UpdateCheck.latest { [weak self] result in
            // Fetch already came back on the main queue; this only tells the compiler so.
            MainActor.assumeIsolated {
                switch result {
                case .success(let release?): self?.updateStatus = .available(release)
                case .success(nil): self?.updateStatus = .upToDate
                case .failure(let error): self?.updateStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    func setFolder(_ path: String?, screenshots: Bool) {
        var captures = config.captures ?? Config.Captures()
        if screenshots { captures.screenshots = path } else { captures.recordings = path }
        config.captures = captures
        commit()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    enum Tab: String, CaseIterable, Identifiable {
        case presets = "Presets"
        case shortcuts = "Shortcuts"
        case captures = "Captures"
        case plugins = "Plugins"
        case about = "About"
        var id: String { rawValue }

        init?(name: String?) {
            guard let name,
                  let match = Self.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() })
            else { return nil }
            self = match
        }
    }

    var body: some View {
        TabView(selection: $model.tab) {
            PresetsTab(model: model).tabItem { Text(Tab.presets.rawValue) }.tag(Tab.presets)
            ShortcutsTab(model: model).tabItem { Text(Tab.shortcuts.rawValue) }.tag(Tab.shortcuts)
            CapturesTab(model: model).tabItem { Text(Tab.captures.rawValue) }.tag(Tab.captures)
            PluginsTab(model: model).tabItem { Text(Tab.plugins.rawValue) }.tag(Tab.plugins)
            AboutTab(model: model).tabItem { Text(Tab.about.rawValue) }.tag(Tab.about)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct PresetsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sizes added here join the built-in ones in Region Presets. "
                 + "Type a name and a size, or capture the region as it is now.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selected) {
                ForEach(model.config.presets.indices, id: \.self) { index in
                    PresetRow(preset: Binding(get: { model.config.presets[index] },
                                              set: { model.config.presets[index] = $0
                                                     model.commit() }))
                        .tag(index)
                }
            }
            .border(.separator)

            HStack {
                Button("Add Preset") { model.addPreset() }
                Button("Add Current Region Size") { model.addCurrentRegionAsPreset() }
                Button("Remove") {
                    model.removePresets(IndexSet(selected))
                    selected = []
                }
                .disabled(selected.isEmpty)
                Spacer()
            }
        }
    }
}

/// One editable preset. Every keystroke writes the file: it is a few hundred bytes
/// written atomically, and the alternative is edits that vanish when the window closes.
private struct PresetRow: View {
    @Binding var preset: Config.Preset

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $preset.name)
                .textFieldStyle(.roundedBorder)
            TextField("Width", value: $preset.width, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text("x").foregroundStyle(.secondary)
            TextField("Height", value: $preset.height, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text("pt").foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct ShortcutsTab: View {
    @ObservedObject var model: SettingsModel

    /// The four the app registers itself, and what they do. Anything else in the file is
    /// listed underneath as a custom binding.
    private let builtIns = [
        ("toggle-mirroring", "Toggle mirroring", "ctrl-opt-cmd-m"),
        ("toggle-pause", "Toggle pause", "ctrl-opt-cmd-p"),
        ("screenshot", "Take screenshot", "ctrl-opt-cmd-s"),
        ("toggle-recording", "Start or stop recording", "ctrl-opt-cmd-r"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Click a shortcut and press the keys you want. Recording a shortcut for "
                 + "an action replaces its default.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(builtIns, id: \.0) { command, title, fallback in
                        HStack {
                            Text(title)
                            Spacer()
                            ShortcutField(
                                spec: model.config.hotkeys.first { $0.value == command }?.key,
                                placeholder: fallback,
                                onRecord: { model.bind($0, to: command) },
                                onClear: { spec in model.unbind(spec) },
                                setSuspended: { model.environment.setShortcutsSuspended($0) })
                        }
                    }

                    let custom = model.config.hotkeys
                        .filter { pair in !builtIns.contains { $0.0 == pair.value } }
                        .sorted { $0.key < $1.key }
                    if !custom.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(custom, id: \.key) { spec, command in
                            HStack {
                                Text(command).font(.system(.body, design: .monospaced))
                                Spacer()
                                Text(spec).foregroundStyle(.secondary)
                                Button("Remove") { model.unbind(spec) }
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
    }
}

/// Records a shortcut: click, press the keys, done. Escape cancels, Delete clears.
private struct ShortcutField: NSViewRepresentable {
    let spec: String?
    let placeholder: String
    let onRecord: (String) -> Void
    let onClear: (String) -> Void
    let setSuspended: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorder {
        let view = ShortcutRecorder()
        configure(view)
        return view
    }

    func updateNSView(_ view: ShortcutRecorder, context: Context) {
        configure(view)
        view.display(spec: spec, placeholder: placeholder)
    }

    private func configure(_ view: ShortcutRecorder) {
        view.onRecord = onRecord
        view.onClear = { if let spec { onClear(spec) } }
        view.setSuspended = setSuspended
    }
}

/// An NSButton that swallows the next key press instead of acting on it.
final class ShortcutRecorder: NSButton {
    var onRecord: ((String) -> Void)?
    var onClear: (() -> Void)?
    var setSuspended: ((Bool) -> Void)?

    private var monitor: Any?
    private var recording = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        // Not `stop()`: deinit is nonisolated and removing the monitor is all that is left.
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func display(spec: String?, placeholder: String) {
        guard !recording else { return }
        title = spec ?? placeholder
        contentTintColor = spec == nil ? .secondaryLabelColor : nil
    }

    @objc private func startRecording() {
        guard !recording else { return stop() }
        recording = true
        title = "Press keys..."
        // Carbon takes a registered combination before any monitor sees it, so recording
        // a key an action already holds would run that action instead.
        setSuspended?(true)

        // A local monitor, so the keystroke never reaches the rest of the app: recording
        // cmd-q must not quit.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            if event.keyCode == UInt16(kVK_Delete) {
                onClear?()
                stop()
                return nil
            }
            guard let spec = KeySpec(event: event)?.spec else {
                NSSound.beep()   // modifier-only, or a key with no name
                return nil
            }
            onRecord?(spec)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        setSuspended?(false)
    }
}

private struct CapturesTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            folderRow(title: "Screenshots",
                      path: model.config.captures?.screenshots,
                      fallback: "~/Pictures/Virtual Display",
                      screenshots: true)
            folderRow(title: "Recordings",
                      path: model.config.captures?.recordings,
                      fallback: "~/Movies/Virtual Display",
                      screenshots: false)
            Text("Recordings are H.264 at 1920x1080, video only. Both capture the shared "
                 + "window, overlays included.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func folderRow(title: String, path: String?, fallback: String,
                           screenshots: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                Text(path ?? fallback)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .truncationMode(.head)
                    .lineLimit(1)
                Spacer()
                Button("Choose...") { choose(screenshots: screenshots) }
                Button("Default") { model.setFolder(nil, screenshots: screenshots) }
                    .disabled(path == nil)
            }
        }
    }

    private func choose(screenshots: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setFolder(url.path, screenshots: screenshots)
    }
}

private struct PluginsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable plugins", isOn: Binding(get: { model.pluginsEnabled },
                                                   set: { model.setPlugins($0) }))
                .toggleStyle(.switch)

            Text("A plugin is Lua code running inside this app, which holds Screen "
                 + "Recording permission. It can capture the screen and send what it "
                 + "finds elsewhere. Only enable this for files you put there yourself.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(ConfigPaths.plugins.path)
                    .font(.system(.callout, design: .monospaced))
                    .truncationMode(.head).lineLimit(1)
                Spacer()
                Button("Reveal") {
                    try? FileManager.default.createDirectory(at: ConfigPaths.plugins,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigPaths.plugins])
                }
                Button("Reload") { model.reloadPlugins() }
                    .disabled(!model.pluginsEnabled)
            }

            if !model.pluginErrors.isEmpty {
                GroupBox("Errors") {
                    ScrollView {
                        Text(model.pluginErrors.joined(separator: "\n\n"))
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            }
            Spacer()
        }
    }
}

/// Who this is, which version is running, and whether a newer one exists. Everything here
/// comes out of the bundle, so it cannot disagree with what was actually shipped.
private struct AboutTab: View {
    @ObservedObject var model: SettingsModel

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    /// Present only in a real bundle; `swift run` shows the version without a link.
    private var license: URL? { Bundle.main.url(forResource: "LICENSE", withExtension: nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Virtual Display").font(.title2).bold()
                    // Selectable: it is the first thing a bug report needs.
                    Text("Version \(UpdateCheck.currentVersion)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let copyright = info["NSHumanReadableCopyright"] as? String {
                        Text(copyright).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Button("GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateCheck.repository)")!)
                }
                if let license {
                    Button("License") { NSWorkspace.shared.open(license) }
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 10) {
                Button("Check for Updates") { model.checkForUpdate() }
                    .disabled(isChecking)
                status
                Spacer()
            }

            Text("Updates are not installed for you. With Homebrew, "
                 + "brew upgrade --cask virtual-display.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var isChecking: Bool {
        if case .checking = model.updateStatus { return true }
        return false
    }

    @ViewBuilder private var status: some View {
        switch model.updateStatus {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking...").foregroundStyle(.secondary)
        case .upToDate:
            Text("Up to date.").foregroundStyle(.secondary)
        case .available(let release):
            Text("Version \(release.version) is available.")
            Button("Open Release Page") {
                if let url = URL(string: release.page) { NSWorkspace.shared.open(url) }
            }
        // A failed check must not read as "up to date": that is the one wrong answer here.
        case .failed(let message):
            Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }
}
