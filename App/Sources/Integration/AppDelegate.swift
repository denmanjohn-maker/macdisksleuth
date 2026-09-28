import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var serviceProvider: ServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let provider = ServiceProvider(model: AppModel.shared)
        serviceProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    }

    /// Single-window utility: quitting with the window means a Quick Action
    /// always relaunches into a fresh, visible window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
