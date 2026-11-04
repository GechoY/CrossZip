import AppKit
import XCTest
import CrossZipCore
@testable import CrossZip

@MainActor
final class FinderServiceTests: XCTestCase {
    func testServiceUsesOnlyCurrentMultiSelectionWithSpecialNames() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try put("previous.txt", in: root)
        let first = try put("中文 $() & ' file.txt", in: root)
        let folder = root.appendingPathComponent("资料.zip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        _ = try put("inside.txt", in: folder)
        let model = AppModel()
        model.addSources([old])
        try await waitUntilIdle(model)
        model.mode = .extract
        var presented = false
        let provider = FinderCompressionService(model: model, presentWindow: { presented = true })
        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(board.writeObjects([first as NSURL, folder as NSURL]))
        var error: NSString?
        provider.compressSelection(board, userData: nil, error: &error)
        XCTAssertNil(error)
        XCTAssertTrue(presented)
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .compress)
        XCTAssertEqual(model.sources, [first, folder])
        XCTAssertEqual(model.sourcePlan?.fileCount, 2)
        XCTAssertFalse(model.sourcePlan!.items.contains { $0.url == old })
        XCTAssertTrue(model.canRun)
    }

    func testExplicitCompressServiceDoesNotExtractSelectedZip() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try put("data.txt", in: root)
        let zip = root.appendingPathComponent("input.zip")
        _ = try ArchiveService().compress([source], to: zip)
        let model = AppModel()
        let provider = FinderCompressionService(model: model, presentWindow: {})
        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(board.writeObjects([zip as NSURL]))
        var error: NSString?
        provider.compressSelection(board, userData: nil, error: &error)
        XCTAssertNil(error)
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .compress)
        XCTAssertEqual(model.sources, [zip])
        XCTAssertNil(model.archiveURL)
        XCTAssertTrue(model.canRun)
    }

    func testLegacyFinderFilenamesAreReadAsOneCompleteBatch() throws {
        let paths = ["/tmp/中文 file.txt", "/tmp/Folder with space"]
        let board = NSPasteboard.withUniqueName()
        board.declareTypes([FinderCompressionService.filenamesType], owner: nil)
        XCTAssertTrue(board.setPropertyList(paths, forType: FinderCompressionService.filenamesType))
        XCTAssertEqual(try FinderCompressionService.fileURLs(from: board).map(\.path), paths)
    }

    func testInvalidOrPartialSelectionIsRejectedWithoutChangingInputs() {
        let model = AppModel()
        let provider = FinderCompressionService(model: model, presentWindow: { XCTFail("不应打开窗口") })
        for objects: [NSPasteboardWriting] in [[], ["plain text" as NSString],
                                               [URL(fileURLWithPath: "/tmp/a") as NSURL, "plain text" as NSString],
                                               [URL(string: "https://example.com/archive.zip")! as NSURL]] {
            let board = NSPasteboard.withUniqueName()
            if !objects.isEmpty { XCTAssertTrue(board.writeObjects(objects)) }
            var error: NSString?
            provider.compressSelection(board, userData: nil, error: &error)
            XCTAssertNotNil(error)
            XCTAssertTrue(model.sources.isEmpty)
            XCTAssertFalse(model.isBusy)
        }
    }

    func testBusyTaskIsNotCancelledOrReplacedByAServiceRequest() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try put("original.txt", in: root)
        let other = try put("other.txt", in: root)
        let model = AppModel()
        model.addSources([original])
        XCTAssertTrue(model.isBusy)
        let provider = FinderCompressionService(model: model, presentWindow: { XCTFail("正在处理时应返回提示") })
        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(board.writeObjects([other as NSURL]))
        var error: NSString?
        provider.compressSelection(board, userData: nil, error: &error)
        XCTAssertTrue(error?.contains("另一项任务") == true)
        XCTAssertEqual(model.sources, [original])
        try await waitUntilIdle(model)
        XCTAssertEqual(model.sourcePlan?.fileCount, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testServiceDeclarationMatchesObjectiveCEntryAndLeavesZipAssociationAlternate() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: project.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let services = try XCTUnwrap(info["NSServices"] as? [[String: Any]])
        XCTAssertEqual(services.count, 1)
        let service = try XCTUnwrap(services.first)
        XCTAssertEqual((service["NSMenuItem"] as? [String: String])?["default"], FinderCompressionService.menuTitle)
        let message = try XCTUnwrap(service["NSMessage"] as? String)
        let provider = FinderCompressionService(model: AppModel(), presentWindow: {})
        XCTAssertTrue(provider.responds(to: NSSelectorFromString(message + ":userData:error:")))
        XCTAssertEqual(service["NSPortName"] as? String, info["CFBundleName"] as? String)
        XCTAssertEqual(service["NSSendFileTypes"] as? [String], ["public.item"])
        let documents = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertTrue(documents.allSatisfy { $0["LSHandlerRank"] as? String == "Alternate" })
        let extensions = Set(documents.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] })
        XCTAssertTrue(Set(["zip", "7z", "rar", "tar", "gz", "bz2", "xz"]).isSubset(of: extensions))
    }

    func testModalFileSelectionIsNotReplacedByAServiceRequest() {
        let application = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let session = application.beginModalSession(for: window)
        defer { application.endModalSession(session); window.close() }
        XCTAssertTrue(application.modalWindow === window)
        let model = AppModel()
        let provider = FinderCompressionService(model: model, presentWindow: { XCTFail("文件选择中不应替换当前输入") })
        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(board.writeObjects([URL(fileURLWithPath: "/tmp/selected.txt") as NSURL]))
        var error: NSString?
        provider.compressSelection(board, userData: nil, error: &error)
        XCTAssertTrue(error?.contains("文件选择窗口") == true)
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZipServiceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func put(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("service test".utf8).write(to: url)
        return url
    }

    private func waitUntilIdle(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("文件预检未在 5 秒内完成")
    }
}
