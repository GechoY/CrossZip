import XCTest
import Foundation
import CryptoKit
@testable import CrossZipCore

final class CompressionWorkflowTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZip-Workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func put(_ path: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    func testAllFormatsEncloseMultipleInputsAndKeepOnlyIncludedOriginalBytes() throws {
        let first = try put("first.swift", Data("原始文字\r\n".utf8))
        let second = try put("code/second.bin", Data((0...255).map(UInt8.init)))
        let omitted = try put("code/wrong.txt", Data("wrong".utf8))
        let sources = [first, second.deletingLastPathComponent()]
        for format in ArchiveFormat.allCases {
            let destination = root.appendingPathComponent("result." + format.rawValue)
            _ = try ArchiveManager().compress(sources, to: destination, format: format, excluding: [omitted], enclosingFolderName: "项目代码")
            let inspection = try ArchiveManager().verify(destination)
            XCTAssertEqual(Set(inspection.records.map(\.path)), ["项目代码", "项目代码/first.swift", "项目代码/code", "项目代码/code/second.bin"])
            let output = try ArchiveManager().extract(inspection, to: root)
            for (source, path) in [(first, "first.swift"), (second, "code/second.bin")] {
                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)),
                               SHA256.hash(data: try Data(contentsOf: output.url.appendingPathComponent("项目代码/" + path))))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: omitted.path), "移除不能删除磁盘原文件")
        }
    }

    func testExcludedDirectoryCanRestoreOneExplicitChildWithoutRestoringSiblings() throws {
        let first = try put("source/removed/first.txt", Data("first".utf8))
        let second = try put("source/removed/second.txt", Data("second".utf8))
        _ = try put("source/keep.txt", Data("keep".utf8))
        let removed = first.deletingLastPathComponent(), source = removed.deletingLastPathComponent()
        let plan = try SourceScanner.scan([source, first], excluding: [removed])
        XCTAssertEqual(plan.rootCount, 1)
        XCTAssertTrue(plan.items.contains { $0.url.path == first.path })
        XCTAssertFalse(plan.items.contains { $0.url.path == second.path })
        let archive = root.appendingPathComponent("restored.zip")
        _ = try ArchiveManager().compress([source, first], to: archive, excluding: [removed])
        let paths = try ArchiveManager().verify(archive).records.map(\.path)
        XCTAssertTrue(paths.contains("source/removed/first.txt"))
        XCTAssertFalse(paths.contains("source/removed/second.txt"))
    }

    func testZIPLevelsActuallyChangeCompressionAndDefaultUsesMaximum() throws {
        let source = try put("pattern.txt", Data(String(repeating: "compression patterns 1234567890 原始内容\n", count: 50000).utf8))
        var sizes: [CompressionLevel: Int] = [:]
        for level in CompressionLevel.allCases {
            let archive = root.appendingPathComponent("level-\(level.rawValue).zip")
            _ = try ArchiveManager().compress([source], to: archive, level: level)
            sizes[level] = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            XCTAssertEqual(try ZIPInspector.inspect(archive).records.first?.method, 8)
        }
        XCTAssertLessThan(sizes[.maximum]!, sizes[.fast]!)
        let archive = root.appendingPathComponent("default.zip")
        _ = try ArchiveManager().compress([source], to: archive)
        XCTAssertEqual(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize, sizes[.maximum])
    }

    func testSmallSelectionEstimatesUseActualCodecsForEveryFormat() throws {
        let first = try put("代码/中文.swift", Data(String(repeating: "let channel = 42\n", count: 200).utf8))
        _ = try put("代码/empty", Data())
        let source = first.deletingLastPathComponent()
        let plan = try SourceScanner.scan([source])
        for format in ArchiveFormat.allCases {
            let estimate = try ArchiveEstimator.estimate(plan, format: format, enclosingFolderName: "估算")
            let archive = root.appendingPathComponent("estimate." + format.rawValue)
            _ = try ArchiveManager().compress([source], to: archive, format: format, enclosingFolderName: "估算")
            let actual = Int64(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
            XCTAssertFalse(estimate.isSampled)
            XCTAssertLessThanOrEqual(abs(Int64(estimate.bytes) - actual), 2048, format.rawValue)
        }
    }

    func testSizePriorityNeverExceedsOtherExposedLevelsForMixedData() throws {
        var generator: UInt64 = 20261104
        let random = Data((0..<(256 * 1024)).map { _ -> UInt8 in
            generator = generator &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: generator >> 32)
        })
        let first = try put("mixed/random.bin", random)
        _ = try put("mixed/text.csv", Data(String(repeating: "channel,1,2,3\n", count: 25000).utf8))
        let source = first.deletingLastPathComponent()
        for format in ArchiveFormat.allCases where format.supportsLevel {
            var sizes: [CompressionLevel: Int] = [:]
            for level in CompressionLevel.allCases {
                let output = root.appendingPathComponent("mixed-\(level.rawValue)." + format.rawValue)
                _ = try ArchiveManager().compress([source], to: output, format: format, level: level)
                sizes[level] = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            }
            XCTAssertLessThanOrEqual(sizes[.maximum]!, sizes[.standard]!, format.rawValue)
            XCTAssertLessThanOrEqual(sizes[.maximum]!, sizes[.fast]!, format.rawValue)
        }
    }

    func testLargeEstimationIsBoundedAndCancellationDoesNotModifySource() throws {
        let bytes = Data(repeating: 37, count: 10 * 1024 * 1024)
        let source = try put("large.bin", bytes)
        let plan = try SourceScanner.scan([source])
        let estimate = try ArchiveEstimator.estimate(plan, format: .zip)
        XCTAssertTrue(estimate.isSampled)
        XCTAssertLessThanOrEqual(estimate.sampledBytes, UInt64(ArchiveEstimator.sampleLimit))
        XCTAssertEqual(estimate.sampledFileCount, 1)
        XCTAssertEqual(estimate.totalFileCount, 1)
        XCTAssertEqual(estimate.sourceFileBytes, UInt64(bytes.count))
        XCTAssertLessThan(estimate.bytes, UInt64(bytes.count / 2))
        let context = JobContext(); context.cancel()
        XCTAssertThrowsError(try ArchiveEstimator.estimate(plan, format: .zip, context: context))
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), SHA256.hash(data: bytes))
    }

    func testNumberedOutputNamesRespectExistingFilesAndBrokenLinks() throws {
        _ = try put("archive.zip", Data("keep".utf8))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("archive (2).zip").path, withDestinationPath: "missing")
        XCTAssertEqual(OutputNames.availableArchiveURL(for: "archive", format: .zip, in: root).lastPathComponent, "archive (3).zip")
        let source = try put("input.txt", Data())
        let unsafe = try SourceScanner.scan([source], enclosingFolderName: "../outside")
        XCTAssertFalse(unsafe.canProceed)
    }
}
