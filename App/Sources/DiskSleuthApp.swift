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
