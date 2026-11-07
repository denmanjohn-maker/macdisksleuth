import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var serviceProvider: ServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let provider = ServiceProvider(model: AppModel.shared)
        serviceProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        if ScanNotifier.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Quitting with the last window means a Quick Action always relaunches
    /// into a fresh, visible window. Recommendation windows count: closing the
    /// results window while one is open keeps the app running until that
    /// window closes too.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show the "scan complete" banner even while the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Clicking the banner opens the recommendations.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NSApp.activate()
            if AppModel.shared.graph != nil {
                AppModel.shared.showRecommendations = true
            }
        }
    }
}
