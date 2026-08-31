import SwiftUI

@main
struct DiskSleuthApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
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
            }
        }

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
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

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
    }
}
