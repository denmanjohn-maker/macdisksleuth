import SwiftUI

@main
struct DiskSleuthApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
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
