import XCTest
import Foundation
import ZIPFoundation
@testable import CrossZipCore

final class ZIPAuditTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZipZIPAudit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testReducedCentralDirectoryDoesNotSilentlyOmitFiles() throws {
        for zip64 in [false, true] {
            let url = try makeTwoFileZIP(zip64: zip64)
            var bytes = try Data(contentsOf: url)
            let end = bytes.count - 22
            let directory = Int(auditInteger(bytes, end + 16, width: 4))
            // In ZIP64 the EOCD contains sentinels, so use the full-size record instead.
            let zip64End = end - 20 - 56
            let actualDirectory = zip64 ? Int(auditInteger(bytes, zip64End + 48, width: 8)) : directory
            let firstLength = 46 + Int(auditInteger(bytes, actualDirectory + 28, width: 2))
                + Int(auditInteger(bytes, actualDirectory + 30, width: 2))
                + Int(auditInteger(bytes, actualDirectory + 32, width: 2))
            if zip64 {
                auditStore(&bytes, at: zip64End + 24, value: UInt64(1))
                auditStore(&bytes, at: zip64End + 32, value: UInt64(1))
                auditStore(&bytes, at: zip64End + 40, value: UInt64(firstLength))
            } else {
                auditStore(&bytes, at: end + 8, value: UInt16(1))
                auditStore(&bytes, at: end + 10, value: UInt16(1))
                auditStore(&bytes, at: end + 12, value: UInt32(firstLength))
            }
            try bytes.write(to: url)
            XCTAssertThrowsError(try ZIPInspector.inspect(url), "A remaining uncounted central record must not be ignored")
            XCTAssertThrowsError(try ArchiveService().verify(url))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".crosszip-") }.count, 0)
        }
    }

    func testCompleteCentralDirectoryAndDigitalSignatureStillRead() throws {
        for zip64 in [false, true] {
            for signature in [false, true] {
                let url = try makeTwoFileZIP(zip64: zip64, signature: signature)
                let inspection = try ArchiveService().verify(url)
                XCTAssertEqual(inspection.fileCount, 2)
                XCTAssertEqual(inspection.members.map(\.path), ["first.txt", "second.txt"])
                XCTAssertEqual(inspection.isZIP64, zip64)
            }
        }
    }

    func testEmptyCountCannotHideAnExistingCentralDirectory() throws {
        let url = try makeTwoFileZIP()
        var bytes = try Data(contentsOf: url)
        let end = bytes.count - 22
        auditStore(&bytes, at: end + 8, value: UInt16(0))
        auditStore(&bytes, at: end + 10, value: UInt16(0))
        auditStore(&bytes, at: end + 12, value: UInt32(0))
        try bytes.write(to: url)
        XCTAssertThrowsError(try ZIPInspector.inspect(url))
    }

    func testZIP64EmptyStreamDescriptorUsesComplete64BitSizes() throws {
        for signature in [false, true] {
            let valid = try makeEmptyStreamZIP(zip64Sizes: true, signature: signature)
            let inspection = try ArchiveService().verify(valid)
            XCTAssertTrue(inspection.isZIP64)
            XCTAssertEqual(inspection.members[0].size, 0)
            let corrupt = try makeEmptyStreamZIP(zip64Sizes: true, signature: signature, corruptSize: true)
            XCTAssertThrowsError(try ZIPInspector.inspect(corrupt), "The high-width size must not be mistaken for a shorter descriptor")
        }
    }

    func testZIP64OffsetOnlyDoesNotPromotePayloadDescriptorSizes() throws {
        for signature in [false, true] {
            let url = try makeEmptyStreamZIP(zip64Sizes: false, signature: signature, zip64Offset: true)
            let inspection = try ArchiveService().verify(url)
            XCTAssertTrue(inspection.isZIP64)
            XCTAssertEqual(inspection.fileCount, 1)
        }
    }

    private func makeEmptyStreamZIP(zip64Sizes: Bool, signature: Bool, corruptSize: Bool = false,
                                   zip64Offset: Bool = false) throws -> URL {
        let name = Data("empty.txt".utf8)
        var localExtra = Data()
        if zip64Sizes {
            localExtra.auditAppendLE(UInt16(1)); localExtra.auditAppendLE(UInt16(16))
            localExtra.auditAppendLE(UInt64(0)); localExtra.auditAppendLE(UInt64(0))
        }
        var bytes = Data()
        bytes.auditAppendLE(UInt32(0x04034b50)); bytes.auditAppendLE(UInt16(zip64Sizes ? 45 : 20))
        bytes.auditAppendLE(UInt16(0x0808)); bytes.auditAppendLE(UInt16(8))
        bytes.auditAppendLE(UInt16(0)); bytes.auditAppendLE(UInt16(0x5821))
        bytes.auditAppendLE(UInt32(0)); bytes.auditAppendLE(UInt32(0)); bytes.auditAppendLE(UInt32(0))
        bytes.auditAppendLE(UInt16(name.count)); bytes.auditAppendLE(UInt16(localExtra.count))
        bytes.append(name); bytes.append(localExtra)
        bytes.append(contentsOf: [0x03, 0x00]) // Complete raw Deflate stream for an empty file.
        if signature { bytes.auditAppendLE(UInt32(0x08074b50)) }
        bytes.auditAppendLE(UInt32(0))
        if zip64Sizes {
            bytes.auditAppendLE(UInt64(2)); bytes.auditAppendLE(UInt64(corruptSize ? 12345 : 0))
        } else {
            bytes.auditAppendLE(UInt32(2)); bytes.auditAppendLE(UInt32(0))
        }
        let directory = UInt32(bytes.count)
        var centralExtra = Data()
        if zip64Offset {
            centralExtra.auditAppendLE(UInt16(1)); centralExtra.auditAppendLE(UInt16(8))
            centralExtra.auditAppendLE(UInt64(0))
        }
        bytes.auditAppendLE(UInt32(0x02014b50)); bytes.auditAppendLE(UInt16(0x0314))
        bytes.auditAppendLE(UInt16(zip64Sizes || zip64Offset ? 45 : 20))
        bytes.auditAppendLE(UInt16(0x0808)); bytes.auditAppendLE(UInt16(8))
        bytes.auditAppendLE(UInt16(0)); bytes.auditAppendLE(UInt16(0x5821))
        bytes.auditAppendLE(UInt32(0)); bytes.auditAppendLE(UInt32(2)); bytes.auditAppendLE(UInt32(0))
        bytes.auditAppendLE(UInt16(name.count)); bytes.auditAppendLE(UInt16(centralExtra.count))
        bytes.auditAppendLE(UInt16(0)); bytes.auditAppendLE(UInt16(0)); bytes.auditAppendLE(UInt16(0))
        bytes.auditAppendLE(UInt32(0x81a4) << 16)
        bytes.auditAppendLE(zip64Offset ? UInt32.max : UInt32(0))
        bytes.append(name); bytes.append(centralExtra)
        let directorySize = UInt32(bytes.count) - directory
        bytes.auditAppendLE(UInt32(0x06054b50)); bytes.auditAppendLE(UInt16(0)); bytes.auditAppendLE(UInt16(0))
        bytes.auditAppendLE(UInt16(1)); bytes.auditAppendLE(UInt16(1))
        bytes.auditAppendLE(directorySize); bytes.auditAppendLE(directory); bytes.auditAppendLE(UInt16(0))
        let url = root.appendingPathComponent(UUID().uuidString + ".zip")
        try bytes.write(to: url)
        return url
    }

    private func makeTwoFileZIP(zip64: Bool = false, signature: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".zip")
        do {
            let archive = try Archive(url: url, accessMode: .create)
            for (name, text) in [("first.txt", "first payload"), ("second.txt", "second payload must not be lost")] {
                let payload = Data(text.utf8)
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(payload.count),
                                     provider: { offset, count in
                    payload.subdata(in: Int(offset)..<(Int(offset) + count))
                })
            }
        }
        var bytes = try Data(contentsOf: url)
        var ordinaryEnd = bytes.subdata(in: (bytes.count - 22)..<bytes.count)
        let directory = auditInteger(ordinaryEnd, 16, width: 4)
        var directorySize = auditInteger(ordinaryEnd, 12, width: 4)
        bytes.removeLast(22)
        if signature {
            bytes.auditAppendLE(UInt32(0x05054b50))
            bytes.auditAppendLE(UInt16(3))
            bytes.append(Data("sig".utf8))
            directorySize += 9
            auditStore(&ordinaryEnd, at: 12, value: UInt32(directorySize))
        }
        if zip64 {
            let recordOffset = UInt64(bytes.count)
            bytes.auditAppendLE(UInt32(0x06064b50)); bytes.auditAppendLE(UInt64(44))
            bytes.auditAppendLE(UInt16(45)); bytes.auditAppendLE(UInt16(45))
            bytes.auditAppendLE(UInt32(0)); bytes.auditAppendLE(UInt32(0))
            bytes.auditAppendLE(UInt64(2)); bytes.auditAppendLE(UInt64(2))
            bytes.auditAppendLE(directorySize); bytes.auditAppendLE(directory)
            bytes.auditAppendLE(UInt32(0x07064b50)); bytes.auditAppendLE(UInt32(0))
            bytes.auditAppendLE(recordOffset); bytes.auditAppendLE(UInt32(1))
            auditStore(&ordinaryEnd, at: 8, value: UInt16.max)
            auditStore(&ordinaryEnd, at: 10, value: UInt16.max)
            auditStore(&ordinaryEnd, at: 12, value: UInt32.max)
            auditStore(&ordinaryEnd, at: 16, value: UInt32.max)
        }
        bytes.append(ordinaryEnd)
        try bytes.write(to: url)
        return url
    }
}

private func auditInteger(_ bytes: Data, _ offset: Int, width: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<width { value |= UInt64(bytes[offset + index]) << (index * 8) }
    return value
}

private func auditStore<T: FixedWidthInteger>(_ data: inout Data, at offset: Int, value: T) {
    var encoded = Data()
    encoded.auditAppendLE(value)
    data.replaceSubrange(offset..<(offset + encoded.count), with: encoded)
}

private extension Data {
    mutating func auditAppendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
