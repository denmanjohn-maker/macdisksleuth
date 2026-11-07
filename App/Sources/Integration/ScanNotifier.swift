import AppKit
import MacDiskSleuthKit
import UserNotifications

/// Posts the "scan complete — here's what to delete" banner.
@MainActor
enum ScanNotifier {
    /// Notifications need an app bundle; running the bare binary has none.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func post(report: RecommendationReport, scannedPath: String) async {
        guard isAvailable else { return }
        let granted =
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]))
            ?? false
        guard granted else { return }

        let top = Array(report.recommendations.prefix(3))
        let content = UNMutableNotificationContent()
        if top.isEmpty {
            content.title = "Scan complete"
            content.body = "Nothing obvious to delete in \(lastComponent(scannedPath))."
        } else {
            let shown = top.reduce(Int64(0)) { $0 + $1.freeable }
            content.title = "Up to \(ByteCount.format(shown)) can be freed"
            content.subtitle = lastComponent(scannedPath)
            content.body = top.enumerated()
                .map { "\($0.offset + 1). \($0.element.title) — \(ByteCount.format($0.element.freeable))" }
                .joined(separator: "\n")
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "scan-complete-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
