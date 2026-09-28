import AppKit

/// Handles the "Analyze with DiskSleuth" Finder Quick Action / Services menu
/// item declared under NSServices in project.yml.
@MainActor
final class ServiceProvider: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// Selector `analyzeFolder:userData:error:` — must match NSMessage
    /// ("analyzeFolder") in project.yml.
    @objc func analyzeFolder(
        _ pasteboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let url = urls.first else {
            error.pointee = "DiskSleuth didn't receive a folder to analyze." as NSString
            return
        }

        // NSSendFileTypes limits this to folders and volumes, but scan the
        // enclosing folder if a file ever slips through.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let path = exists && !isDirectory.boolValue ? url.deletingLastPathComponent().path : url.path

        model.startScan(path: path)
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
