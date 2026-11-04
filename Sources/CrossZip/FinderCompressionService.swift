import AppKit
import Foundation
import CrossZipCore

/// Finder sends the entire selection in one pasteboard. The service only prepares a
/// new compression task; the regular preflight and Save ZIP flow remain in control.
@MainActor
final class FinderCompressionService: NSObject {
    static let menuTitle = "使用 CrossZip 压缩"
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private let model: AppModel
    private let presentWindow: @MainActor () -> Void

    init(model: AppModel, presentWindow: @escaping @MainActor () -> Void = FinderCompressionService.showMainWindow) {
        self.model = model
        self.presentWindow = presentWindow
    }

    @objc(compressSelection:userData:error:)
    func compressSelection(_ pasteboard: NSPasteboard, userData: String?,
                           error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>) {
        errorPointer.pointee = nil
        do {
            guard NSApp?.modalWindow == nil else {
                throw CrossZipError.message("请先完成或关闭 CrossZip 当前的文件选择窗口，再使用右键压缩。")
            }
            let selection = try Self.fileURLs(from: pasteboard)
            try model.prepareCompressionSelection(selection)
            presentWindow()
        } catch { errorPointer.pointee = error.localizedDescription as NSString }
    }

    static func fileURLs(from pasteboard: NSPasteboard) throws -> [URL] {
        let items = pasteboard.pasteboardItems ?? []
        if !items.isEmpty, items.allSatisfy({ $0.types.contains(.fileURL) }),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           urls.count == items.count, urls.allSatisfy(\.isFileURL) {
            return urls
        }
        // Older Finder/services pasteboards carry one array rather than one URL per item.
        if items.count == 1, let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
                throw CrossZipError.message("没有收到完整的本机文件选择，请在 Finder 中重新选择文件。")
            }
            return paths.map { URL(fileURLWithPath: $0) }
        }
        throw CrossZipError.message("没有收到完整的本机文件选择，请在 Finder 中重新选择文件。")
    }

    private static func showMainWindow() {
        let application = NSApplication.shared
        application.unhide(nil)
        if let window = application.windows.first(where: { $0.canBecomeMain }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        application.activate(ignoringOtherApps: true)
    }
}
