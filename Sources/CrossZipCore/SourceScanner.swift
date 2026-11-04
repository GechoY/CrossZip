import Foundation

public struct SourceItem: Sendable {
    public let url: URL
    public let path: String
    public let kind: ItemKind
    public var size: UInt64 { kind == .directory ? 0 : UInt64(fingerprint.size) }
    let fingerprint: FileFingerprint
    let linkTarget: Data?

    init(url: URL, path: String, kind: ItemKind, fingerprint: FileFingerprint, linkTarget: Data? = nil) {
        self.url = url; self.path = path; self.kind = kind; self.fingerprint = fingerprint; self.linkTarget = linkTarget
    }
}

public struct SourcePlan: Sendable {
    public let sources: [URL]
    public let items: [SourceItem]
    public let excluded: [String]
    public let issues: [ArchiveIssue]
    public let totalBytes: UInt64
    public let enclosingFolderName: String?
    public let rootCount: Int
    public var fileCount: Int { items.filter { $0.kind != .directory }.count }
    public var directoryCount: Int { items.count - fileCount + (enclosingFolderName == nil ? 0 : 1) }
    public var canProceed: Bool { !items.isEmpty && !issues.contains { $0.severity == .error } }

    init(sources: [URL], items: [SourceItem], excluded: [String], issues: [ArchiveIssue], enclosingFolderName: String? = nil,
         rootCount: Int? = nil) {
        self.sources = sources; self.items = items; self.excluded = excluded
        self.enclosingFolderName = enclosingFolderName
        self.rootCount = rootCount ?? sources.count
        totalBytes = items.reduce(UInt64(0)) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.size)
            return overflow ? UInt64.max : sum
        }
        self.issues = issues + (totalBytes > UInt64(Int64.max)
            ? [ArchiveIssue("所选内容", "文件总逻辑大小超过支持范围", suggestion: "请分批打包。")]
            : [])
    }
}

public enum SourceScanner {
    public static func scan(_ input: [URL], context: JobContext = JobContext(),
                            reportProgress: Bool = true, excluding: [URL] = [],
                            enclosingFolderName: String? = nil) throws -> SourcePlan {
        if reportProgress { context.report(.scanning, detail: "读取全部所选内容，保留原名和原始内容…", force: true) }
        var unique: [URL] = []
        for url in input.map({ $0.standardizedFileURL }).sorted(by: { $0.path < $1.path }) {
            if !unique.contains(where: {
                $0 == url || (PathRules.contains(url, in: $0) && (try? FileFingerprint.read($0).kind) == .directory)
            }) { unique.append(url) }
        }
        guard let first = unique.first else { throw CrossZipError.message("请先添加文件或文件夹。") }
        let omitted = excluding.map(\.standardizedFileURL)
        let restored = input.map(\.standardizedFileURL).filter { candidate in
            omitted.contains { $0 != candidate && PathRules.contains(candidate, in: $0) }
        }
        func isIncluded(_ url: URL) -> Bool {
            let omission = omitted.filter { PathRules.contains(url, in: $0) }.map { $0.pathComponents.count }.max() ?? -1
            let restoration = restored.filter { PathRules.contains(url, in: $0) }.map { $0.pathComponents.count }.max() ?? -1
            return omission < 0 || restoration > omission
        }
        // Different locations retain their actual relative parent paths. Two real
        // readme.txt files then need neither renaming nor duplicate ZIP entries.
        var base = first.deletingLastPathComponent()
        while !unique.allSatisfy({ PathRules.contains($0, in: base) }) {
            let parent = base.deletingLastPathComponent()
            guard parent != base else { break }
            base = parent
        }
        var items: [SourceItem] = []
        var issues: [ArchiveIssue] = []

        func walk(_ url: URL, path: String) throws {
            try context.checkCancellation()
            if !isIncluded(url) && !restored.contains(where: { PathRules.contains($0, in: url) }) { return }
            if reportProgress { context.report(.scanning, path: path, detail: "已扫描 \(items.count) 项") }
            let fingerprint = try FileFingerprint.read(url)
            guard let kind = fingerprint.kind else {
                issues.append(ArchiveIssue(path, "这是管道、套接字或设备等特殊对象，没有可作为普通文件读取的固定内容",
                                           suggestion: "请先由创建它的程序导出为普通文件；不会跳过此项后报告成功。"))
                return
            }
            guard fingerprint.size >= 0 else { throw CrossZipError.message("文件大小无效：\(path)") }
            var target: Data?
            if kind == .file {
                let handle = try FileSupport.openRegularFile(url, expected: fingerprint)
                try handle.close()
            } else if kind == .symlink {
                target = try FileSupport.readLink(url, expected: fingerprint)
            }
            items.append(SourceItem(url: url, path: path, kind: kind, fingerprint: fingerprint, linkTarget: target))
            if kind == .directory {
                for child in try FileSupport.children(of: url) {
                    try visit(child, path: path + "/" + child.lastPathComponent)
                }
            }
        }

        func visit(_ url: URL, path: String) throws {
            do { try walk(url, path: path) }
            catch CrossZipError.cancelled { throw CrossZipError.cancelled }
            catch { issues.append(ArchiveIssue(path, "读取失败：\(error.localizedDescription)", suggestion: "检查文件是否存在、是否有读取权限。")) }
        }
        for url in unique {
            try visit(url, path: url.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/"))
        }
        if unique.contains(where: { $0.deletingLastPathComponent() != base }) {
            issues.append(ArchiveIssue("多位置选择", "按共同父目录保留原始相对路径，避免同名文件互相覆盖",
                                       suggestion: "预览中的父目录均来自原有路径；文件和目录没有改名。", severity: .warning))
        }
        if items.contains(where: { $0.kind == .symlink }) {
            issues.append(ArchiveIssue("符号链接", "按链接本身及其原始目标路径保存，不转换成目标文件",
                                       suggestion: "Windows 自带解压程序可能无法还原符号链接；失效链接和循环链接也按原样保留。", severity: .warning))
        }
        if let root = enclosingFolderName {
            items = items.map { SourceItem(url: $0.url, path: root + "/" + $0.path, kind: $0.kind,
                                           fingerprint: $0.fingerprint, linkTarget: $0.linkTarget) }
        }
        issues += PathRules.validateTree((enclosingFolderName.map { [($0, ItemKind.directory)] } ?? []) + items.map { ($0.path, $0.kind) })
        if items.isEmpty { issues.append(ArchiveIssue("所选内容", "没有可读取的文件或文件夹")) }
        return SourcePlan(sources: unique + restored.filter { !unique.contains($0) },
                          items: items.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) },
                          excluded: [], issues: issues, enclosingFolderName: enclosingFolderName, rootCount: unique.count)
    }
}
