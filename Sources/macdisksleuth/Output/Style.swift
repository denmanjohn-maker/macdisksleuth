import Darwin
import Foundation

/// Minimal ANSI styling, enabled only when writing to a TTY (or forced off).
struct Style: Sendable {
    var enabled: Bool

    init(noColor: Bool, fd: CInt = STDOUT_FILENO) {
        let envNoColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        self.enabled = !noColor && !envNoColor && isatty(fd) == 1
    }

    private func wrap(_ text: String, _ codes: String) -> String {
        enabled ? "\u{1B}[\(codes)m\(text)\u{1B}[0m" : text
    }

    func bold(_ text: String) -> String { wrap(text, "1") }
    func dim(_ text: String) -> String { wrap(text, "2") }
    func blue(_ text: String) -> String { wrap(text, "34") }
    func cyan(_ text: String) -> String { wrap(text, "36") }
    func green(_ text: String) -> String { wrap(text, "32") }
    func yellow(_ text: String) -> String { wrap(text, "33") }
    func red(_ text: String) -> String { wrap(text, "31") }
    func boldBlue(_ text: String) -> String { wrap(text, "1;34") }
}
