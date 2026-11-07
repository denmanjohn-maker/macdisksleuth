import Foundation

/// Posts a macOS user notification from a plain command-line process through
/// osascript — no app bundle or entitlement needed, so scheduled scans can
/// announce their findings. Best effort: a headless session or disabled
/// AppleScript simply yields no notification.
public enum UserNotifier {
    public static func post(title: String, body: String, subtitle: String? = nil) async {
        func quoted(_ text: String) -> String {
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " · ")
            return "\"" + escaped + "\""
        }
        var script = "display notification \(quoted(body)) with title \(quoted(title))"
        if let subtitle { script += " subtitle \(quoted(subtitle))" }
        _ = try? await Subprocess.run("/usr/bin/osascript", ["-e", script], timeout: .seconds(10))
    }
}
