import SwiftUI

@main
struct MacDiskSleuthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    /// Scene id of the results window; `openWindow(id:)` reopens it and
    /// `NSWindow.identifier` starts with it.
    static let mainWindowID = "main"
    /// Scene id of the per-recommendation windows, keyed by `Recommendation.id`.
    static let recommendationWindowID = "recommendation"

    var body: some Scene {
        // First so File › New Window (⌘N) still means the results window.
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environment(model)
                .environment(\.typography, Typography(scale: model.textScale))
                .environment(\.font, .system(size: 13 * model.textScale))
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1150, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Folder…") { model.pickAndScanFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.graph == nil)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Bigger Text") { model.increaseTextSize() }
                    .keyboardShortcut("+")
                Button("Smaller Text") { model.decreaseTextSize() }
                    .keyboardShortcut("-")
                Button("Default Text Size") { model.resetTextSize() }
                    .keyboardShortcut("0")
                Divider()
                Button("Enclosing Folder") { model.up() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp)
                Button("Open Selection") { model.drillIntoSelection() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(model.selection == nil)
                Button("Disk Overview") { model.goToOverview() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                    .disabled(model.graph == nil || model.atOverview)
                Divider()
                Button("Recommendations") { model.showRecommendations.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.graph == nil)
            }
        }

        // One window per recommendation (openWindow(value:) brings an existing
        // one forward instead of opening a second). Scenes don't inherit the
        // main group's environment, so inject it again. The value is nil when
        // macOS restores the window at relaunch; the view shows an empty state.
        WindowGroup("Recommendation", id: Self.recommendationWindowID, for: String.self) { $recommendationID in
            RecommendationWindowView(recommendationID: recommendationID)
                .environment(model)
                .environment(\.typography, Typography(scale: model.textScale))
                .environment(\.font, .system(size: 13 * model.textScale))
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            VStack(alignment: .leading, spacing: 8) {
                Slider(
                    value: $model.textScale,
                    in: AppModel.minTextScale...AppModel.maxTextScale,
                    step: 0.05
                ) {
                    Text("Text size")
                } minimumValueLabel: {
                    Text("A").font(.system(size: 10))
                } maximumValueLabel: {
                    Text("A").font(.system(size: 20))
                }
                Text("The quick brown fox — \(Int(model.textScale * 100))%")
                    .font(.system(size: 13 * model.textScale))
                    .foregroundStyle(.secondary)
                Text("Also: View menu, or ⌘+ / ⌘− / ⌘0 anywhere.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Divider()
            Toggle("Notify when a scan finishes", isOn: $model.notifyOnScanComplete)
            Text("A macOS notification lists the top things to delete. Allow notifications for MacDiskSleuth when asked.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.phase {
            case .welcome:
                WelcomeView()
            case .scanning:
                ScanProgressView()
            case .results:
                ResultsView()
            }
        }
        .navigationTitle(model.windowTitle)
        .onAppear { model.openWindow = openWindow }
    }
}
