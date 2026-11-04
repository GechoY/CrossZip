import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import CrossZipCore

final class MultiFormatTests: XCTestCase {
    private var root: URL!
    private let manager = ArchiveManager()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZip-Multi-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func put(_ path: String, data: Data = Data()) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    private func noPartialResults() throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".crosszip-") })
    }

    func testEveryWritableFormatPreservesNamesHierarchyBytesAndLinks() throws {
        let source = root.appendingPathComponent("原样资料")
        let payloads = ["中文🙂.txt": Data("原文\r\n不转换".utf8), ".gitignore": Data("build/\n".utf8),
                        ".DS_Store": Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]), "._真实内容": Data("real".utf8),
                        "a?.txt": Data("question".utf8), "a\\b.bin": Data((0...255).map(UInt8.init)),
                        "CON.txt": Data(), "line\nfeed": Data("new line in name".utf8),
                        "深层/数据.bin": Data(repeating: 19, count: 131_073)]
        for (name, data) in payloads { try put("原样资料/" + name, data: data) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("空目录"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "中文🙂.txt")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("broken").path, withDestinationPath: "missing")
        let plan = try SourceScanner.scan([source])
        for format in ArchiveFormat.allCases {
            let archive = root.appendingPathComponent("roundtrip." + format.rawValue)
            let result = try manager.compress([source], to: archive, format: format)
            XCTAssertEqual(result.fileCount, payloads.count + 2)
            let inspection = try manager.verify(archive)
            XCTAssertTrue(inspection.canProceed)
            XCTAssertEqual(Set(inspection.records.map { Data($0.path.utf8) }), Set(plan.items.map { Data($0.path.utf8) }), format.rawValue)
            let output = try manager.extract(inspection, to: root)
            for (name, data) in payloads {
                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: output.url.appendingPathComponent("原样资料/" + name))), SHA256.hash(data: data), format.rawValue + ":" + name)
                XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(name)), data)
            }
            for link in ["link", "broken"] {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: output.url.appendingPathComponent("原样资料/" + link).path),
                               try FileManager.default.destinationOfSymbolicLink(atPath: source.appendingPathComponent(link).path))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.url.appendingPathComponent("原样资料/空目录").path))
        }
        try noPartialResults()
    }

    func testSelectiveExtractionInEveryFormatIncludesOnlyChosenFileAndParents() throws {
        let first = try put("source/sub/first.txt", data: Data("chosen".utf8))
        _ = try put("source/sub/other.txt", data: Data("not chosen".utf8))
        for format in ArchiveFormat.allCases {
            let archive = root.appendingPathComponent("subset." + format.rawValue)
            _ = try manager.compress([root.appendingPathComponent("source")], to: archive, format: format)
            let inspection = try manager.inspect(archive)
            let file = try XCTUnwrap(inspection.records.first { $0.path == "source/sub/first.txt" })
            let output = try manager.extract(inspection, to: root, selectedIDs: [file.id])
            XCTAssertEqual(output.fileCount, 1)
            XCTAssertEqual(try Data(contentsOf: output.url.appendingPathComponent(file.path)), try Data(contentsOf: first))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.url.appendingPathComponent("source/sub/other.txt").path))
            XCTAssertThrowsError(try manager.extract(inspection, to: root, selectedIDs: []))
            XCTAssertThrowsError(try manager.extract(inspection, to: root, selectedIDs: [999_999]))
        }
        try noPartialResults()
    }

    func testChoosingDirectoryIncludesItsEntireSubtree() throws {
        _ = try put("source/chosen/a", data: Data("a".utf8))
        _ = try put("source/chosen/deep/b", data: Data("b".utf8))
        _ = try put("source/other", data: Data("other".utf8))
        let archive = root.appendingPathComponent("directory.7z")
        _ = try manager.compress([root.appendingPathComponent("source")], to: archive, format: .sevenZip)
        let inspection = try manager.inspect(archive)
        let folder = try XCTUnwrap(inspection.records.first { $0.path == "source/chosen" })
        let output = try manager.extract(inspection, to: root, selectedIDs: [folder.id])
        XCTAssertEqual(output.fileCount, 2)
        XCTAssertEqual(try Data(contentsOf: output.url.appendingPathComponent("source/chosen/deep/b")), Data("b".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.url.appendingPathComponent("source/other").path))
    }

    func testZIPStoreOptionAndGzipCompressionLevelsAffectActualOutput() throws {
        let source = try put("pattern.bin", data: Data(repeating: 37, count: 1_000_000))
        let stored = root.appendingPathComponent("stored.zip")
        _ = try manager.compress([source], to: stored, storeOnly: true)
        XCTAssertTrue(try ZIPInspector.inspect(stored).records.allSatisfy { $0.method == 0 })
        XCTAssertGreaterThan(try FileFingerprint.read(stored).size, 1_000_000)
        let fast = root.appendingPathComponent("fast.tar.gz"), small = root.appendingPathComponent("small.tar.gz")
        _ = try manager.compress([source], to: fast, format: .tarGzip, level: .fast)
        _ = try manager.compress([source], to: small, format: .tarGzip, level: .maximum)
        XCTAssertLessThan(try FileFingerprint.read(small).size, try FileFingerprint.read(fast).size)
        XCTAssertNoThrow(try manager.verify(small))
    }

    func testTARFilenameBeginningWithPKIsNotMistakenForZIP() throws {
        let payload = Data("original bytes\r\n原文".utf8)
        let archive = try put("pk-name.tar", data: tarEntry("PK_report.txt", data: payload) + Data(repeating: 0, count: 1024))
        let inspection = try manager.verify(archive)
        XCTAssertEqual(inspection.formatName, "TAR")
        XCTAssertEqual(inspection.records.map(\.path), ["PK_report.txt"])
        let output = try manager.extract(inspection, to: root)
        XCTAssertEqual(try Data(contentsOf: output.url.appendingPathComponent("PK_report.txt")), payload)
        try noPartialResults()
    }

    func testEmptyZIPAndZIP64StillUseStrictZIPInspection() throws {
        var empty = Data([0x50, 0x4b, 0x05, 0x06])
        empty.append(Data(repeating: 0, count: 18))
        let zip = try put("empty.zip", data: empty)
        XCTAssertEqual(try manager.verify(zip).formatName, "ZIP")

        func little(_ value: UInt64, _ width: Int) -> Data {
            Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        var zip64 = little(0x06064b50, 4) + little(44, 8)
        zip64.append(little(45, 2) + little(45, 2))
        zip64.append(Data(repeating: 0, count: 40))
        zip64.append(little(0x07064b50, 4) + little(0, 4) + little(0, 8) + little(1, 4))
        zip64.append(little(0x06054b50, 4) + little(0, 4))
        zip64.append(little(0xffff, 2) + little(0xffff, 2))
        zip64.append(little(0xffffffff, 4) + little(0xffffffff, 4) + little(0, 2))
        let large = try put("empty-zip64.zip", data: zip64)
        let inspection = try manager.verify(large)
        XCTAssertEqual(inspection.formatName, "ZIP64")
        XCTAssertTrue(inspection.records.isEmpty)
        _ = try manager.extract(inspection, to: root)
    }

    func testHardlinkChainsAndForwardReferencesRestoreBytesWhenOnlyAliasIsSelected() throws {
        let archive = root.appendingPathComponent("hardlinks.tar")
        var data = tarEntry("alias.txt", type: "1", link: "middle.txt")
        data.append(tarEntry("middle.txt", type: "1", link: "original.txt"))
        data.append(tarEntry("original.txt", data: Data("original bytes".utf8)))
        data.append(Data(repeating: 0, count: 1024)); try data.write(to: archive)
        let inspection = try manager.inspect(archive)
        let alias = try XCTUnwrap(inspection.records.first { $0.path == "alias.txt" })
        XCTAssertEqual(alias.size, 14)
        let result = try manager.extract(inspection, to: root, selectedIDs: [alias.id])
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("alias.txt")), Data("original bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.url.appendingPathComponent("original.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.url.appendingPathComponent("middle.txt").path))
    }

    func testUnsafeDuplicateAndLinkAncestorTARsNeverPublish() throws {
        let inputs = [tarEntry("../escape", data: Data("bad".utf8)),
                      tarEntry("/absolute", data: Data()),
                      tarEntry("a", data: Data()) + tarEntry("a", data: Data()),
                      tarEntry("link", type: "2", link: "../../outside") + tarEntry("link/file", data: Data("bad".utf8))]
        for (index, data) in inputs.enumerated() {
            let archive = try put("unsafe\(index).tar", data: data + Data(repeating: 0, count: 1024))
            let inspection = try manager.inspect(archive)
            XCTAssertFalse(inspection.canProceed)
            XCTAssertThrowsError(try manager.extract(inspection, to: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unsafe\(index)").path))
        }
        try noPartialResults()
    }

    func testTruncatedNewFormatsAndBrokenTARTrailerAreRejected() throws {
        let source = try put("data.bin", data: Data(repeating: 71, count: 100_000))
        for format in ArchiveFormat.allCases where format != .zip {
            let archive = root.appendingPathComponent("damaged." + format.rawValue)
            _ = try manager.compress([source], to: archive, format: format)
            var data = try Data(contentsOf: archive)
            data.removeLast(format == .tar ? 512 : 12)
            try data.write(to: archive)
            XCTAssertThrowsError(try manager.inspect(archive), format.rawValue)
        }
        try noPartialResults()
    }

    func testCancellationAndSourceMutationCleanUpEveryNewFormat() throws {
        let source = try put("data.bin", data: Data(repeating: 1, count: 131_072))
        for format in ArchiveFormat.allCases where format != .zip {
            let archive = root.appendingPathComponent("cancelled." + format.rawValue)
            let box = NativeTestState()
            let context = JobContext { update in if update.phase == .compressing { box.context?.cancel() } }
            box.context = context
            XCTAssertThrowsError(try manager.compress([source], to: archive, format: format, context: context))
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
            try noPartialResults()
        }
        let box = NativeTestState()
        let context = JobContext { update in
            if update.phase == .verifying && !box.changed {
                box.changed = true
                try! Data("changed".utf8).write(to: source)
            }
        }
        let output = root.appendingPathComponent("changed.7z")
        XCTAssertThrowsError(try manager.compress([source], to: output, format: .sevenZip, context: context))
        XCTAssertTrue(box.changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try noPartialResults()
    }

    func testExternalRARAndRAR5FixturesRestoreExpectedContentsAndLinks() throws {
        let rar = try XCTUnwrap(Bundle.module.url(forResource: "test_read_format_rar.rar", withExtension: nil, subdirectory: "Fixtures"))
        let first = try manager.inspect(rar)
        XCTAssertEqual(first.formatName, "RAR")
        XCTAssertEqual(first.records.count, 5)
        let result = try manager.extract(first, to: root)
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("test.txt")), Data("test text document\r\n".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: result.url.appendingPathComponent("testlink").path), "test.txt")
        let rar5 = try XCTUnwrap(Bundle.module.url(forResource: "test_read_format_rar5_solid.rar", withExtension: nil, subdirectory: "Fixtures"))
        let second = try manager.verify(rar5)
        XCTAssertEqual(second.formatName, "RAR5")
        XCTAssertEqual(second.fileCount, 7)
        XCTAssertEqual(second.totalBytes, 25_776)
        let extracted = try manager.extract(second, to: root)
        for member in second.records {
            XCTAssertEqual(FileSupport.crc(try Data(contentsOf: extracted.url.appendingPathComponent(member.path))), member.checksum)
        }
    }

    func testEncryptedRARIsExplicitlyRejected() throws {
        let rar = try XCTUnwrap(Bundle.module.url(forResource: "test_read_format_rar_encryption_header.rar", withExtension: nil, subdirectory: "Fixtures"))
        XCTAssertThrowsError(try manager.inspect(rar))
    }

    func testIgnoredUpstream7zSymlinkCRCErrorIsStillRejected() throws {
        let archive = try XCTUnwrap(Bundle.module.url(forResource: "corrupt-symlink-crc.7z", withExtension: nil, subdirectory: "Fixtures"))
        XCTAssertThrowsError(try manager.inspect(archive)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("crc"))
        }
    }

    func testGzipCRCSizeConcatenationAndEmptyFiles() throws {
        let valid = gzipFixture(Data("hello".utf8), name: "中文.txt")
        let archive = try put("original.gz", data: valid)
        let inspection = try manager.inspect(archive)
        XCTAssertEqual(inspection.records.first?.path, "中文.txt")
        let output = try manager.extract(inspection, to: root)
        XCTAssertEqual(try Data(contentsOf: output.url.appendingPathComponent("中文.txt")), Data("hello".utf8))
        for offset in [valid.count - 8, valid.count - 4] {
            var bad = valid; bad[offset] ^= 1
            let url = try put("bad\(offset).gz", data: bad)
            XCTAssertThrowsError(try manager.inspect(url))
        }
        let joined = try put("joined.txt.gz", data: gzipFixture(Data("one".utf8)) + gzipFixture(Data("two".utf8)))
        let joinedOutput = try manager.extract(manager.inspect(joined), to: root)
        XCTAssertEqual(try Data(contentsOf: joinedOutput.url.appendingPathComponent("joined.txt")), Data("onetwo".utf8))
        let empty = try put("empty.gz", data: gzipFixture(Data(), name: "zero.txt"))
        let emptyOutput = try manager.extract(manager.inspect(empty), to: root)
        XCTAssertEqual(try Data(contentsOf: emptyOutput.url.appendingPathComponent("zero.txt")), Data())
        let padded = try put("padded.gz", data: valid + Data(repeating: 0, count: 17))
        XCTAssertNoThrow(try manager.verify(padded))
        let junk = try put("junk.gz", data: valid + Data("junk".utf8))
        XCTAssertThrowsError(try manager.verify(junk))
    }

    func testReadOnlyDestinationDoesNotLeaveFormalOrTemporaryOutput() throws {
        let source = try put("input", data: Data("readable".utf8))
        let parent = root.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        XCTAssertThrowsError(try manager.compress([source], to: parent.appendingPathComponent("output.7z"), format: .sevenZip))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testCABAndCPIOReferenceArchivesCanBeReadAndExtracted() throws {
        for name in ["test_read_format_cab_1.cab", "test_read_format_cpio_filename_utf8_jp.cpio"] {
            let archive = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            let inspection = try manager.inspect(archive)
            XCTAssertTrue(inspection.canProceed)
            let output = try manager.extract(inspection, to: root)
            for member in inspection.records where member.kind == .file {
                XCTAssertEqual(FileSupport.crc(try Data(contentsOf: output.url.appendingPathComponent(member.path))), member.checksum)
            }
        }
    }

    func testSingleCompressedStreamsPreserveZeroBlocksAndOnlyUnwrapOneLayer() throws {
        let contents = [Data(repeating: 0, count: 4096), Data(repeating: 0, count: 1024) + Data("original".utf8),
                        tarEntry("inside", data: Data("TAR payload".utf8)) + Data(repeating: 0, count: 1024)]
        for (number, data) in contents.enumerated() {
            let archive = try put("single-\(number).gz", data: gzipFixture(data))
            let inspection = try manager.verify(archive)
            XCTAssertEqual(inspection.fileCount, 1)
            let output = try manager.extract(inspection, to: root)
            XCTAssertEqual(try Data(contentsOf: output.url.appendingPathComponent("single-\(number)")), data)
        }
        let combined = try put("archive.tar.gz", data: gzipFixture(contents[2]))
        let output = try manager.extract(manager.inspect(combined), to: root)
        XCTAssertEqual(try Data(contentsOf: output.url.appendingPathComponent("inside")), Data("TAR payload".utf8))
    }

    func testInputNamedAsArchiveFolderStillScansAndCompoundOutputNamesAreCorrect() {
        XCTAssertEqual(OutputNames.archiveName(for: "资料", format: .tarGzip), "资料.tar.gz")
        XCTAssertEqual(ArchiveFormat.stem(of: URL(fileURLWithPath: "/tmp/资料.tar.xz")), "资料")
        XCTAssertTrue(ArchiveFormat.recognizes(URL(fileURLWithPath: "/tmp/test.7z")))
        XCTAssertTrue(ArchiveFormat.recognizes(URL(fileURLWithPath: "/tmp/test.RAR")))
    }
}

private final class NativeTestState: @unchecked Sendable {
    var context: JobContext?
    var changed = false
}

/// Minimal independent USTAR fixtures, including structures no normal writer emits.
private func tarEntry(_ name: String, type: String = "0", link: String = "", data: Data = Data()) -> Data {
    var header = Data(repeating: 0, count: 512)
    func field(_ offset: Int, _ length: Int, _ text: String) {
        let bytes = Data(text.utf8)
        precondition(bytes.count <= length)
        header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
    field(0, 100, name); field(100, 8, "0000644\0"); field(108, 8, "0000000\0"); field(116, 8, "0000000\0")
    field(124, 12, String(format: "%011llo", UInt64(data.count)) + "\0")
    field(136, 12, "00000000000\0"); field(148, 8, "        "); field(156, 1, type)
    field(157, 100, link); field(257, 6, "ustar\0"); field(263, 2, "00")
    let checksum = header.reduce(0) { $0 + Int($1) }
    field(148, 8, String(format: "%06o", checksum) + "\0 ")
    header.append(data)
    if data.count % 512 != 0 { header.append(Data(repeating: 0, count: 512 - data.count % 512)) }
    return header
}

private func gzipFixture(_ data: Data, name: String? = nil) -> Data {
    precondition(data.count < 65_536)
    var result = Data([0x1f, 0x8b, 8, name == nil ? 0 : 8, 0, 0, 0, 0, 0, 255])
    if let name { result.append(Data(name.utf8)); result.append(0) }
    // One final Stored Deflate block, independent of the production compressor.
    result.append(1)
    for value in [UInt16(data.count), ~UInt16(data.count)] {
        result.append(UInt8(truncatingIfNeeded: value)); result.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    result.append(data)
    for value in [FileSupport.crc(data), UInt32(data.count)] {
        for shift in stride(from: 0, through: 24, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    return result
}
