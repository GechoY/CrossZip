import Foundation

public struct ZIPMember: Identifiable, Sendable {
    public let id: Int
    public let path: String
    public let kind: ItemKind
    public let size: UInt64
    public let compressedSize: UInt64
    public let checksum: UInt32
    let modified: Date?
    public internal(set) var isExcluded = false
    let rawName: Data
    let flags: UInt16
    let method: UInt16
    let localOffset: UInt64
    var dataOffset: UInt64 = 0
    var rangeEnd: UInt64 = 0
    var usesZIP64 = false
    var usesZIP64Sizes = false
}

public struct ZIPInspection: Sendable {
    public let url: URL
    public let encoding: FilenameEncoding
    public let records: [ZIPMember]
    public let issues: [ArchiveIssue]
    public let isZIP64: Bool
    let fingerprint: FileFingerprint
    public var members: [ZIPMember] { records.filter { !$0.isExcluded } }
    public var totalBytes: UInt64 { members.reduce(0) { $0 + $1.size } }
    public var excludedCount: Int { records.filter(\.isExcluded).count }
    public var fileCount: Int { members.filter { $0.kind != .directory }.count }
    public var directoryCount: Int { members.count - fileCount }
    public var canProceed: Bool { !issues.contains { $0.severity == .error } }
}

private struct ZIPBytes {
    let data: Data
    func integer(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, width > 0, offset <= data.count, width <= data.count - offset else {
            throw CrossZipError.message("ZIP 字段被截断，压缩包不完整。")
        }
        var value: UInt64 = 0
        for index in 0..<width { value |= UInt64(data[offset + index]) << (index * 8) }
        return value
    }
    func u16(_ offset: Int) throws -> UInt16 { UInt16(try integer(offset, 2)) }
    func u32(_ offset: Int) throws -> UInt32 { UInt32(try integer(offset, 4)) }
    func u64(_ offset: Int) throws -> UInt64 { try integer(offset, 8) }
}

/// A bounded index reader complements the engine: its Sequence iterator may end on a malformed
/// record. Here the EOCD count, central records, local records and byte ranges must all agree.
public enum ZIPInspector {
    private struct Index {
        let offset: UInt64
        let size: UInt64
        let count: UInt64
        let zip64: Bool
        let endBoundary: UInt64
    }

    public static func inspect(_ url: URL, encoding: FilenameEncoding = .automatic,
                               context: JobContext = JobContext(), phase: JobPhase = .scanning) throws -> ZIPInspection {
        context.report(phase, path: url.lastPathComponent, detail: "检查 ZIP 目录和文件名…", force: true)
        try context.checkCancellation()
        let fingerprint = try FileFingerprint.read(url)
        guard fingerprint.kind == .file, fingerprint.size >= 22 else {
            throw CrossZipError.message("不是完整的 ZIP 文件，或文件过短。")
        }
        let handle = try FileSupport.openRegularFile(url, expected: fingerprint)
        defer { try? handle.close() }
        let fileSize = UInt64(fingerprint.size)
        let index = try readIndex(handle, fileSize: fileSize)
        // The complete central directory (including an optional digital signature) must
        // meet the following end record. A gap can otherwise hide additional file headers
        // when a damaged EOCD understates both its entry count and directory size.
        guard index.offset <= index.endBoundary, index.size == index.endBoundary - index.offset,
              index.count <= index.size / 46, index.count <= UInt64(Int.max) else {
            throw CrossZipError.message("ZIP 目录偏移、长度或条目数量不一致。")
        }
        var cursor = index.offset
        let centralEnd = cursor + index.size
        var records: [ZIPMember] = []
        var issues: [ArchiveIssue] = []
        var totalSize: UInt64 = 0
        var hasLegacyNames = false
        for number in 0..<Int(index.count) {
            try context.checkCancellation()
            guard cursor <= centralEnd, 46 <= centralEnd - cursor else {
                throw CrossZipError.message("ZIP 目录被截断，条目数量与记录不符。")
            }
            let fixed = ZIPBytes(data: try read(handle, at: cursor, count: 46, limit: fileSize))
            guard try fixed.u32(0) == 0x02014b50 else { throw CrossZipError.message("ZIP 目录记录损坏。") }
            let flags = try fixed.u16(8)
            let method = try fixed.u16(10)
            let nameLength = Int(try fixed.u16(28))
            let extraLength = Int(try fixed.u16(30))
            let commentLength = Int(try fixed.u16(32))
            let variableLength = nameLength + extraLength + commentLength
            guard UInt64(variableLength) <= centralEnd - cursor - 46, nameLength > 0 else {
                throw CrossZipError.message("ZIP 目录中的名称或扩展字段长度无效。")
            }
            let variable = try read(handle, at: cursor + 46, count: variableLength, limit: fileSize)
            let rawName = variable.subdata(in: 0..<nameLength)
            let extras = try extraFields(variable.subdata(in: nameLength..<(nameLength + extraLength)))
            var size = UInt64(try fixed.u32(24))
            var compressed = UInt64(try fixed.u32(20))
            let usesZIP64Sizes = size == UInt32.max || compressed == UInt32.max
            var localOffset = UInt64(try fixed.u32(42))
            var disk = UInt64(try fixed.u16(34))
            if size == UInt32.max || compressed == UInt32.max || localOffset == UInt32.max || disk == UInt16.max {
                guard let data = extras[1] else { throw CrossZipError.message("缺少 ZIP64 必需的大小或偏移信息。") }
                let zip = ZIPBytes(data: data)
                var position = 0
                if size == UInt32.max { size = try zip.u64(position); position += 8 }
                if compressed == UInt32.max { compressed = try zip.u64(position); position += 8 }
                if localOffset == UInt32.max { localOffset = try zip.u64(position); position += 8 }
                if disk == UInt16.max { disk = UInt64(try zip.u32(position)) }
            }
            guard disk == 0 else { throw CrossZipError.message("首版不支持分卷 ZIP，请先合并为普通 ZIP。") }
            guard size <= UInt64(Int64.max), compressed <= UInt64(Int64.max), totalSize <= UInt64(Int64.max) - size else {
                throw CrossZipError.message("ZIP 声明的解压大小超出支持范围。")
            }
            totalSize += size
            let decoded = try decodeName(rawName, flags: flags, extras: extras, encoding: encoding)
            hasLegacyNames = hasLegacyNames || (flags & 0x0800 == 0 && rawName.contains { $0 >= 128 })
            let host = try fixed.u16(4) >> 8
            let attributes = try fixed.u32(38)
            let unixType = (attributes >> 16) & 0xf000
            let unixAttributes = host == 3 || host == 19
            let isDirectory = decoded.hasSuffix("/") || attributes & 0x10 != 0 || (unixAttributes && unixType == 0x4000)
            let isSymlink = unixAttributes && unixType == 0xa000
            let path = decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
            if flags & 0x2041 != 0 || method == 99 {
                issues.append(ArchiveIssue(path, "加密 ZIP 不属于首版支持范围", suggestion: "请提供未加密的普通 ZIP。"))
            }
            if method != 0 && method != 8 {
                issues.append(ArchiveIssue(path, "不支持 ZIP 内的压缩方法 \(method)", suggestion: "请使用 Stored 或 Deflate 重新打包。"))
            }
            if unixAttributes && unixType != 0 && unixType != 0x4000 && unixType != 0x8000 && !isSymlink {
                issues.append(ArchiveIssue(path, "压缩包包含特殊文件",
                                           suggestion: "首版仅解压普通文件和文件夹。"))
            }
            if isSymlink && isDirectory { throw CrossZipError.message("ZIP 条目同时声明目录和符号链接：\(path)") }
            let checksum = try fixed.u32(16)
            if isDirectory && (size != 0 || checksum != 0) {
                throw CrossZipError.message("目录条目声明了文件内容，压缩包结构异常：\(path)")
            }
            var record = ZIPMember(id: number, path: path, kind: isDirectory ? .directory : isSymlink ? .symlink : .file,
                                   size: size, compressedSize: compressed, checksum: checksum,
                                   modified: dosDate(date: try fixed.u16(14), time: try fixed.u16(12)),
                                   rawName: rawName, flags: flags, method: method, localOffset: localOffset)
            record.usesZIP64 = extras[1] != nil
            record.usesZIP64Sizes = usesZIP64Sizes
            try validateLocal(&record, handle: handle, centralOffset: index.offset, fileSize: fileSize)
            records.append(record)
            cursor += UInt64(46 + variableLength)
            context.report(phase, path: path, fraction: Double(number + 1) / Double(max(1, index.count)),
                           detail: "已检查 \(number + 1) / \(index.count) 项")
        }
        if cursor != centralEnd {
            // A central-directory digital signature is permitted after the records.
            let remaining = centralEnd - cursor
            guard remaining >= 6 else { throw CrossZipError.message("ZIP 目录长度与实际条目不符。") }
            let signature = ZIPBytes(data: try read(handle, at: cursor, count: 6, limit: fileSize))
            guard try signature.u32(0) == 0x05054b50, UInt64(try signature.u16(4)) + 6 == remaining else {
                throw CrossZipError.message("ZIP 目录包含未计入清单的条目或损坏数据。")
            }
        }
        var previousEnd: UInt64 = 0
        for record in records.sorted(by: { $0.localOffset < $1.localOffset }) {
            guard record.localOffset >= previousEnd else { throw CrossZipError.message("ZIP 条目使用了重叠的数据范围。") }
            previousEnd = record.rangeEnd
        }
        issues += PathRules.validateTree(records.map { ($0.path, $0.kind) })
        if records.contains(where: { $0.kind == .symlink }) {
            issues.append(ArchiveIssue(url.lastPathComponent, "包含符号链接，将保留链接及其原始目标路径",
                                       suggestion: "只创建链接，不读写链接目标；Windows 自带解压程序可能无法还原此类型。", severity: .warning))
        }
        if encoding == .automatic && hasLegacyNames {
            issues.append(ArchiveIssue(url.lastPathComponent, "部分文件名未声明 UTF-8，请确认预览名称是否正确",
                                       suggestion: "若显示乱码，可切换 GB18030 / GBK 或 UTF-8 后重新预览。", severity: .warning))
        }

        // Existing entries are user data, including .DS_Store and AppleDouble files.
        // Never silently omit them during extraction. The writer generates no sidecars.
        guard fingerprint.matches(try FileFingerprint.read(url)) else { throw CrossZipError.message("ZIP 在检查过程中发生变化，请重新选择。") }
        return ZIPInspection(url: url, encoding: encoding, records: records, issues: issues,
                             isZIP64: index.zip64 || records.contains(where: \.usesZIP64), fingerprint: fingerprint)
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int, limit: UInt64) throws -> Data {
        guard offset <= limit, count >= 0, UInt64(count) <= limit - offset else {
            throw CrossZipError.message("ZIP 数据偏移越界或文件被截断。")
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw CrossZipError.message("ZIP 数据读取不完整。") }
        return data
    }

    private static func readIndex(_ handle: FileHandle, fileSize: UInt64) throws -> Index {
        let length = Int(min(fileSize, 65_557))
        let tail = try read(handle, at: fileSize - UInt64(length), count: length, limit: fileSize)
        let bytes = ZIPBytes(data: tail)
        var found: Int?
        for index in stride(from: length - 22, through: 0, by: -1) {
            if try bytes.u32(index) == 0x06054b50, index + 22 + Int(try bytes.u16(index + 20)) == length {
                found = index; break
            }
        }
        guard let found else { throw CrossZipError.message("找不到完整 ZIP 结束目录，文件可能被截断。") }
        let eocd = fileSize - UInt64(length) + UInt64(found)
        guard try bytes.u16(found + 4) == 0, try bytes.u16(found + 6) == 0 else {
            throw CrossZipError.message("首版不支持分卷 ZIP。")
        }
        let count = try bytes.u16(found + 10)
        guard try bytes.u16(found + 8) == count else { throw CrossZipError.message("ZIP 的磁盘条目数量不一致。") }
        let offset = try bytes.u32(found + 16)
        let size = try bytes.u32(found + 12)
        let requiresZIP64 = count == UInt16.max || offset == UInt32.max || size == UInt32.max
        if eocd >= 20 {
            let locator = ZIPBytes(data: try read(handle, at: eocd - 20, count: 20, limit: fileSize))
            if try locator.u32(0) == 0x07064b50 {
                guard try locator.u32(4) == 0, try locator.u32(16) == 1 else { throw CrossZipError.message("首版不支持 ZIP64 分卷。") }
                let recordOffset = try locator.u64(8)
                guard recordOffset <= eocd - 20, eocd - 20 - recordOffset >= 56 else { throw CrossZipError.message("ZIP64 结束目录越界。") }
                let record = ZIPBytes(data: try read(handle, at: recordOffset, count: 56, limit: fileSize))
                guard try record.u32(0) == 0x06064b50, try record.u64(4) >= 44,
                      try record.u64(4) == eocd - 20 - recordOffset - 12,
                      try record.u32(16) == 0, try record.u32(20) == 0,
                      try record.u64(24) == record.u64(32) else { throw CrossZipError.message("ZIP64 结束目录损坏。") }
                let largeCount = try record.u64(32)
                let largeSize = try record.u64(40)
                let largeOffset = try record.u64(48)
                guard (count == UInt16.max || UInt64(count) == largeCount),
                      (size == UInt32.max || UInt64(size) == largeSize),
                      (offset == UInt32.max || UInt64(offset) == largeOffset) else { throw CrossZipError.message("ZIP64 与普通结束目录记录不一致。") }
                return Index(offset: largeOffset, size: largeSize, count: largeCount, zip64: true, endBoundary: recordOffset)
            }
        }
        guard !requiresZIP64 else { throw CrossZipError.message("ZIP64 结束目录缺失。") }
        return Index(offset: UInt64(offset), size: UInt64(size), count: UInt64(count), zip64: false, endBoundary: eocd)
    }

    private static func extraFields(_ data: Data) throws -> [UInt16: Data] {
        var fields: [UInt16: Data] = [:]
        let bytes = ZIPBytes(data: data)
        var cursor = 0
        while cursor < data.count {
            guard data.count - cursor >= 4 else { throw CrossZipError.message("ZIP 扩展字段被截断。") }
            let tag = try bytes.u16(cursor)
            let size = Int(try bytes.u16(cursor + 2))
            cursor += 4
            guard size <= data.count - cursor else { throw CrossZipError.message("ZIP 扩展字段长度无效。") }
            if fields[tag] == nil { fields[tag] = data.subdata(in: cursor..<(cursor + size)) }
            cursor += size
        }
        return fields
    }

    private static func decodeName(_ name: Data, flags: UInt16, extras: [UInt16: Data],
                                   encoding: FilenameEncoding) throws -> String {
        var data = name
        var selected = encoding.stringEncoding
        if encoding == .automatic {
            if flags & 0x0800 != 0 { selected = .utf8 }
            else if let unicode = extras[0x7075], unicode.count >= 5, unicode[0] == 1,
                    try ZIPBytes(data: unicode).u32(1) == FileSupport.crc(name) {
                selected = .utf8
                data = unicode.subdata(in: 5..<unicode.count)
            }
        }
        guard let string = String(data: data, encoding: selected), !string.isEmpty else {
            throw CrossZipError.message("文件名无法按所选编码解码，请切换编码后重新预览。")
        }
        return string
    }

    private static func validateLocal(_ member: inout ZIPMember, handle: FileHandle,
                                       centralOffset: UInt64, fileSize: UInt64) throws {
        let offset = member.localOffset
        guard offset <= centralOffset, centralOffset - offset >= 30 else { throw CrossZipError.message("ZIP 本地文件头越界：\(member.path)") }
        let header = ZIPBytes(data: try read(handle, at: offset, count: 30, limit: fileSize))
        guard try header.u32(0) == 0x04034b50, try header.u16(6) == member.flags,
              try header.u16(8) == member.method else { throw CrossZipError.message("ZIP 本地文件头与目录不一致：\(member.path)") }
        let nameSize = Int(try header.u16(26))
        let extraSize = Int(try header.u16(28))
        let headerSize = UInt64(30 + nameSize + extraSize)
        guard headerSize <= centralOffset - offset else { throw CrossZipError.message("ZIP 本地文件头长度异常。") }
        let variable = try read(handle, at: offset + 30, count: nameSize + extraSize, limit: fileSize)
        guard variable.subdata(in: 0..<nameSize) == member.rawName else { throw CrossZipError.message("ZIP 两处文件名记录不一致：\(member.path)") }
        let extras = try extraFields(variable.subdata(in: nameSize..<(nameSize + extraSize)))
        // A streamed ZIP64 local header may keep zero placeholders instead of size
        // sentinels. The extra field still declares 64-bit data-descriptor sizes.
        member.usesZIP64 = member.usesZIP64 || extras[1] != nil
        member.usesZIP64Sizes = member.usesZIP64Sizes || extras[1] != nil
        var size = UInt64(try header.u32(22))
        var compressed = UInt64(try header.u32(18))
        if size == UInt32.max || compressed == UInt32.max {
            member.usesZIP64 = true
            guard let raw = extras[1] else { throw CrossZipError.message("ZIP64 本地文件头缺少大小。") }
            let zip = ZIPBytes(data: raw)
            var position = 0
            if size == UInt32.max { size = try zip.u64(position); position += 8 }
            if compressed == UInt32.max { compressed = try zip.u64(position) }
        }
        let usesDescriptor = member.flags & 8 != 0
        if !usesDescriptor {
            guard size == member.size, compressed == member.compressedSize,
                  try header.u32(14) == member.checksum else { throw CrossZipError.message("ZIP 本地大小或 CRC 与目录不一致：\(member.path)") }
        } else {
            guard (size == 0 || size == member.size), (compressed == 0 || compressed == member.compressedSize),
                  (try header.u32(14) == 0 || header.u32(14) == member.checksum) else {
                throw CrossZipError.message("ZIP 数据描述符与文件头信息冲突：\(member.path)")
            }
        }
        member.dataOffset = offset + headerSize
        guard member.dataOffset <= centralOffset, member.compressedSize <= centralOffset - member.dataOffset else {
            throw CrossZipError.message("ZIP 文件内容被截断或越界：\(member.path)")
        }
        member.rangeEnd = member.dataOffset + member.compressedSize
        if usesDescriptor {
            let length = Int(min(24, centralOffset - member.rangeEnd))
            let data = try read(handle, at: member.rangeEnd, count: length, limit: fileSize)
            let descriptor = ZIPBytes(data: data)
            var foundLength: Int?
            for signatureSize in [4, 0] {
                if signatureSize == 4 {
                    if data.count < 4 { continue }
                    if try descriptor.u32(0) != 0x08074b50 { continue }
                }
                // Do not guess 32-bit first: for an empty ZIP64 stream, the upper
                // half of compressedSize is zero and can mimic uncompressedSize32.
                // A ZIP64 field used only for a central-directory offset does not
                // promote the member's payload sizes.
                let width = member.usesZIP64Sizes ? 8 : 4
                let needed = signatureSize + 4 + width * 2
                if needed > data.count { continue }
                if try descriptor.u32(signatureSize) == member.checksum,
                   try descriptor.integer(signatureSize + 4, width) == member.compressedSize,
                   try descriptor.integer(signatureSize + 4 + width, width) == member.size {
                    foundLength = needed
                }
                if foundLength != nil { break }
            }
            guard let foundLength else { throw CrossZipError.message("ZIP 数据描述符损坏：\(member.path)") }
            member.rangeEnd += UInt64(foundLength)
        }
    }

    private static func dosDate(date: UInt16, time: UInt16) -> Date? {
        var components = DateComponents()
        components.year = 1980 + Int(date >> 9)
        components.month = Int((date >> 5) & 15)
        components.day = Int(date & 31)
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 63)
        components.second = Int(time & 31) * 2
        guard (1...12).contains(components.month!), (1...31).contains(components.day!),
              components.hour! < 24, components.minute! < 60, components.second! < 60 else { return nil }
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
