import Foundation
import Darwin
import CryptoKit
import CLibArchive

struct NativeMember: Sendable {
    let id: Int
    let path: String
    let kind: ItemKind
    var size: UInt64
    var checksum: UInt32
    var digest: Data
    let modified: Date?
    let linkTarget: Data?
    let hardlink: String?
    var contentPath: String?
}

struct NativeInspection: Sendable {
    let url: URL
    let fingerprint: FileFingerprint
    let encoding: FilenameEncoding
    let records: [NativeMember]
    let issues: [ArchiveIssue]
    let formatName: String
    let isRawStream: Bool
    var canProceed: Bool { !issues.contains { $0.severity == .error } }
}

/// No external programs or command-output parsing. Libarchive reads metadata and
/// bytes; this layer controls every output path, link and final publication.
enum NativeArchive {
    static let chunkSize = 64 * 1024

    private static func checked(_ status: Int32, _ archive: OpaquePointer, action: String) throws {
        guard status == ARCHIVE_OK else {
            let reason = archive_error_string(archive).map { String(cString: $0) } ?? "未知归档错误"
            throw CrossZipError.message("\(action)：\(reason)")
        }
    }

    private static func name(_ pointer: UnsafePointer<CChar>?, field: String) throws -> String {
        guard let pointer, let value = String(validatingCString: pointer) else {
            throw CrossZipError.message("无法无损读取\(field)的文字编码；未修改或跳过该条目。")
        }
        return value
    }

    private static func relative(_ path: String, directory: Bool = false) -> String {
        var value = path
        while value.hasPrefix("./") { value.removeFirst(2) }
        if directory && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func isSingleFileStream(_ url: URL) -> Bool {
        let suffix = url.pathExtension.lowercased()
        return ["gz", "bz2", "xz", "lzma", "lz", "z"].contains(suffix) &&
            !url.lastPathComponent.lowercased().hasSuffix(".tar." + suffix)
    }

    private static func reader(_ handle: FileHandle, rawOnly: Bool = false) throws -> OpaquePointer {
        guard let archive = archive_read_new() else { throw CrossZipError.message("无法创建归档读取器。") }
        do {
            // Register built-in filters individually: never fall back to launching
            // gzip/xz or another program from PATH.
            for enable in [archive_read_support_filter_none, archive_read_support_filter_gzip,
                           archive_read_support_filter_bzip2, archive_read_support_filter_xz,
                           archive_read_support_filter_lzma, archive_read_support_filter_lzip,
                           archive_read_support_filter_compress] {
                try checked(enable(archive), archive, action: "初始化解压算法失败")
            }
            if !rawOnly {
                for enable in [archive_read_support_format_7zip, archive_read_support_format_tar,
                               archive_read_support_format_rar, archive_read_support_format_rar5,
                               archive_read_support_format_cab, archive_read_support_format_cpio,
                               archive_read_support_format_iso9660, archive_read_support_format_ar,
                               archive_read_support_format_empty] {
                    try checked(enable(archive), archive, action: "初始化归档格式失败")
                }
                try checked(archive_read_set_format_option(archive, "tar", "read_concatenated_archives", "1"),
                            archive, action: "设置 TAR 完整读取失败")
                // On macOS the library otherwise consumes every ._ entry as an
                // AppleDouble attachment, even when it is a real ordinary file.
                try checked(archive_read_set_format_option(archive, "tar", "mac-ext", nil),
                            archive, action: "设置隐藏文件保留策略失败")
            }
            if rawOnly {
                try checked(archive_read_support_format_empty(archive), archive, action: "初始化空数据流失败")
            }
            try checked(archive_read_support_format_raw(archive), archive, action: "初始化压缩数据流失败")
            try checked(archive_read_open_fd(archive, handle.fileDescriptor, chunkSize), archive, action: "打开压缩包失败")
            return archive
        } catch { archive_read_free(archive); throw error }
    }

    static func read(_ url: URL, encoding: FilenameEncoding = .automatic, context: JobContext,
                     phase: JobPhase = .scanning,
                     onStart: (NativeMember) throws -> Void = { _ in },
                     onData: (Data) throws -> Void = { _ in },
                     onEnd: (NativeMember) throws -> Void = { _ in }) throws -> NativeInspection {
        guard let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else { throw CrossZipError.message("无法初始化 UTF-8 文件名环境。") }
        let previousLocale = uselocale(locale)
        defer { uselocale(previousLocale); freelocale(locale) }
        context.report(phase, detail: "读取归档条目并校验内容…", force: true)
        let fingerprint = try FileFingerprint.read(url)
        let handle = try FileSupport.openRegularFile(url, expected: fingerprint)
        defer { try? handle.close() }
        // A standalone compressed file is one payload, even if it begins with
        // zero blocks or happens to contain archive bytes. Letting TAR probe it
        // can mistake a zero-filled payload for an empty archive and lose data.
        let archive = try reader(handle, rawOnly: isSingleFileStream(url))
        defer { archive_read_free(archive) }
        var records: [NativeMember] = []
        var entry: OpaquePointer?
        var ordinal = 0
        var total: UInt64 = 0
        var isRaw = false
        var isTar = false
        var isGzip = false
        var formatName = "归档"
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try context.checkCancellation()
            // Format probing can leave harmless diagnostics after a successful
            // open. Clear those, then retain actual per-entry CRC diagnostics:
            // 7z can return OK for a symlink header despite a body CRC error.
            archive_clear_error(archive)
            let status = archive_read_next_header(archive, &entry)
            if let diagnostic = archive_error_string(archive), status == ARCHIVE_OK || status == ARCHIVE_EOF {
                throw CrossZipError.message("归档条目校验失败：" + String(cString: diagnostic))
            }
            if status == ARCHIVE_EOF { break }
            try checked(status, archive, action: "归档目录不完整或不受支持")
            guard let entry else { throw CrossZipError.message("归档目录缺少条目。") }
            if archive_entry_is_encrypted(entry) != 0 {
                throw CrossZipError.message("此条目经过加密，当前版本尚不读取加密包。请先使用支持其密码格式的工具解密。")
            }
            let baseFormat = archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK
            isRaw = baseFormat == ARCHIVE_FORMAT_RAW
            isTar = baseFormat == ARCHIVE_FORMAT_TAR
            formatName = formatTitle(archive)
            guard archive_filter_count(archive) <= 2 else {
                throw CrossZipError.message("暂不自动展开多重压缩数据流，请先逐层解压；原文件未改变。")
            }
            isGzip = archive_filter_code(archive, 0) == ARCHIVE_FILTER_GZIP
            if isRaw && archive_filter_code(archive, 0) == ARCHIVE_FILTER_NONE {
                throw CrossZipError.message("这不是支持的压缩包或压缩数据流。")
            }
            let type = Int(archive_entry_filetype(entry))
            let hardlink = try archive_entry_hardlink_utf8(entry).map { relative(try name($0, field: "硬链接目标")) }
            let kind: ItemKind
            switch type {
            case Int(S_IFREG): kind = .file
            case Int(S_IFDIR): kind = .directory
            case Int(S_IFLNK): kind = .symlink
            case 0 where hardlink != nil: kind = .file
            default: throw CrossZipError.message("归档包含不能作为普通文件还原的特殊对象。")
            }
            let path = isRaw ? try rawName(url, encoding: encoding)
                : relative(try name(archive_entry_pathname_utf8(entry), field: "文件名"), directory: kind == .directory)
            let id = ordinal
            ordinal += 1
            if kind == .directory && (path.isEmpty || path == ".") {
                try checked(archive_read_data_skip(archive), archive, action: "读取根目录条目失败")
                continue
            }
            let linkTarget: Data?
            if kind == .symlink {
                guard let pointer = archive_entry_symlink_utf8(entry) ?? archive_entry_symlink(entry) else {
                    throw CrossZipError.message("归档链接没有目标路径：\(path)")
                }
                linkTarget = Data(bytes: pointer, count: strlen(pointer))
            } else { linkTarget = nil }
            let modified = archive_entry_mtime_is_set(entry) == 0 ? nil : Date(timeIntervalSince1970:
                Double(archive_entry_mtime(entry)) + Double(archive_entry_mtime_nsec(entry)) / 1e9)
            var member = NativeMember(id: id, path: path, kind: kind, size: 0, checksum: 0, digest: Data(),
                                      modified: modified, linkTarget: linkTarget, hardlink: hardlink)
            try onStart(member)
            var sha = SHA256()
            var count: UInt64 = 0
            var crc: UInt32 = 0
            let declared = archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil
            if kind != .file {
                if isTar && declared != nil && declared != 0 { throw CrossZipError.message("TAR 非文件条目声明了额外数据：\(path)") }
                try checked(archive_read_data_skip(archive), archive, action: "完成目录或链接条目失败")
            }
            while kind == .file {
                try context.checkCancellation()
                let bytes = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
                guard bytes >= 0 else { try checked(Int32(bytes), archive, action: "读取或校验归档内容失败"); continue }
                if bytes == 0 { break }
                guard kind == .file, hardlink == nil, UInt64(bytes) <= UInt64(Int64.max) - count else {
                    throw CrossZipError.message("归档内容大小或条目类型异常：\(path)")
                }
                count += UInt64(bytes)
                if let declared, declared < 0 || count > UInt64(declared) {
                    throw CrossZipError.message("实际内容超过归档声明的大小：\(path)")
                }
                let data = Data(buffer.prefix(bytes))
                sha.update(data: data); crc = FileSupport.crc(data, seed: crc)
                try onData(data)
                context.report(phase, path: path, detail: "已读取 \(records.count + 1) 项")
            }
            if kind == .file && hardlink == nil, let declared, declared < 0 || count != UInt64(declared) {
                throw CrossZipError.message("归档文件内容被截断：\(path)")
            }
            if let target = linkTarget {
                sha.update(data: target); crc = FileSupport.crc(target); count = UInt64(target.count)
            }
            guard total <= UInt64(Int64.max) - count else { throw CrossZipError.message("解压总大小超过支持范围。") }
            total += count
            member.size = count; member.checksum = crc; member.digest = Data(sha.finalize())
            records.append(member)
            try onEnd(member)
            context.report(phase, path: path, detail: "已读取 \(records.count) 项")
        }
        // Empty 7z/TAR archives may return EOF on the first header.
        formatName = formatTitle(archive)
        let baseFormat = archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK
        isTar = baseFormat == ARCHIVE_FORMAT_TAR
        isRaw = baseFormat == ARCHIVE_FORMAT_RAW
        isGzip = archive_filter_code(archive, 0) == ARCHIVE_FILTER_GZIP
        guard archive_filter_count(archive) <= 2 else { throw CrossZipError.message("暂不自动展开多重压缩数据流，请先逐层解压；原文件未改变。") }
        if records.isEmpty && (baseFormat == ARCHIVE_FORMAT_EMPTY || isRaw) && archive_filter_code(archive, 0) != ARCHIVE_FILTER_NONE {
            isRaw = true
            let path = try rawName(url, encoding: encoding)
            let member = NativeMember(id: 0, path: path, kind: .file, size: 0, checksum: 0,
                                      digest: Data(SHA256.hash(data: Data())), modified: nil, linkTarget: nil, hardlink: nil)
            try onStart(member); try onEnd(member); records.append(member)
        }
        if (baseFormat == ARCHIVE_FORMAT_EMPTY && !isRaw) || (isRaw && archive_filter_code(archive, 0) == ARCHIVE_FILTER_NONE) {
            throw CrossZipError.message("不是支持的压缩包。")
        }
        try checked(archive_read_close(archive), archive, action: "归档结束记录或校验信息不完整")
        try resolveHardlinks(&records)
        if isGzip {
            var tail = Data()
            var total: UInt64 = 0
            try GzipValidator.read(url, fingerprint: fingerprint, context: context) { data in
                guard UInt64(data.count) <= UInt64(Int64.max) - total else { throw CrossZipError.message("GZIP 数据流过大。") }
                total += UInt64(data.count)
                if isTar {
                    tail.append(data)
                    if tail.count > 1024 { tail = Data(tail.suffix(1024)) }
                }
            }
            if isTar { try checkTarTail(tail, size: total) }
        } else if isTar { try validateTarTrailer(url, fingerprint: fingerprint, context: context) }
        var issues = PathRules.validateTree(records.map { ($0.path, $0.kind) })
        if records.contains(where: { $0.kind == .symlink }) {
            issues.append(ArchiveIssue(url.lastPathComponent, "按链接本身保留其原目标路径", suggestion: "不会读取或写入链接指向的位置。", severity: .warning))
        }
        guard fingerprint.matches(try FileFingerprint.read(url)) else { throw CrossZipError.message("压缩包在读取过程中发生变化。") }
        return NativeInspection(url: url, fingerprint: fingerprint, encoding: encoding, records: records, issues: issues,
                                formatName: formatName, isRawStream: isRaw)
    }

    private static func resolveHardlinks(_ records: inout [NativeMember]) throws {
        var index: [Data: Int] = [:]
        for (number, member) in records.enumerated() { index[Data(member.path.utf8)] = number }
        var resolved: Set<Int> = []
        func resolve(_ number: Int, visiting: Set<Int>) throws {
            if resolved.contains(number) { return }
            guard !visiting.contains(number) else { throw CrossZipError.message("归档硬链接形成循环，无法还原内容。") }
            if let target = records[number].hardlink {
                guard let other = index[Data(target.utf8)], records[other].kind == .file else {
                    throw CrossZipError.message("归档硬链接的目标文件缺失：\(records[number].path)")
                }
                var visiting = visiting; visiting.insert(number)
                try resolve(other, visiting: visiting)
                records[number].size = records[other].size
                records[number].checksum = records[other].checksum
                records[number].digest = records[other].digest
                records[number].contentPath = records[other].contentPath ?? records[other].path
            }
            resolved.insert(number)
        }
        for number in records.indices { try resolve(number, visiting: []) }
        var total: UInt64 = 0
        for member in records {
            guard member.size <= UInt64(Int64.max) - total else { throw CrossZipError.message("解压总大小超过支持范围。") }
            total += member.size
        }
    }

    private static func validateTarTrailer(_ url: URL, fingerprint: FileFingerprint, context: JobContext) throws {
        let file = try FileSupport.openRegularFile(url, expected: fingerprint)
        defer { try? file.close() }
        let archive = try reader(file, rawOnly: true)
        defer { archive_read_free(archive) }
        var entry: OpaquePointer?
        try checked(archive_read_next_header(archive, &entry), archive, action: "读取 TAR 数据流失败")
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var tail = Data()
        var total: UInt64 = 0
        while true {
            try context.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
            if count < 0 { try checked(Int32(count), archive, action: "TAR 压缩数据流损坏") }
            if count == 0 { break }
            guard UInt64(count) <= UInt64(Int64.max) - total else { throw CrossZipError.message("TAR 数据流过大。") }
            total += UInt64(count)
            tail.append(contentsOf: buffer.prefix(count))
            if tail.count > 1024 { tail = Data(tail.suffix(1024)) }
        }
        try checkTarTail(tail, size: total)
        try checked(archive_read_close(archive), archive, action: "TAR 数据流结束校验失败")
    }

    private static func checkTarTail(_ tail: Data, size: UInt64) throws {
        guard size >= 1024, size % 512 == 0, tail.count == 1024, tail.allSatisfy({ $0 == 0 }) else {
            throw CrossZipError.message("TAR 缺少完整结束块，文件可能已截断。")
        }
    }

    private static func formatTitle(_ archive: OpaquePointer) -> String {
        let format = archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK
        let filter = archive_filter_code(archive, 0)
        switch format {
        case ARCHIVE_FORMAT_TAR:
            switch filter {
            case ARCHIVE_FILTER_GZIP: return "TAR.GZ"
            case ARCHIVE_FILTER_BZIP2: return "TAR.BZ2"
            case ARCHIVE_FILTER_XZ: return "TAR.XZ"
            default: return "TAR"
            }
        case ARCHIVE_FORMAT_7ZIP: return "7z"
        case ARCHIVE_FORMAT_RAR: return "RAR"
        case ARCHIVE_FORMAT_RAR_V5: return "RAR5"
        case ARCHIVE_FORMAT_RAW, ARCHIVE_FORMAT_EMPTY: return archive_filter_name(archive, 0).map { String(cString: $0).uppercased() } ?? "压缩数据流"
        case ARCHIVE_FORMAT_CAB: return "CAB"
        case ARCHIVE_FORMAT_CPIO: return "CPIO"
        case ARCHIVE_FORMAT_ISO9660: return "ISO"
        case ARCHIVE_FORMAT_AR: return "AR"
        default: return archive_format_name(archive).map { String(cString: $0) } ?? "归档"
        }
    }

    private static func rawName(_ url: URL, encoding: FilenameEncoding) throws -> String {
        // GZIP's optional original filename is an ISO-8859-1 field; modern tools
        // also place UTF-8 bytes here. Explicit encoding remains available in UI.
        if url.pathExtension.lowercased() == "gz" {
            let file = try FileSupport.openRegularFile(url)
            defer { try? file.close() }
            let header = try file.read(upToCount: 131_072) ?? Data()
            if header.count >= 10 && header[0] == 0x1f && header[1] == 0x8b {
                let flags = header[3]
                var offset = 10
                if flags & 4 != 0, header.count >= 12 { offset = 12 + Int(header[10]) + Int(header[11]) * 256 }
                if flags & 8 != 0, offset < header.count,
                   let end = header[offset...].firstIndex(of: 0), end > offset {
                    let bytes = header.subdata(in: offset..<end)
                    let decoded = encoding == .automatic ? (String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1))
                        : String(data: bytes, encoding: encoding.stringEncoding)
                    guard let decoded else { throw CrossZipError.message("无法按所选编码读取 GZIP 原文件名。") }
                    return decoded
                }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

extension NativeArchive {
    static func measuredSize(_ plan: SourcePlan, to url: URL, format: ArchiveFormat, level: CompressionLevel,
                             storeOnly: Bool, context: JobContext) throws -> UInt64 {
        _ = try writePreferred(plan, to: url, format: format, level: level, storeOnly: storeOnly, context: context)
        return UInt64(try FileFingerprint.read(url).size)
    }

    private struct ExpectedContent {
        let kind: ItemKind
        let size: UInt64
        let digest: Data
    }

    static func compress(_ sources: [URL], to destination: URL, format: ArchiveFormat,
                         level: CompressionLevel, storeOnly: Bool = false, excluding: [URL] = [],
                         enclosingFolderName: String? = nil, context: JobContext,
                         availableSpace: (URL) throws -> UInt64 = FileSupport.availableBytes) throws -> OperationResult {
        let plan = try SourceScanner.scan(sources, context: context, excluding: excluding, enclosingFolderName: enclosingFolderName)
        guard plan.canProceed else { throw CrossZipError.issues(plan.issues) }
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        try checkParent(parent)
        let resolved = parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent)
        for source in plan.sources where (try FileFingerprint.read(source).kind) == .directory {
            if PathRules.contains(resolved, in: source.resolvingSymlinksInPath()) {
                throw CrossZipError.message("压缩包不能保存在待压缩目录内部。请选择其他位置。")
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) { throw CrossZipError.message("目标已存在，未覆盖原文件。") }
        try FileSupport.requireSpace(128 * 1024, at: parent, availableOverride: availableSpace(parent))
        let work = try workDirectory(in: parent)
        defer { try? FileManager.default.removeItem(at: work) }
        let temporary = work.appendingPathComponent("archive." + format.rawValue)
        let expected = try writePreferred(plan, to: temporary, format: format, level: level, storeOnly: storeOnly, context: context)
        context.report(.verifying, detail: "重新读取归档，核对清单和 SHA-256…", force: true)
        if format == .zip {
            let inspection = try ZIPInspector.inspect(temporary, context: context, phase: .verifying)
            guard inspection.canProceed else { throw CrossZipError.issues(inspection.issues) }
            guard inspection.records.count == expected.count else { throw CrossZipError.message("ZIP 条目数量与源文件不一致。") }
            let file = try FileSupport.openRegularFile(temporary, expected: inspection.fingerprint)
            defer { try? file.close() }
            for (number, member) in inspection.records.enumerated() {
                guard let source = expected[Data(member.path.utf8)], source.kind == member.kind, source.size == member.size,
                      member.rawName.allSatisfy({ $0 < 128 }) || member.flags & 0x0800 != 0 else {
                    throw CrossZipError.message("ZIP 名称、类型、大小或 UTF-8 声明不一致：\(member.path)")
                }
                var sha = SHA256()
                _ = try ZIPPayloadReader.read(member, from: file, context: context) { sha.update(data: $0) }
                guard Data(sha.finalize()) == source.digest else { throw CrossZipError.message("ZIP 内容校验失败：\(member.path)") }
                context.report(.verifying, path: member.path, fraction: Double(number + 1) / Double(max(1, expected.count)))
            }
        } else {
            let inspection = try read(temporary, context: context, phase: .verifying)
            guard inspection.canProceed else { throw CrossZipError.issues(inspection.issues) }
            guard inspection.records.count == expected.count else { throw CrossZipError.message("归档结果条目数量与源文件不一致。") }
            for member in inspection.records {
                guard let source = expected[Data(member.path.utf8)], source.kind == member.kind,
                      source.size == member.size, source.digest == member.digest else {
                    throw CrossZipError.message("归档中的原名称、类型、大小或内容不一致：\(member.path)")
                }
            }
        }
        let latest = try SourceScanner.scan(plan.sources, context: context, reportProgress: false,
                                            excluding: excluding, enclosingFolderName: enclosingFolderName)
        guard latest.canProceed, latest.items.count == plan.items.count else { throw CrossZipError.message("源文件清单在压缩时发生变化。") }
        for (before, after) in zip(plan.items, latest.items) {
            guard before.path.utf8.elementsEqual(after.path.utf8), before.fingerprint.matches(after.fingerprint),
                  before.linkTarget == after.linkTarget else { throw CrossZipError.message("源文件在压缩时发生变化：\(before.path)") }
        }
        try context.checkCancellation()
        guard try FileSupport.publishIfAbsent(temporary, to: destination) else { throw CrossZipError.message("目标已存在，未覆盖原文件。") }
        context.report(.finished, path: destination.path, fraction: 1, detail: "归档已通过全部内容校验", force: true)
        return OperationResult(url: destination, fileCount: plan.fileCount, directoryCount: plan.directoryCount,
                               totalBytes: plan.totalBytes, excludedCount: 0)
    }

    private static func writePreferred(_ plan: SourcePlan, to destination: URL, format: ArchiveFormat,
                                       level: CompressionLevel, storeOnly: Bool, context: JobContext) throws -> [Data: ExpectedContent] {
        let levels: [CompressionLevel] = level == .maximum && format.supportsLevel && !storeOnly
            ? [.maximum, .standard, .fast] : [level]
        var bestURL: URL?, bestSize = UInt64.max
        var expected: [Data: ExpectedContent] = [:]
        for (pass, preset) in levels.enumerated() {
            try context.checkCancellation()
            let candidate = pass == 0 ? destination : destination.appendingPathExtension("level-\(preset.rawValue)")
            let contents = try write(plan, to: candidate, format: format, level: preset, storeOnly: storeOnly,
                                     context: context, pass: pass, passes: levels.count)
            if pass > 0 {
                guard contents.count == expected.count, contents.allSatisfy({ key, item in
                    expected[key].map { $0.kind == item.kind && $0.size == item.size && $0.digest == item.digest } == true
                }) else { throw CrossZipError.message("源文件在比较压缩等级时发生变化。") }
            } else { expected = contents }
            let size = UInt64(try FileFingerprint.read(candidate).size)
            if size < bestSize {
                if let bestURL { try FileManager.default.removeItem(at: bestURL) }
                bestURL = candidate; bestSize = size
            } else { try FileManager.default.removeItem(at: candidate) }
        }
        if let bestURL, bestURL != destination { try FileManager.default.moveItem(at: bestURL, to: destination) }
        return expected
    }

    private static func write(_ plan: SourcePlan, to destination: URL, format: ArchiveFormat,
                              level: CompressionLevel, storeOnly: Bool, context: JobContext,
                              pass: Int = 0, passes: Int = 1) throws -> [Data: ExpectedContent] {
        guard let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else { throw CrossZipError.message("无法初始化 UTF-8 文件名环境。") }
        let previousLocale = uselocale(locale)
        defer { uselocale(previousLocale); freelocale(locale) }
        guard let archive = archive_write_new() else { throw CrossZipError.message("无法创建归档写入器。") }
        defer { archive_write_free(archive) }
        if format == .zip {
            try checked(archive_write_set_format_zip(archive), archive, action: "设置 ZIP 格式失败")
            try checked(archive_write_set_format_option(archive, "zip", "hdrcharset", "UTF-8"), archive, action: "设置 UTF-8 文件名失败")
            try checked(archive_write_set_format_option(archive, "zip", "compression", storeOnly ? "store" : "deflate"), archive, action: "设置 ZIP 算法失败")
            try checked(archive_write_set_format_option(archive, "zip", "compression-level", String(level.rawValue)), archive, action: "设置 ZIP 压缩等级失败")
        } else if format == .sevenZip {
            try checked(archive_write_set_format_7zip(archive), archive, action: "设置 7z 格式失败")
            try checked(archive_write_set_format_option(archive, "7zip", "compression", "lzma2"), archive, action: "设置 7z 算法失败")
            try checked(archive_write_set_format_option(archive, "7zip", "compression-level", String(level.rawValue)), archive, action: "设置 7z 压缩等级失败")
        } else {
            try checked(archive_write_set_format_pax_restricted(archive), archive, action: "设置 TAR 格式失败")
            let filter: String?
            switch format {
            case .tarGzip:
                try checked(archive_write_add_filter_gzip(archive), archive, action: "设置 GZIP 失败"); filter = "gzip"
            case .tarBzip2:
                try checked(archive_write_add_filter_bzip2(archive), archive, action: "设置 BZIP2 失败"); filter = "bzip2"
            case .tarXz:
                try checked(archive_write_add_filter_xz(archive), archive, action: "设置 XZ 失败"); filter = "xz"
            default: filter = nil
            }
            if let filter {
                try checked(archive_write_set_filter_option(archive, filter, "compression-level", String(level.rawValue)), archive, action: "设置压缩等级失败")
            }
        }
        try checked(archive_write_set_bytes_per_block(archive, 0), archive, action: "设置归档数据块失败")
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        try checked(archive_write_open_fd(archive, descriptor), archive, action: "创建归档文件失败")
        let total = plan.items.reduce(0.0) { $0 + Double(max(1, $1.size)) }
        var completed = 0.0
        var expected: [Data: ExpectedContent] = [:]
        context.report(.compressing, fraction: Double(pass) / Double(passes),
                       detail: passes > 1 ? "比较压缩等级 \(pass + 1)/\(passes)…" : "创建 \(format.rawValue)…", force: true)
        if let root = plan.enclosingFolderName {
            guard let entry = archive_entry_new() else { throw CrossZipError.message("无法创建外层目录。") }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, root + "/")
            archive_entry_set_filetype(entry, numericCast(S_IFDIR)); archive_entry_set_size(entry, 0)
            archive_entry_set_perm(entry, 0o755)
            archive_entry_set_mtime(entry, time(nil), 0)
            try checked(archive_write_header(archive, entry), archive, action: "写入外层目录失败")
            try checked(archive_write_finish_entry(archive), archive, action: "完成外层目录失败")
            expected[Data(root.utf8)] = ExpectedContent(kind: .directory, size: 0, digest: Data(SHA256.hash(data: Data())))
        }
        for item in plan.items {
            try context.checkCancellation()
            guard item.fingerprint.matches(try FileFingerprint.read(item.url)) else { throw CrossZipError.message("源文件在扫描后发生变化：\(item.path)") }
            guard let entry = archive_entry_new() else { throw CrossZipError.message("无法创建归档条目。") }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, item.path)
            archive_entry_set_perm(entry, numericCast(item.fingerprint.mode & 0o777))
            archive_entry_set_mtime(entry, numericCast(item.fingerprint.modifiedSeconds), numericCast(item.fingerprint.modifiedNanos))
            switch item.kind {
            case .directory:
                archive_entry_set_filetype(entry, numericCast(S_IFDIR)); archive_entry_set_size(entry, 0)
            case .symlink:
                archive_entry_set_filetype(entry, numericCast(S_IFLNK)); archive_entry_set_size(entry, 0)
                guard let target = item.linkTarget, target == (try FileSupport.readLink(item.url, expected: item.fingerprint)) else {
                    throw CrossZipError.message("链接在扫描后发生变化：\(item.path)")
                }
                (target + Data([0])).withUnsafeBytes { bytes in
                    archive_entry_set_symlink(entry, bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
            case .file:
                archive_entry_set_filetype(entry, numericCast(S_IFREG)); archive_entry_set_size(entry, Int64(item.size))
            }
            try checked(archive_write_header(archive, entry), archive, action: "写入条目失败：\(item.path)")
            var sha = SHA256()
            if item.kind == .file {
                let handle = try FileSupport.openRegularFile(item.url, expected: item.fingerprint)
                defer { try? handle.close() }
                var count: UInt64 = 0
                while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
                    try context.checkCancellation()
                    guard count <= item.size, UInt64(data.count) <= item.size - count else { throw CrossZipError.message("源文件变大：\(item.path)") }
                    let written = data.withUnsafeBytes { archive_write_data(archive, $0.baseAddress, $0.count) }
                    if written < 0 { try checked(Int32(written), archive, action: "写入文件失败：\(item.path)") }
                    guard written == data.count else { throw CrossZipError.message("归档文件写入不完整：\(item.path)") }
                    count += UInt64(data.count); sha.update(data: data)
                    context.report(.compressing, path: item.path,
                                   fraction: (Double(pass) + (completed + Double(count)) / max(1, total)) / Double(passes))
                }
                guard count == item.size, item.fingerprint.matches(try FileFingerprint.read(item.url)) else {
                    throw CrossZipError.message("源文件在压缩过程中发生变化：\(item.path)")
                }
            } else if let target = item.linkTarget { sha.update(data: target) }
            try checked(archive_write_finish_entry(archive), archive, action: "完成条目失败：\(item.path)")
            expected[Data(item.path.utf8)] = ExpectedContent(kind: item.kind, size: item.size, digest: Data(sha.finalize()))
            completed += Double(max(1, item.size))
        }
        context.report(.compressing, fraction: Double(pass + 1) / Double(passes),
                       detail: "正在完成归档目录与压缩数据流…", force: true)
        try context.checkCancellation()
        try checked(archive_write_close(archive), archive, action: "写入归档结束记录失败")
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return expected
    }

    static func extract(_ inspection: NativeInspection, to parent: URL, selected: Set<Int>, context: JobContext) throws -> OperationResult {
        guard inspection.fingerprint.matches(try FileFingerprint.read(inspection.url)) else { throw CrossZipError.message("归档在预览后发生变化，请重新预览。") }
        let members = inspection.records.filter { selected.contains($0.id) }
        let parent = parent.standardizedFileURL
        try checkParent(parent)
        let caseSensitive = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? false
        let conflicts = PathRules.extractionConflicts(members.map { ($0.path, $0.kind) }, caseSensitive: caseSensitive)
        guard conflicts.isEmpty else { throw CrossZipError.message(conflicts.map { "\($0.path)：\($0.reason)" }.joined(separator: "\n")) }
        let needed = Set(members.compactMap { $0.contentPath }.map { Data($0.utf8) })
        let cachedBytes = inspection.records.filter { needed.contains(Data($0.path.utf8)) && !selected.contains($0.id) }.reduce(UInt64(0)) { $0 + $1.size }
        let totalBytes = members.reduce(UInt64(0)) { $0 + $1.size }
        try FileSupport.requireSpace(totalBytes + cachedBytes, at: parent)
        let work = try workDirectory(in: parent)
        defer { try? FileManager.default.removeItem(at: work) }
        let output = work.appendingPathComponent("output", isDirectory: true)
        let cache = work.appendingPathComponent("content", isDirectory: true)
        for directory in [output, cache] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let expected = Dictionary(uniqueKeysWithValues: inspection.records.map { ($0.id, $0) })
        var active: FileHandle?
        defer { try? active?.close() }
        var contentFiles: [Data: URL] = [:]
        let readback = try read(inspection.url, encoding: inspection.encoding, context: context, phase: .extracting,
                               onStart: { incoming in
            guard let member = expected[incoming.id], member.path.utf8.elementsEqual(incoming.path.utf8),
                  member.kind == incoming.kind, member.linkTarget == incoming.linkTarget, member.hardlink == incoming.hardlink else {
                throw CrossZipError.message("归档清单在解压时发生变化。")
            }
            let chosen = selected.contains(member.id)
            if member.kind == .directory {
                if chosen { try createParent(output.appendingPathComponent(member.path, isDirectory: true)) }
            } else if member.kind == .file && member.hardlink == nil && (chosen || needed.contains(Data(member.path.utf8))) {
                let destination = chosen ? output.appendingPathComponent(member.path) : cache.appendingPathComponent(String(member.id))
                guard PathRules.contains(destination, in: work) else { throw CrossZipError.message("归档条目越界。") }
                try createParent(destination.deletingLastPathComponent())
                let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                active = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                contentFiles[Data(member.path.utf8)] = destination
            }
        }, onData: { data in try active?.write(contentsOf: data) }, onEnd: { _ in
            try active?.synchronize(); try active?.close(); active = nil
        })
        guard readback.records.count == inspection.records.count else { throw CrossZipError.message("归档读取条目数不一致。") }
        for (before, after) in zip(inspection.records, readback.records) {
            guard before.path.utf8.elementsEqual(after.path.utf8), before.kind == after.kind,
                  before.size == after.size, before.digest == after.digest else {
                throw CrossZipError.message("归档内容在解压时发生变化：\(before.path)")
            }
        }
        for member in members where member.hardlink != nil {
            try context.checkCancellation()
            guard let source = member.contentPath.flatMap({ contentFiles[Data($0.utf8)] }) else { throw CrossZipError.message("硬链接内容未完整读取：\(member.path)") }
            let destination = output.appendingPathComponent(member.path)
            try createParent(destination.deletingLastPathComponent())
            try FileManager.default.copyItem(at: source, to: destination)
        }
        // Ordinary writes and hard-link content copies finish before any symlinks.
        for member in members where member.kind == .symlink {
            try context.checkCancellation()
            guard let target = member.linkTarget, !target.isEmpty, !target.contains(0), target.count < Int(PATH_MAX) else {
                throw CrossZipError.message("目标磁盘无法按原样还原此链接：\(member.path)")
            }
            let destination = output.appendingPathComponent(member.path)
            try createParent(destination.deletingLastPathComponent())
            let status = (target + Data([0])).withUnsafeBytes { bytes in symlink(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), destination.path) }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        for member in members.reversed() where member.kind != .symlink {
            if let date = member.modified { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: output.appendingPathComponent(member.path).path) }
        }
        context.report(.verifying, detail: "复核输出名称、类型、大小与 SHA-256…", force: true)
        for (number, member) in members.enumerated() {
            try context.checkCancellation()
            let destination = output.appendingPathComponent(member.path)
            let fingerprint = try FileFingerprint.read(destination)
            guard fingerprint.kind == member.kind else { throw CrossZipError.message("输出条目类型改变：\(member.path)") }
            var sha = SHA256()
            if member.kind == .file {
                guard fingerprint.size >= 0, UInt64(fingerprint.size) == member.size else { throw CrossZipError.message("输出文件大小不一致：\(member.path)") }
                let file = try FileSupport.openRegularFile(destination, expected: fingerprint)
                defer { try? file.close() }
                while let data = try file.read(upToCount: chunkSize), !data.isEmpty { try context.checkCancellation(); sha.update(data: data) }
            } else if member.kind == .symlink { sha.update(data: try FileSupport.readLink(destination, expected: fingerprint)) }
            guard Data(sha.finalize()) == member.digest else { throw CrossZipError.message("输出文件内容校验失败：\(member.path)") }
            context.report(.verifying, path: member.path, fraction: Double(number + 1) / Double(max(1, members.count)))
        }
        guard inspection.fingerprint.matches(try FileFingerprint.read(inspection.url)) else { throw CrossZipError.message("归档在解压时发生变化。") }
        var number = 1
        var destination: URL
        while true {
            try context.checkCancellation()
            destination = parent.appendingPathComponent(OutputNames.extractionName(for: ArchiveFormat.stem(of: inspection.url), number: number), isDirectory: true)
            if try FileSupport.publishIfAbsent(output, to: destination) { break }
            number += 1
        }
        context.report(.finished, path: destination.path, fraction: 1, detail: "所选内容已通过全部校验", force: true)
        let files = members.filter { $0.kind != .directory }.count
        return OperationResult(url: destination, fileCount: files, directoryCount: members.count - files,
                               totalBytes: totalBytes, excludedCount: inspection.records.count - members.count)
    }

    private static func checkParent(_ parent: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
            throw CrossZipError.message("目标文件夹不存在。")
        }
    }
    private static func createParent(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private static func workDirectory(in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(".crosszip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
}
