import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import CrossZipCore

final class PackAllTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZip-PackAll-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func file(_ path: String, content: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func roundTrip(_ sources: [URL], archiveName: String = "result.zip") throws -> (SourcePlan, URL) {
        let plan = try SourceScanner.scan(sources)
        XCTAssertTrue(plan.canProceed, plan.issues.map(\.reason).joined(separator: "\n"))
        let result = try ArchiveService().compress(sources, to: root.appendingPathComponent(archiveName))
        let inspection = try ArchiveService().verify(result.url)
        // Exactly the input inventory: no name map, new sidecars, or missing entries.
        XCTAssertEqual(inspection.records.count, plan.items.count)
        XCTAssertEqual(Set(inspection.records.map { Data($0.path.utf8) }), Set(plan.items.map { Data($0.path.utf8) }))
        let output = try ArchiveService().extract(inspection, to: root).url
        for item in plan.items {
            let target = output.appendingPathComponent(item.path)
            let fingerprint = try FileFingerprint.read(target)
            XCTAssertEqual(fingerprint.kind, item.kind)
            if item.kind == .file {
                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: target)),
                               SHA256.hash(data: try Data(contentsOf: item.url)), item.path)
            } else if item.kind == .symlink {
                XCTAssertEqual(try FileSupport.readLink(target, expected: fingerprint), item.linkTarget)
            }
        }
        // POSIX enumeration checks the actual spelling returned by the filesystem.
        func inventory(_ url: URL, prefix: String = "") throws -> Set<Data> {
            var names: Set<Data> = []
            for child in try FileSupport.children(of: url) {
                let path = prefix + child.lastPathComponent
                names.insert(Data(path.utf8))
                if try FileFingerprint.read(child).kind == .directory {
                    names.formUnion(try inventory(child, prefix: path + "/"))
                }
            }
            return names
        }
        var expected: Set<Data> = []
        for item in plan.items {
            let parts = item.path.split(separator: "/")
            for index in parts.indices { expected.insert(Data(parts[...index].joined(separator: "/").utf8)) }
        }
        XCTAssertEqual(try inventory(output), expected)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".crosszip-") })
        return (plan, output)
    }

    func testSpecialNamesAndAllBytesSurviveWithoutRenamingOrExtraFiles() throws {
        let names = ["CON.txt", "a?.txt", "a*.txt", "a_.txt", "tail.", "tail ", "LPT¹.csv", "a\\b.txt",
                     "a:b.txt", "line\nfeed.txt", "CrossZip-名称对照.json", ".DS_Store", "._resource", "中文 🙂.txt"]
        let sources = try names.enumerated().map { try file("输入/" + $0.element, content: "原样内容-\($0.offset)\r\n") }
        let (plan, _) = try roundTrip([root.appendingPathComponent("输入")])
        XCTAssertEqual(plan.fileCount, names.count)
        XCTAssertEqual(plan.excluded, [])
        XCTAssertEqual(Set(plan.items.filter { $0.kind == .file }.map { Data($0.path.utf8) }),
                       Set(names.map { Data(("输入/" + $0).utf8) }))
        XCTAssertTrue(plan.issues.allSatisfy { $0.severity == .warning })
        for (index, url) in sources.enumerated() {
            XCTAssertEqual(try Data(contentsOf: url), Data("原样内容-\(index)\r\n".utf8))
        }
    }

    func testSameTopLevelNamesKeepBothOriginalTreesAndParents() throws {
        _ = try file("one/资料/内容.txt", content: "first tree")
        _ = try file("two/资料/内容.txt", content: "second tree")
        let (plan, _) = try roundTrip([root.appendingPathComponent("one/资料"), root.appendingPathComponent("two/资料")])
        XCTAssertEqual(plan.fileCount, 2)
        XCTAssertEqual(plan.items.map(\.path), ["one/资料", "one/资料/内容.txt", "two/资料", "two/资料/内容.txt"])
    }

    func testLongNamesAndDeepPathsRemainExactIncludingEmptyDirectories() throws {
        let longName = String(repeating: "中🧪", count: 75) + ".bin"
        let deep = (0..<18).map { "第\($0)层-" + String(repeating: "x", count: 15) }.joined(separator: "/")
        _ = try file("长路径/" + longName, content: "long leaf")
        let original = "长路径/" + deep + "/数据.txt"
        _ = try file(original, content: "deep leaf")
        let emptyPath = "长路径/" + deep + "/空文件夹"
        let empty = root.appendingPathComponent(emptyPath)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let (plan, output) = try roundTrip([root.appendingPathComponent("长路径")])
        XCTAssertEqual(plan.fileCount, 2)
        XCTAssertEqual(plan.directoryCount, 20)
        XCTAssertTrue(plan.issues.contains { $0.reason.contains("路径预算") })
        XCTAssertTrue(plan.items.contains { $0.path == original })
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent(emptyPath).path))
    }

    func testOpenedAndAdvisoryLockedReadableFileCanBePacked() throws {
        let source = try file("opened.txt", content: "still readable while another handle is open")
        let handle = try FileHandle(forUpdating: source)
        defer { try? handle.close() }
        XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        _ = try roundTrip([source])
    }

    func testValidBrokenCyclicAndExternalSymlinksRemainLinksWithoutFollowingTargets() throws {
        let target = try file("outside/目标.txt", content: "must not be modified or copied by following a link")
        let input = root.appendingPathComponent("输入")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        for (name, destination) in [("file-link", target), ("dir-link", target.deletingLastPathComponent()),
                                    ("broken", root.appendingPathComponent("missing")), ("cycle", input)] {
            try FileManager.default.createSymbolicLink(at: input.appendingPathComponent(name), withDestinationURL: destination)
        }
        let (plan, _) = try roundTrip([input])
        XCTAssertEqual(plan.fileCount, 4)
        XCTAssertEqual(plan.directoryCount, 1)
        XCTAssertEqual(plan.items.filter { $0.kind == .symlink }.count, 4)
        XCTAssertEqual(try Data(contentsOf: target), Data("must not be modified or copied by following a link".utf8))
        let relative = input.appendingPathComponent("relative")
        try FileManager.default.createSymbolicLink(atPath: relative.path, withDestinationPath: "../outside/目标.txt")
        _ = try roundTrip([relative], archiveName: "relative.zip")
    }

    func testUnsupportedPipeFailsWithoutSkippingItOrPublishingPartialResults() throws {
        let source = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(source.path, 0o600), 0)
        let ordinary = try file("ordinary.txt", content: "ordinary content")
        let output = root.appendingPathComponent("pipe.zip")
        let plan = try SourceScanner.scan([source, ordinary])
        XCTAssertFalse(plan.canProceed)
        XCTAssertEqual(plan.fileCount, 1)
        XCTAssertThrowsError(try ArchiveService().compress([source, ordinary], to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRetargetedLinkIsDetectedAndDoesNotPublish() throws {
        let first = try file("outside/first.txt", content: "one")
        let second = try file("outside/second.txt", content: "two")
        let link = root.appendingPathComponent("selection")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let state = LinkMutation()
        let context = JobContext { update in
            if update.phase == .verifying && !state.fired {
                state.fired = true
                do {
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
                } catch { state.error = error }
            }
        }
        let output = root.appendingPathComponent("retargeted.zip")
        XCTAssertThrowsError(try ArchiveService().compress([link], to: output, context: context))
        XCTAssertTrue(state.fired)
        XCTAssertNil(state.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCaseAndUnicodeDifferencesAreStorableButDoNotSilentlyMergeAtExtraction() throws {
        for pairs in [[("A/one", ItemKind.file), ("a/two", .file)], [("é.txt", .file), ("e\u{301}.txt", .file)]] {
            XCTAssertTrue(PathRules.validateTree(pairs).allSatisfy { $0.severity == .warning })
            XCTAssertFalse(PathRules.extractionConflicts(pairs, caseSensitive: false).isEmpty)
        }
        XCTAssertTrue(PathRules.extractionConflicts([("A/one", .file), ("a/two", .file)], caseSensitive: true).isEmpty)
        let archive = root.appendingPathComponent("case.zip")
        try writeFixture([Fixture("A/one", Data("one".utf8)), Fixture("a/two", Data("two".utf8))], to: archive)
        let inspection = try ArchiveService().verify(archive)
        XCTAssertTrue(inspection.canProceed)
        XCTAssertEqual(inspection.fileCount, 2)
        if try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames != true {
            XCTAssertThrowsError(try ArchiveService().extract(inspection, to: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("case").path))
        }
    }

    func testArchiveCannotWriteThroughSymlinkAncestorEvenWhenOrderIsReversed() throws {
        var link = Fixture("link", Data("../../outside".utf8))
        link.attributes = UInt32(0xa1ff) << 16
        for entries in [[link, Fixture("link/escape.txt", Data("bad".utf8))],
                        [Fixture("link/escape.txt", Data("bad".utf8)), link]] {
            let archive = root.appendingPathComponent("unsafe.zip")
            try writeFixture(entries, to: archive)
            let inspection = try ZIPInspector.inspect(archive)
            XCTAssertFalse(inspection.canProceed)
            XCTAssertThrowsError(try ArchiveService().extract(inspection, to: root))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
    }

    func testCompatibilityWarningsCannotHideAnExactlyRepeatedEntry() throws {
        let archive = root.appendingPathComponent("duplicate.zip")
        try writeFixture([Fixture("A", Data()), Fixture("a", Data()), Fixture("a", Data())], to: archive)
        let inspection = try ZIPInspector.inspect(archive)
        XCTAssertFalse(inspection.canProceed)
        XCTAssertTrue(inspection.issues.contains { $0.severity == .error && $0.reason.contains("重复") })
    }

    func testCompressibleContentIsNotRejectedByItsUncompressedSize() throws {
        let source = try file("compressible.bin", content: "")
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()
        let archive = root.appendingPathComponent("small.zip")
        // A virtual 32 MiB free-space reading is less than the source, but more
        // than enough for these compressed zero bytes. Do not fill the real disk.
        let service = ArchiveService(availableSpace: { _ in 32 * 1024 * 1024 })
        let result = try service.compress([source], to: archive)
        XCTAssertEqual(result.totalBytes, 64 * 1024 * 1024)
        XCTAssertLessThan(try FileFingerprint.read(archive).size, 32 * 1024 * 1024)
        XCTAssertEqual(try service.verify(archive).fileCount, 1)
    }
}

private final class LinkMutation: @unchecked Sendable {
    var fired = false
    var error: Error?
}
