import XCTest
import Foundation
@testable import CrossZipCore
@testable import CrossZip

@MainActor
final class WorkflowTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZip-App-Workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func put(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((path + "\r\n原始内容").utf8).write(to: url)
        return url
    }
    private func idle(_ model: AppModel) async throws {
        for _ in 0..<1000 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("任务未在预期时间完成")
    }

    func testDefaultSaveLocationCreatesOneOuterFolderAndAvoidsOverwrite() async throws {
        let first = try put("first.swift"), second = try put("second.swift")
        let model = AppModel()
        XCTAssertEqual(model.level, .maximum)
        model.addSources([first, second]); try await idle(model)
        model.archiveName = "项目代码"
        XCTAssertEqual(model.effectiveSaveDirectory?.path, root.path)
        XCTAssertEqual(model.enclosingFolderName, "项目代码")
        model.start(); try await idle(model)
        let output = try XCTUnwrap(model.result?.url)
        XCTAssertEqual(output.lastPathComponent, "项目代码.zip")
        let paths = try ArchiveManager().verify(output).records.map(\.path)
        XCTAssertEqual(Set(paths), ["项目代码", "项目代码/first.swift", "项目代码/second.swift"])
        model.start(); try await idle(model)
        XCTAssertEqual(model.result?.url.lastPathComponent, "项目代码 (2).zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testCustomSaveLocationAndClearingItRestoreOriginalDirectory() async throws {
        let file = try put("source/file.txt"), directory = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let model = AppModel(); model.addSources([file]); try await idle(model)
        model.saveDirectory = directory
        model.start(); try await idle(model)
        XCTAssertEqual(model.result?.url.deletingLastPathComponent().path, directory.path)
        model.saveDirectory = nil
        XCTAssertEqual(model.effectiveSaveDirectory?.path, file.deletingLastPathComponent().path)
        model.archiveName = "bad/name"
        XCTAssertFalse(model.canRun)
    }

    func testRemovingNestedContentAndReaddingOneFileKeepsOriginals() async throws {
        let first = try put("source/removed/one.txt"), second = try put("source/removed/two.txt")
        _ = try put("source/keep.txt")
        let source = first.deletingLastPathComponent().deletingLastPathComponent()
        let model = AppModel(); model.addSources([source]); try await idle(model)
        let item = try XCTUnwrap(model.previewItems.first { $0.path == "source/removed" })
        model.removeItem(item); try await idle(model)
        XCTAssertFalse(model.previewItems.contains { $0.path.hasPrefix("source/removed") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        model.addSources([first]); try await idle(model)
        XCTAssertNil(model.enclosingFolderName)
        XCTAssertTrue(model.previewItems.contains { $0.path == "source/removed/one.txt" })
        XCTAssertFalse(model.previewItems.contains { $0.path == "source/removed/two.txt" })
        model.clear()
        XCTAssertTrue(model.sources.isEmpty); XCTAssertTrue(model.omittedURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testAppearanceDefaultsToSystemAndPersistsExplicitChoice() throws {
        let domain = "CrossZip-Test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = AppModel(defaults: defaults)
        XCTAssertEqual(first.appearance, .system)
        first.appearance = .dark
        let second = AppModel(defaults: defaults)
        XCTAssertEqual(second.appearance, .dark)
        second.appearance = .system
        XCTAssertNil(second.appearance.colorScheme)
    }

    func testBackgroundEstimateCompletesAndClearRemovesStaleResult() async throws {
        let file = try put("estimate.txt")
        let model = AppModel(estimatesEnabled: true)
        model.addSources([file]); try await idle(model)
        for _ in 0..<1000 {
            if !model.isEstimating && model.estimate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.estimate, model.estimateError ?? "")
        XCTAssertTrue(model.canRun)
        model.clear()
        XCTAssertNil(model.estimate); XCTAssertFalse(model.isEstimating)
    }

    func testTerminationWaitsForBackgroundEstimateCleanup() async throws {
        let file = try put("cancel-estimate.txt")
        let model = AppModel(estimatesEnabled: true)
        model.addSources([file]); try await idle(model)
        XCTAssertTrue(model.hasBackgroundWork)
        let completed = expectation(description: "取消估算并等待临时文件清理")
        model.cancelForTermination { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertFalse(model.hasBackgroundWork)
        XCTAssertFalse(model.isEstimating)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testSampleEstimateShowsRoundedPointAndMeasuredCoverageInsteadOfInventedBounds() {
        let model = AppModel()
        model.estimate = ArchiveSizeEstimate(bytes: 61_600_000_000, sampledBytes: 8_388_608, isSampled: true,
                                             sampledFileCount: 24, totalFileCount: 48_126, sourceFileBytes: 78_000_000_000)
        XCTAssertTrue(model.estimateDescription.hasPrefix("粗估 "))
        XCTAssertTrue(model.estimateDescription.contains("62"))
        XCTAssertFalse(model.estimateDescription.contains("–"))
        XCTAssertTrue(model.estimateDetail.contains("24 / 48126"))
        XCTAssertTrue(model.estimateDetail.contains("0.01%"))
        XCTAssertFalse(model.estimateDetail.contains("30%"))
    }
}
