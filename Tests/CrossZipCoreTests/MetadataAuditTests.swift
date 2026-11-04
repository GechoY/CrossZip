import XCTest
import Foundation
import ZIPFoundation
@testable import CrossZipCore

final class MetadataAuditTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZipMetadataAudit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMalformedAppleDoubleSourceIsPreservedThroughPackingAndExtraction() throws {
        let source = root.appendingPathComponent("资料", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let ordinary = appleDouble([(9, 4096, 1024)], payload: Data("ordinary payload".utf8))
        let metadata = appleDouble([(9, 38, 4)], payload: Data("info".utf8))
        try ordinary.write(to: source.appendingPathComponent("._ordinary.bin"))
        try metadata.write(to: source.appendingPathComponent("._metadata"))
        let scan = try SourceScanner.scan([source])
        XCTAssertTrue(scan.canProceed)
        XCTAssertEqual(scan.excluded, [])
        XCTAssertEqual(scan.fileCount, 2)
        XCTAssertTrue(scan.items.contains { $0.path == "资料/._ordinary.bin" })

        let zip = root.appendingPathComponent("roundtrip.zip")
        _ = try ArchiveService().compress([source], to: zip)
        let inspection = try ZIPInspector.inspect(zip)
        XCTAssertEqual(inspection.excludedCount, 0)
        XCTAssertTrue(inspection.members.contains { $0.path == "资料/._ordinary.bin" })
        let result = try ArchiveService().extract(inspection, to: root)
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("资料/._ordinary.bin")), ordinary)
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("资料/._metadata")), metadata)
    }

    func testAllAppleDoubleFilesSurviveAcrossInflateChunks() throws {
        let count = 6_000
        let tableEnd = UInt32(26 + count * 12)
        var descriptors = (0..<count).map { (UInt32(0x80000000) + UInt32($0), tableEnd, UInt32(0)) }
        let metadata = appleDouble(descriptors)
        descriptors[count - 1].1 = tableEnd + 1
        let ordinary = appleDouble(descriptors)
        XCTAssertGreaterThan(metadata.count, 64 * 1024)

        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try metadata.write(to: source.appendingPathComponent("._metadata"))
        try ordinary.write(to: source.appendingPathComponent("._ordinary"))
        let scan = try SourceScanner.scan([source])
        XCTAssertEqual(scan.excluded, [])
        XCTAssertTrue(scan.items.contains { $0.path == "source/._ordinary" })

        let zip = root.appendingPathComponent("incoming.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            for (name, data) in [("._metadata", metadata), ("._ordinary", ordinary)] {
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                                     compressionMethod: .deflate, bufferSize: 64 * 1024,
                                     provider: { position, count in
                    data.subdata(in: Int(position)..<(Int(position) + count))
                })
            }
        }
        let inspection = try ZIPInspector.inspect(zip)
        XCTAssertTrue(inspection.canProceed)
        XCTAssertEqual(inspection.excludedCount, 0)
        XCTAssertEqual(inspection.members.map(\.path), ["._metadata", "._ordinary"])
        let result = try ArchiveService().extract(inspection, to: root)
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("._ordinary")), ordinary)
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("._metadata")), metadata)
    }
}

private func appleDouble(_ descriptors: [(UInt32, UInt32, UInt32)], payload: Data = Data()) -> Data {
    var data = Data()
    data.appendBigEndian(UInt32(0x00051607))
    data.appendBigEndian(UInt32(0x00020000))
    data.append(Data(repeating: 0, count: 16))
    data.appendBigEndian(UInt16(descriptors.count))
    for (identifier, offset, length) in descriptors {
        data.appendBigEndian(identifier); data.appendBigEndian(offset); data.appendBigEndian(length)
    }
    data.append(payload)
    return data
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
