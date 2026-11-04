import XCTest
import Foundation
import CryptoKit
import Darwin
import ZIPFoundation
@testable import CrossZipCore

final class ArchiveTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZipTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    func put(_ path: String, _ data: Data = Data()) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func noTemporaryContent(in parent: URL? = nil) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: (parent ?? root).path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".crosszip-") })
    }

    func testUnicodeRoundTripPreservesDataEmptyFoldersAndRealHiddenFiles() throws {
        let source = try directory("实验资料 🧪/空文件夹") .deletingLastPathComponent()
        let payloads: [String: Data] = [
            "中文 文件.txt": Data("无线信道实验\n".utf8),
            "école/模型🧠.bin": Data((0...255).map(UInt8.init)),
            ".gitignore": Data(".build/\n".utf8), ".env": Data("EXAMPLE=1\n".utf8),
            "._真实文件": Data("普通文件，不能因前缀被丢弃".utf8), "zero": Data()
        ]
        for (name, bytes) in payloads { try put(source.lastPathComponent + "/" + name, bytes) }
        let archive = root.appendingPathComponent("互通.zip")
        let service = ArchiveService()
        let packed = try service.compress([source], to: archive)
        XCTAssertEqual(packed.fileCount, payloads.count)
        let inspection = try service.verify(archive)
        XCTAssertTrue(inspection.canProceed)
        XCTAssertTrue(inspection.records.allSatisfy { $0.flags & 0x0800 != 0 })
        let output = try service.extract(inspection, to: root)
        for (name, data) in payloads {
            let extracted = output.url.appendingPathComponent(source.lastPathComponent).appendingPathComponent(name)
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: extracted)), SHA256.hash(data: data))
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.url.appendingPathComponent(source.lastPathComponent + "/空文件夹").path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let second = try service.extract(inspection, to: root)
        XCTAssertEqual(second.url.lastPathComponent, "互通 (2)")
        try noTemporaryContent()
    }

    func testExistingMacMetadataAndHiddenFilesArePreserved() throws {
        let source = try directory("资料")
        let store = Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]) + Data(repeating: 0, count: 32)
        let apple = appleDouble()
        try put("资料/.DS_Store", store)
        try put("资料/__MACOSX/._内容.txt", apple)
        try put("资料/._说明.txt", Data("普通文本".utf8))
        try put("资料/真实目录/.DS_Store", Data("同名普通文件".utf8))
        let scan = try SourceScanner.scan([source])
        XCTAssertTrue(scan.canProceed)
        XCTAssertEqual(scan.excluded.count, 0)
        XCTAssertEqual(scan.fileCount, 4)
        XCTAssertTrue(scan.items.contains { $0.path.contains("__MACOSX") })
        XCTAssertTrue(scan.items.contains { $0.path.hasSuffix("._说明.txt") })
        XCTAssertTrue(scan.items.contains { $0.path == "资料/真实目录/.DS_Store" })
        let url = root.appendingPathComponent("metadata.zip")
        try writeFixture([Fixture("__MACOSX/._file", apple), Fixture("file", Data("data".utf8)),
                          Fixture("._real", Data("real".utf8))], to: url)
        let inspection = try ZIPInspector.inspect(url)
        XCTAssertEqual(inspection.excludedCount, 0)
        let result = try ArchiveService().extract(inspection, to: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.appendingPathComponent("._real").path))
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("__MACOSX/._file")), apple)
    }

    func testWindowsCompatibilityWarningsDoNotChangeNamesOrBlockPacking() throws {
        for name in ["CON.txt", "LPT¹.csv", "a?.txt", "tail.", "tail ", "COM1", "CONIN$"] {
            let path = try put(name)
            let plan = try SourceScanner.scan([path])
            XCTAssertTrue(plan.canProceed, name)
            XCTAssertEqual(plan.items[0].path, name)
            XCTAssertFalse(plan.issues.isEmpty)
            XCTAssertTrue(plan.issues.allSatisfy { $0.severity == .warning })
            XCTAssertEqual(try Data(contentsOf: path), Data())
        }
        XCTAssertFalse(PathRules.validateTree([("A/one", .file), ("a/two", .file)]).isEmpty)
        XCTAssertFalse(PathRules.validateTree([("é.txt", .file), ("e\u{301}.txt", .file)]).isEmpty)
        XCTAssertFalse(PathRules.validateTree([("σ.txt", .file), ("ς.txt", .file)]).isEmpty)
        XCTAssertFalse(PathRules.validateTree([("a", .file), ("a/b", .file)]).isEmpty)
        XCTAssertFalse(PathRules.issues(for: String(repeating: "a", count: 250)).isEmpty)
        XCTAssertTrue(PathRules.issues(for: String(repeating: "中", count: 100)).isEmpty)
        XCTAssertTrue(PathRules.issues(for: "文档/正常 文件.txt").isEmpty)
    }

    func testOverlappingSelectionsDeduplicateAndMultipleLocationsKeepOriginalParents() throws {
        let source = try directory("first")
        let child = try put("first/readme.txt", Data("one".utf8))
        let scan = try SourceScanner.scan([child, source, source])
        XCTAssertTrue(scan.canProceed)
        XCTAssertEqual(scan.fileCount, 1)
        let other = try put("second/README.txt", Data("two".utf8))
        let combined = try SourceScanner.scan([child, other])
        XCTAssertTrue(combined.canProceed)
        XCTAssertEqual(combined.fileCount, 2)
        XCTAssertEqual(combined.items.map(\.path), ["first/readme.txt", "second/README.txt"])
    }

    func testDestinationInsideSourceAndExistingOutputAreRejected() throws {
        let source = try directory("source")
        try put("source/input.txt", Data("data".utf8))
        XCTAssertThrowsError(try ArchiveService().compress([source], to: source.appendingPathComponent("bad.zip")))
        let existing = try put("exists.zip", Data("original".utf8))
        XCTAssertThrowsError(try ArchiveService().compress([source], to: existing))
        XCTAssertEqual(try Data(contentsOf: existing), Data("original".utf8))
        try noTemporaryContent()
    }

    func testLegacyCP437GB18030UTF8AndUnicodePathExtraField() throws {
        let cp = root.appendingPathComponent("cp.zip")
        var first = Fixture("dummy", Data("ok".utf8))
        first.rawName = Data([0x82]) + Data("cole.txt".utf8); first.flags = 0
        try writeFixture([first], to: cp)
        XCTAssertEqual(try ZIPInspector.inspect(cp).members[0].path, "école.txt")
        let gb = root.appendingPathComponent("gb.zip")
        var second = Fixture("中文.txt", Data("GBK file".utf8))
        second.rawName = "中文.txt".data(using: FilenameEncoding.gb18030.stringEncoding)!; second.flags = 0
        try writeFixture([second], to: gb)
        let inspection = try ZIPInspector.inspect(gb, encoding: .gb18030)
        XCTAssertEqual(inspection.members[0].path, "中文.txt")
        let result = try ArchiveService().extract(inspection, to: root)
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("中文.txt")), second.data)
        let utf = root.appendingPathComponent("unflagged.zip")
        var third = Fixture("中文.txt", Data()); third.flags = 0
        try writeFixture([third], to: utf)
        XCTAssertEqual(try ZIPInspector.inspect(utf, encoding: .utf8).members[0].path, "中文.txt")
        let unicode = root.appendingPathComponent("unicode-extra.zip")
        var fourth = Fixture("legacy.txt", Data("unicode".utf8)); fourth.flags = 0
        var extra = Data([1]); extra.le(FileSupport.crc(fourth.rawName)); extra.append(Data("正确中文.txt".utf8))
        fourth.extra.le(UInt16(0x7075)); fourth.extra.le(UInt16(extra.count)); fourth.extra.append(extra)
        try writeFixture([fourth], to: unicode)
        let parsed = try ZIPInspector.inspect(unicode)
        XCTAssertEqual(parsed.members[0].path, "正确中文.txt")
        let extracted = try ArchiveService().extract(parsed, to: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.url.appendingPathComponent("正确中文.txt").path))
    }

    func testRequestedArchiveFilenameIsPreservedEvenWithWindowsWarnings() throws {
        let source = try put("valid.txt", Data("data".utf8))
        for name in ["CON.zip", "report:2026.zip", "report?.zip"] {
            let destination = root.appendingPathComponent(name)
            let result = try ArchiveService().compress([source], to: destination)
            XCTAssertEqual(result.url, destination)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
            XCTAssertEqual(try ArchiveService().verify(result.url).fileCount, 1)
        }
        try noTemporaryContent()
    }

    func testLogicalSizeOverflowIsReportedInsteadOfTrapping() {
        var value = stat()
        value.st_mode = S_IFREG | 0o600
        value.st_size = Int64.max
        let items = (0..<3).map { index in
            SourceItem(url: root.appendingPathComponent("f\(index)"), path: "f\(index)", kind: .file,
                       fingerprint: FileFingerprint(value))
        }
        // Synthetic file states exercise arithmetic only; no huge files are created or read.
        let plan = SourcePlan(sources: [root], items: items, excluded: [], issues: [])
        XCTAssertEqual(plan.totalBytes, UInt64.max)
        XCTAssertFalse(plan.canProceed)
        XCTAssertTrue(plan.issues.contains { $0.reason.contains("逻辑大小") })
    }

    func testLongChineseFilenameAndSuggestedArchiveNameRoundTrip() throws {
        let name = String(repeating: "中", count: 100) + ".txt"
        let payload = Data("Long Unicode filename".utf8)
        let source = try put(name, payload)
        XCTAssertTrue(try SourceScanner.scan([source]).canProceed)
        let archive = root.appendingPathComponent(OutputNames.archiveName(for: name))
        _ = try ArchiveService().compress([source], to: archive)
        let output = try ArchiveService().extract(ZIPInspector.inspect(archive), to: root)
        XCTAssertEqual(try Data(contentsOf: output.url.appendingPathComponent(name)), payload)
        let longName = OutputNames.archiveName(for: String(repeating: "a", count: 248))
        XCTAssertTrue(longName.hasSuffix(".zip"))
        XCTAssertLessThanOrEqual(longName.utf16.count, 255)
        XCTAssertEqual(OutputNames.archiveName(for: "CON"), "CON.zip")
    }

    func testExtractionSkipsDanglingLinksAndFitsNumberedDirectoryNames() throws {
        let zip = root.appendingPathComponent("broken.zip")
        try writeFixture([Fixture("file.txt", Data("data".utf8))], to: zip)
        let link = root.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
        let result = try ArchiveService().extract(ZIPInspector.inspect(zip), to: root)
        XCTAssertEqual(result.url.lastPathComponent, "broken (2)")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), root.appendingPathComponent("missing").path)
        let stem = String(repeating: "a", count: 251)
        let longArchive = root.appendingPathComponent(stem + ".zip")
        try writeFixture([Fixture("file.txt", Data("data".utf8))], to: longArchive)
        for number in 1...9 {
            _ = try directory(stem + (number == 1 ? "" : " (\(number))"))
        }
        let numbered = try ArchiveService().extract(ZIPInspector.inspect(longArchive), to: root)
        XCTAssertTrue(numbered.url.lastPathComponent.hasSuffix(" (10)"))
        XCTAssertLessThanOrEqual(numbered.url.lastPathComponent.utf16.count, 255)
        XCTAssertEqual(try Data(contentsOf: numbered.url.appendingPathComponent("file.txt")), Data("data".utf8))
        try noTemporaryContent()
    }

    func testCorruptPayloadAndTruncatedDirectoryFailWithoutPublishing() throws {
        let zip = root.appendingPathComponent("corrupt.zip")
        var fixture = Fixture("a.txt", Data("payload".utf8)); fixture.corruptCRC = true
        try writeFixture([fixture], to: zip)
        let inspection = try ZIPInspector.inspect(zip)
        XCTAssertThrowsError(try ArchiveService().extract(inspection, to: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("corrupt").path))
        try noTemporaryContent()
        var data = try Data(contentsOf: zip)
        data.removeLast(10)
        let truncated = try put("truncated.zip", data)
        XCTAssertThrowsError(try ZIPInspector.inspect(truncated))
        try writeFixture([Fixture("a", Data())], to: zip)
        data = try Data(contentsOf: zip)
        data[data.count - 14] = 2; data[data.count - 12] = 2
        try data.write(to: zip)
        XCTAssertThrowsError(try ZIPInspector.inspect(zip))
    }

    func testUnsafeEncryptedUnsupportedAndDuplicateEntriesAreBlocked() throws {
        for name in ["../escape", "/absolute", "a/../../escape", "a//escape", "a/./escape", "nul\u{0}name"] {
            let zip = root.appendingPathComponent("unsafe.zip")
            try writeFixture([Fixture(name, Data("bad".utf8))], to: zip)
            XCTAssertFalse(try ZIPInspector.inspect(zip).canProceed, name)
        }
        var encrypted = Fixture("secret", Data()); encrypted.flags |= 1
        var unsupported = Fixture("bzip2", Data()); unsupported.method = 12
        var symlink = Fixture("link", Data("../outside".utf8)); symlink.attributes = UInt32(0xa1ff) << 16
        for fixture in [encrypted, unsupported] {
            let zip = root.appendingPathComponent("blocked.zip")
            try writeFixture([fixture], to: zip)
            XCTAssertFalse(try ZIPInspector.inspect(zip).canProceed)
        }
        let linked = root.appendingPathComponent("symlink.zip")
        try writeFixture([symlink], to: linked)
        XCTAssertTrue(try ArchiveService().verify(linked).canProceed)
        let duplicate = root.appendingPathComponent("duplicate.zip")
        try writeFixture([Fixture("a", Data()), Fixture("a", Data())], to: duplicate)
        XCTAssertFalse(try ZIPInspector.inspect(duplicate).canProceed)
        let inputLink = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: inputLink, withDestinationURL: duplicate)
        XCTAssertTrue(try SourceScanner.scan([inputLink]).canProceed)
    }

    func testInsufficientSpaceCancellationAndSourceMutationCleanUp() throws {
        let source = try put("data.bin", Data(repeating: 7, count: 1_000_000))
        let output = root.appendingPathComponent("result.zip")
        let fullDisk = ArchiveService(availableSpace: { _ in 0 })
        XCTAssertThrowsError(try fullDisk.compress([source], to: output))
        try noTemporaryContent()
        let box = TestState()
        let context = JobContext { update in
            if update.phase == .compressing { box.context?.cancel() }
        }
        box.context = context
        XCTAssertThrowsError(try ArchiveService().compress([source], to: output, context: context))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try noTemporaryContent()
        let mutation = TestState()
        let mutateContext = JobContext { update in
            if update.phase == .verifying && !mutation.fired {
                mutation.fired = true
                try! Data("modified".utf8).write(to: source)
            }
        }
        XCTAssertThrowsError(try ArchiveService().compress([source], to: output, context: mutateContext))
        XCTAssertTrue(mutation.fired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try noTemporaryContent()
    }

    func testExtractionSpaceCancellationAndArchiveMutationCleanUp() throws {
        let url = root.appendingPathComponent("data.zip")
        try writeFixture([Fixture("data.bin", Data(repeating: 1, count: 200_000))], to: url)
        let inspected = try ZIPInspector.inspect(url)
        XCTAssertThrowsError(try ArchiveService(availableSpace: { _ in 0 }).extract(inspected, to: root))
        let box = TestState()
        let context = JobContext { update in
            if update.phase == .extracting { box.context?.cancel() }
        }
        box.context = context
        XCTAssertThrowsError(try ArchiveService().extract(inspected, to: root, context: context))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data").path))
        try noTemporaryContent()
        try Data("not a zip".utf8).write(to: url)
        XCTAssertThrowsError(try ArchiveService().extract(inspected, to: root))
    }

    func testUnreadableSourceIsReported() throws {
        let source = try put("blocked/unreadable", Data("private".utf8))
        try put("blocked/z-readable", Data("can read".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
        let plan = try SourceScanner.scan([source.deletingLastPathComponent()])
        XCTAssertFalse(plan.canProceed)
        XCTAssertTrue(plan.issues.contains { $0.path == "blocked/unreadable" })
        XCTAssertTrue(plan.items.contains { $0.path == "blocked/z-readable" })
    }

    func testEmptyArchiveExtractsToANewEmptyDirectory() throws {
        let url = root.appendingPathComponent("empty.zip")
        try writeFixture([], to: url)
        let inspected = try ArchiveService().verify(url)
        XCTAssertTrue(inspected.canProceed)
        let result = try ArchiveService().extract(inspected, to: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.url.path).count, 0)
        try noTemporaryContent()
    }

    func testZIP64SmallAndDataDescriptors() throws {
        for signature in [true, false] {
            let url = root.appendingPathComponent("descriptor.zip")
            var entry = Fixture("data", Data("descriptor test".utf8))
            entry.descriptor = true; entry.descriptorSignature = signature
            try writeFixture([entry], to: url)
            XCTAssertNoThrow(try ArchiveService().verify(url))
        }
        let large = root.appendingPathComponent("zip64.zip")
        try writeFixture([Fixture("file.txt", Data("zip64".utf8))], to: large, zip64: true)
        XCTAssertTrue(try ArchiveService().verify(large).isZIP64)
    }

    func testZIP64MoreThan65535Entries() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CROSSZIP_LARGE_TESTS"] == "1", "设置 CROSSZIP_LARGE_TESTS=1 运行 ZIP64 边界测试")
        let url = root.appendingPathComponent("many.zip")
        try writeFixture((0..<65_536).map { Fixture(String(format: "f%05d", $0), Data()) }, to: url, zip64: true)
        let inspection = try ArchiveService().verify(url)
        XCTAssertTrue(inspection.isZIP64)
        XCTAssertEqual(inspection.fileCount, 65_536)
        let output = try ArchiveService().extract(inspection, to: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.url.path).count, 65_536)
        let repacked = root.appendingPathComponent("many-repacked.zip")
        _ = try ArchiveService().compress([output.url], to: repacked)
        let written = try ZIPInspector.inspect(repacked)
        XCTAssertTrue(written.isZIP64)
        XCTAssertEqual(written.fileCount, 65_536)
        try assertSystemUnzipValid(repacked)
    }

    func testZIP64FileLargerThan4GiBRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CROSSZIP_LARGE_TESTS"] == "1", "设置 CROSSZIP_LARGE_TESTS=1 运行 ZIP64 边界测试")
        let file = try put("large.bin")
        let size: UInt64 = (1 << 32) + 17
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: size)
        try handle.seek(toOffset: size - 8)
        try handle.write(contentsOf: Data("ENDMARK!".utf8))
        try handle.close()
        let zip = root.appendingPathComponent("large.zip")
        _ = try ArchiveService().compress([file], to: zip)
        let inspected = try ZIPInspector.inspect(zip)
        XCTAssertTrue(inspected.isZIP64)
        XCTAssertEqual(inspected.members[0].size, size)
        let output = try ArchiveService().extract(inspected, to: root)
        let result = output.url.appendingPathComponent("large.bin")
        XCTAssertEqual(try FileFingerprint.read(result).size, Int64(size))
        XCTAssertEqual(try streamingSHA256(file), try streamingSHA256(result))
        try assertSystemUnzipValid(zip)
    }

    private func assertSystemUnzipValid(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tqq", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "独立的系统 unzip 应能完整校验 ZIP64 输出")
    }
}

private final class TestState: @unchecked Sendable {
    var context: JobContext?
    var fired = false
}

private func streamingSHA256(_ url: URL) throws -> SHA256.Digest {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize()
}

struct Fixture {
    var rawName: Data
    let data: Data
    var flags: UInt16 = 0x0800
    var method: UInt16 = 0
    var attributes: UInt32 = UInt32(0x81a4) << 16
    var extra = Data()
    var corruptCRC = false
    var descriptor = false
    var descriptorSignature = true
    init(_ name: String, _ data: Data) { rawName = Data(name.utf8); self.data = data }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

func writeFixture(_ entries: [Fixture], to url: URL, zip64: Bool = false) throws {
    var output = Data()
    var central = Data()
    for entry in entries {
        let offset = UInt64(output.count)
        let size = UInt64(entry.data.count)
        let checksum = FileSupport.crc(entry.data) ^ (entry.corruptCRC ? 0xffffffff : 0)
        let flags = entry.flags | (entry.descriptor ? 8 : 0)
        var localExtra = entry.extra
        var centralExtra = entry.extra
        if zip64 {
            localExtra.le(UInt16(1)); localExtra.le(UInt16(16)); localExtra.le(size); localExtra.le(size)
            centralExtra.le(UInt16(1)); centralExtra.le(UInt16(24)); centralExtra.le(size); centralExtra.le(size); centralExtra.le(offset)
        }
        output.le(UInt32(0x04034b50)); output.le(UInt16(zip64 ? 45 : 20)); output.le(flags); output.le(entry.method)
        output.le(UInt16(0)); output.le(UInt16(0x5821)); output.le(entry.descriptor ? UInt32(0) : checksum)
        output.le(zip64 ? UInt32.max : (entry.descriptor ? 0 : UInt32(size)))
        output.le(zip64 ? UInt32.max : (entry.descriptor ? 0 : UInt32(size)))
        output.le(UInt16(entry.rawName.count)); output.le(UInt16(localExtra.count)); output.append(entry.rawName); output.append(localExtra)
        output.append(entry.data)
        if entry.descriptor {
            if entry.descriptorSignature { output.le(UInt32(0x08074b50)) }
            output.le(checksum)
            if zip64 { output.le(size); output.le(size) }
            else { output.le(UInt32(size)); output.le(UInt32(size)) }
        }
        central.le(UInt32(0x02014b50)); central.le(UInt16(0x0314)); central.le(UInt16(zip64 ? 45 : 20))
        central.le(flags); central.le(entry.method); central.le(UInt16(0)); central.le(UInt16(0x5821)); central.le(checksum)
        central.le(zip64 ? UInt32.max : UInt32(size)); central.le(zip64 ? UInt32.max : UInt32(size))
        central.le(UInt16(entry.rawName.count)); central.le(UInt16(centralExtra.count)); central.le(UInt16(0))
        central.le(UInt16(0)); central.le(UInt16(0)); central.le(entry.attributes)
        central.le(zip64 ? UInt32.max : UInt32(offset)); central.append(entry.rawName); central.append(centralExtra)
    }
    let centralOffset = UInt64(output.count)
    output.append(central)
    if zip64 {
        let zip64Offset = UInt64(output.count)
        output.le(UInt32(0x06064b50)); output.le(UInt64(44)); output.le(UInt16(45)); output.le(UInt16(45))
        output.le(UInt32(0)); output.le(UInt32(0)); output.le(UInt64(entries.count)); output.le(UInt64(entries.count))
        output.le(UInt64(central.count)); output.le(centralOffset)
        output.le(UInt32(0x07064b50)); output.le(UInt32(0)); output.le(zip64Offset); output.le(UInt32(1))
    }
    output.le(UInt32(0x06054b50)); output.le(UInt16(0)); output.le(UInt16(0))
    output.le(zip64 ? UInt16.max : UInt16(entries.count)); output.le(zip64 ? UInt16.max : UInt16(entries.count))
    output.le(zip64 ? UInt32.max : UInt32(central.count)); output.le(zip64 ? UInt32.max : UInt32(centralOffset)); output.le(UInt16(0))
    try output.write(to: url)
}

private func appleDouble() -> Data {
    var data = Data([0, 5, 0x16, 7, 0, 2, 0, 0])
    data.append(Data(repeating: 0, count: 16)); data.append(contentsOf: [0, 1])
    data.append(contentsOf: [0, 0, 0, 9, 0, 0, 0, 38, 0, 0, 0, 0])
    return data
}
