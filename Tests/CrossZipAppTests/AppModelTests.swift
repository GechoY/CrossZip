import XCTest
import Foundation
import CrossZipCore
@testable import CrossZip

@MainActor
final class AppModelTests: XCTestCase {
    func testNewFormatDropAndPartialSelectionKeepChosenFilesOnly() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        for name in ["first.txt", "second.txt"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        let archive = root.appendingPathComponent("files.7z")
        _ = try ArchiveManager().compress([source], to: archive, format: .sevenZip)
        let model = AppModel()
        XCTAssertTrue(model.receive([archive]))
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .extract)
        XCTAssertEqual(model.inspection?.formatName, "7z")
        XCTAssertTrue(model.allEntriesSelected)
        let file = try XCTUnwrap(model.inspection?.records.first { $0.path == "input/first.txt" })
        model.toggleEntry(file.id)
        XCTAssertFalse(model.selectedEntryIDs.contains(file.id))
        XCTAssertFalse(model.allEntriesSelected)
        XCTAssertTrue(model.canRun)
        let folder = try XCTUnwrap(model.previewItems.first { $0.path == "input" })
        XCTAssertTrue(model.isPartiallySelected(folder))
        model.selectAllEntries()
        XCTAssertTrue(model.allEntriesSelected)
        model.selectAllEntries()
        XCTAssertFalse(model.canRun)
        model.toggleEntry(file.id)
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.selectedCount, 1)
        model.verifyArchive()
        try await waitUntilIdle(model)
        XCTAssertTrue(model.verified)
        XCTAssertEqual(model.selectedEntryIDs, [file.id], "校验不应把用户取消的条目重新勾选")
        model.selectAllEntries()
        model.selectAllEntries()
        model.verifyArchive()
        try await waitUntilIdle(model)
        XCTAssertTrue(model.selectedEntryIDs.isEmpty)
        XCTAssertFalse(model.canRun)
    }

    func testFolderWithNewArchiveSuffixIsStillACompressionInput() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder.7z")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("data".utf8).write(to: folder.appendingPathComponent("file"))
        let model = AppModel()
        XCTAssertTrue(model.receive([folder]))
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .compress)
        XCTAssertTrue(model.canRun)
    }

    func testWindowsIncompatibleNamesKeepSaveEnabledAndKeepExactNames() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["CON.txt", "报告?.txt", "tail."]
        for name in names { try Data("原样内容".utf8).write(to: root.appendingPathComponent(name)) }
        let model = AppModel()
        model.addSources([root])
        try await waitUntilIdle(model)
        XCTAssertTrue(model.canRun)
        XCTAssertTrue(model.blockers.isEmpty)
        XCTAssertEqual(model.fileCount, names.count)
        XCTAssertFalse(model.issues.isEmpty)
        XCTAssertEqual(Set(model.previewItems.filter { $0.kind == .file }.map(\.path)),
                       Set(names.map { root.lastPathComponent + "/" + $0 }))
        XCTAssertNil(model.errorMessage)
    }

    func testFolderNamedZipIsCompressedInsteadOfOpenedAsAnArchive() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("资料.zip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("文件夹内容".utf8).write(to: folder.appendingPathComponent("内容.txt"))

        let model = AppModel()
        XCTAssertTrue(model.receive([folder]))
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .compress)
        XCTAssertEqual(model.sources, [folder])
        XCTAssertEqual(model.sourcePlan?.fileCount, 1)
        XCTAssertNil(model.archiveURL)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canRun)
    }

    func testFolderDropSwitchesFromExtractionToCompression() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("folder content".utf8).write(to: root.appendingPathComponent("readme.txt"))
        let model = AppModel()
        model.mode = .extract

        XCTAssertTrue(model.receive([root]))
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .compress)
        XCTAssertEqual(model.sources, [root])
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canRun)
    }

    func testOrdinaryFileDropSwitchesFromExtractionToCompression() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("readme.txt")
        try Data("file content".utf8).write(to: file)
        let model = AppModel()
        model.mode = .extract

        XCTAssertTrue(model.receive([file]))
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .compress)
        XCTAssertEqual(model.sourcePlan?.fileCount, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canRun)
    }

    func testSingleZipFileSwitchesToExtraction() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("readme.txt")
        try Data("file content".utf8).write(to: source)
        let archive = root.appendingPathComponent("input.zip")
        _ = try ArchiveService().compress([source], to: archive)
        let model = AppModel()

        XCTAssertTrue(model.receive([archive]))
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .extract)
        XCTAssertEqual(model.archiveURL, archive)
        XCTAssertEqual(model.inspection?.fileCount, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canRun)
    }

    func testMultipleZipFilesAreCompressionInputs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("readme.txt")
        try Data("file content".utf8).write(to: source)
        let archives = [root.appendingPathComponent("first.zip"), root.appendingPathComponent("second.zip")]
        for archive in archives { _ = try ArchiveService().compress([source], to: archive) }
        let model = AppModel()
        model.mode = .extract

        XCTAssertTrue(model.receive(archives))
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .compress)
        XCTAssertEqual(model.sourcePlan?.fileCount, 2)
        XCTAssertEqual(model.sources, archives)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canRun)
    }

    func testSymlinkNamedZipIsPackedAsTheOriginalLink() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("readme.txt")
        try Data("original bytes".utf8).write(to: target)
        let link = root.appendingPathComponent("linked.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let model = AppModel()
        XCTAssertTrue(model.receive([link]))
        try await waitUntilIdle(model)
        XCTAssertEqual(model.mode, .compress)
        XCTAssertEqual(model.sourcePlan?.items.first?.kind, .symlink)
        XCTAssertTrue(model.canRun)
        XCTAssertNil(model.errorMessage)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZipAppTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func waitUntilIdle(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("后台预检应在 5 秒内完成")
    }
}
