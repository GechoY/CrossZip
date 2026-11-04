import Foundation

public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip, sevenZip = "7z", tar, tarGzip = "tar.gz", tarBzip2 = "tar.bz2", tarXz = "tar.xz"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .zip: return "ZIP · 通用交换"
        case .sevenZip: return "7z · 较高压缩率"
        case .tar: return "TAR · 仅打包"
        case .tarGzip: return "TAR.GZ · 常用归档"
        case .tarBzip2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ · 较高压缩率"
        }
    }
    public var supportsLevel: Bool { self != .tar }
    public var note: String {
        switch self {
        case .zip: return "适合日常交换。Windows 自带工具兼容性仍受文件名与系统版本限制。"
        case .sevenZip: return "通常能压得更小，接收方需支持 7z 的解压工具。"
        case .tar: return "只整理目录与文件，不压缩数据。"
        default: return "先保留文件与目录，再压缩 TAR 数据流。"
        }
    }
    public static let readableExtensions = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "cab", "cpio", "iso", "ar", "lzma", "lz", "z"]
    public static func recognizes(_ url: URL) -> Bool { readableExtensions.contains(url.pathExtension.lowercased()) }
    public static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.lzma", ".tar.lz"] {
            if name.lowercased().hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

public enum CompressionLevel: Int, CaseIterable, Identifiable, Sendable {
    case fast = 1, standard = 6, maximum = 9
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .fast: return "快速"
        case .standard: return "标准（推荐）"
        case .maximum: return "体积优先（较慢）"
        }
    }
}

public struct ArchiveContent: Identifiable, Sendable {
    public let id: Int
    public let path: String
    public let kind: ItemKind
    public let size: UInt64
    public let checksum: UInt32
    public var isExcluded: Bool { false }
}

public struct ArchiveInspection: Sendable {
    enum Backend: Sendable { case zip(ZIPInspection), native(NativeInspection) }
    let backend: Backend
    public let url: URL
    public let records: [ArchiveContent]
    public let issues: [ArchiveIssue]
    public let formatName: String
    public let isZIP64: Bool
    public let supportsFilenameEncoding: Bool
    public let encoding: FilenameEncoding
    public var members: [ArchiveContent] { records }
    public var canProceed: Bool { !issues.contains { $0.severity == .error } }
    public var totalBytes: UInt64 { records.reduce(0) { $0 + $1.size } }
    public var fileCount: Int { records.filter { $0.kind != .directory }.count }
    public var directoryCount: Int { records.count - fileCount }
    public var excludedCount: Int { 0 }

    init(_ zip: ZIPInspection) {
        backend = .zip(zip); url = zip.url; issues = zip.issues; isZIP64 = zip.isZIP64
        formatName = zip.isZIP64 ? "ZIP64" : "ZIP"; supportsFilenameEncoding = true
        encoding = zip.encoding
        records = zip.records.map { ArchiveContent(id: $0.id, path: $0.path, kind: $0.kind, size: $0.size, checksum: $0.checksum) }
    }
    init(_ native: NativeInspection) {
        backend = .native(native); url = native.url; issues = native.issues; isZIP64 = false
        formatName = native.formatName
        supportsFilenameEncoding = native.isRawStream && native.formatName == "GZIP"
        encoding = native.encoding
        records = native.records.map { ArchiveContent(id: $0.id, path: $0.path, kind: $0.kind, size: $0.size, checksum: $0.checksum) }
    }

    func selection(_ requested: Set<Int>?) throws -> Set<Int> {
        let all = Set(records.map(\.id))
        guard let requested else { return all }
        if all.isEmpty && requested.isEmpty { return [] }
        guard !requested.isEmpty, requested.isSubset(of: all) else {
            throw CrossZipError.message("请至少勾选一个有效的文件或文件夹。")
        }
        let directories = records.filter { requested.contains($0.id) && $0.kind == .directory }.map { $0.path + "/" }
        return Set(records.filter { requested.contains($0.id) || directories.contains(where: $0.path.hasPrefix) }.map(\.id))
    }
}

/// ZIP keeps its strict independent directory parser. Other archive formats share
/// one streaming backend and the same output-safety and source-stability rules.
public struct ArchiveManager {
    public init() {}

    public func inspect(_ url: URL, encoding: FilenameEncoding = .automatic,
                        context: JobContext = JobContext()) throws -> ArchiveInspection {
        let handle = try FileSupport.openRegularFile(url)
        let prefix = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        // TAR starts with its first pathname, which can also begin with "PK".
        // Recognize complete ZIP signatures, including empty ZIP/ZIP64 files.
        let zipSignatures: [Data] = [
            Data([0x50, 0x4b, 0x03, 0x04]), Data([0x50, 0x4b, 0x05, 0x06]),
            Data([0x50, 0x4b, 0x06, 0x06]), Data([0x50, 0x4b, 0x07, 0x08])
        ]
        if zipSignatures.contains(prefix) {
            return ArchiveInspection(try ZIPInspector.inspect(url, encoding: encoding, context: context))
        }
        return ArchiveInspection(try NativeArchive.read(url, encoding: encoding, context: context))
    }

    public func compress(_ sources: [URL], to destination: URL, format: ArchiveFormat = .zip,
                         level: CompressionLevel = .maximum, storeOnly: Bool = false,
                         excluding: [URL] = [], enclosingFolderName: String? = nil,
                         context: JobContext = JobContext()) throws -> OperationResult {
        return try NativeArchive.compress(sources, to: destination, format: format, level: level, storeOnly: storeOnly,
                                          excluding: excluding, enclosingFolderName: enclosingFolderName, context: context)
    }

    public func extract(_ inspection: ArchiveInspection, to parent: URL, selectedIDs: Set<Int>? = nil,
                        context: JobContext = JobContext()) throws -> OperationResult {
        guard inspection.canProceed else { throw CrossZipError.issues(inspection.issues) }
        let selected = try inspection.selection(selectedIDs)
        switch inspection.backend {
        case .zip(let zip):
            let records = zip.records.map { record -> ZIPMember in
                var item = record
                item.isExcluded = !selected.contains(item.id)
                return item
            }
            let subset = ZIPInspection(url: zip.url, encoding: zip.encoding, records: records, issues: zip.issues,
                                       isZIP64: zip.isZIP64, fingerprint: zip.fingerprint)
            return try ArchiveService().extract(subset, to: parent, context: context)
        case .native(let native):
            return try NativeArchive.extract(native, to: parent, selected: selected, context: context)
        }
    }

    public func verify(_ url: URL, encoding: FilenameEncoding = .automatic,
                       context: JobContext = JobContext()) throws -> ArchiveInspection {
        let inspection = try inspect(url, encoding: encoding, context: context)
        guard inspection.canProceed else { throw CrossZipError.issues(inspection.issues) }
        if case .zip(let zip) = inspection.backend {
            _ = try ArchiveService().verify(zip, context: context)
        }
        context.report(.finished, fraction: 1, detail: "全部条目与内容校验通过", force: true)
        return inspection
    }
}
