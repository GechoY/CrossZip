import Foundation

public enum PathRules {
    static let windowsBase = "C:\\Extract\\"

    static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    static func issues(for path: String, kind: ItemKind = .file) -> [ArchiveIssue] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if path.isEmpty || path.hasPrefix("/") || path.utf8.contains(0) ||
            parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return [ArchiveIssue(path, "包含绝对路径、空路径段或越界路径", suggestion: "无法安全地在目标目录内还原此路径。")]
        }
        var issues: [ArchiveIssue] = []
        func warn(_ reason: String) {
            issues.append(ArchiveIssue(path, reason, suggestion: "按原名保存，不影响打包；Windows 自带解压可能无法还原此名称。", severity: .warning))
        }
        for part in parts {
            if part.unicodeScalars.contains(where: { $0.value < 32 || "<>:\"\\|?*".unicodeScalars.contains($0) }) {
                warn("名称「\(part)」包含 Windows 不接受的字符")
            }
            if part.hasSuffix(" ") || part.hasSuffix(".") { warn("名称「\(part)」以空格或句点结尾") }
            let stem = part.components(separatedBy: ".")[0].trimmingCharacters(in: .whitespaces).uppercased()
            let devices: Set<String> = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
            let portSuffixes: Set<String> = Set((1...9).map(String.init) + ["¹", "²", "³"])
            let isPort = (stem.hasPrefix("COM") || stem.hasPrefix("LPT")) && portSuffixes.contains(String(stem.dropFirst(3)))
            if devices.contains(stem) || isPort { warn("名称「\(part)」是 Windows 保留名称") }
            if part.utf16.count > 255 { warn("单个名称超过常见 Windows 文件系统长度限制") }
        }
        if windowsBase.utf16.count + path.utf16.count + 1 > 260 - (kind == .directory ? 12 : 0) {
            issues.append(ArchiveIssue(path, "按 C:\\Extract\\ 解压时超过传统 Windows 路径预算",
                                       suggestion: "保留全部层级继续打包；接收端需支持长路径的解压程序或更短的目标位置。", severity: .warning))
        }
        return issues
    }

    public static func validateTree(_ items: [(path: String, kind: ItemKind)]) -> [ArchiveIssue] {
        struct Node { let spelling: String; let kind: ItemKind; var explicit: Bool }
        var exact: [Data: Node] = [:]
        var portable: [String: String] = [:]
        var issues: [ArchiveIssue] = []
        var reportedErrors: Set<Data> = []
        var reportedWarnings: Set<Data> = []
        for item in items {
            issues += Self.issues(for: item.path, kind: item.kind)
            let parts = item.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            for index in parts.indices {
                let spelling = parts[...index].joined(separator: "/")
                let bytes = Data(spelling.utf8)
                let isLeaf = index == parts.count - 1
                let kind: ItemKind = isLeaf ? item.kind : .directory
                if var node = exact[bytes] {
                    if node.kind != kind || (isLeaf && node.explicit) {
                        if reportedErrors.insert(bytes).inserted {
                            issues.append(ArchiveIssue(item.path, "与「\(node.spelling)」存在重复条目或文件/目录冲突",
                                                       suggestion: "不能在同一路径无损还原多个对象。"))
                        }
                    }
                    if isLeaf { node.explicit = true; exact[bytes] = node }
                } else { exact[bytes] = Node(spelling: spelling, kind: kind, explicit: isLeaf) }
                let key = Self.key(spelling)
                if let other = portable[key], !other.utf8.elementsEqual(spelling.utf8) {
                    if reportedWarnings.insert(bytes).inserted {
                        issues.append(ArchiveIssue(item.path, "与「\(other)」仅大小写或 Unicode 形式不同",
                                                   suggestion: "原名全部保留；不区分这些名称的目标磁盘无法同时还原它们。", severity: .warning))
                    }
                } else { portable[key] = spelling }
            }
        }
        return issues
    }

    /// Reject extraction onto a volume that cannot distinguish names before any
    /// directories can silently merge. The ZIP itself still keeps both names.
    static func extractionConflicts(_ items: [(path: String, kind: ItemKind)], caseSensitive: Bool) -> [ArchiveIssue] {
        var nodes: [String: String] = [:]
        var issues: [ArchiveIssue] = []
        var reported: Set<String> = []
        for item in items {
            let parts = item.path.split(separator: "/").map(String.init)
            for index in parts.indices {
                let spelling = parts[...index].joined(separator: "/")
                let key = caseSensitive ? spelling.precomposedStringWithCanonicalMapping : Self.key(spelling)
                if let other = nodes[key], !other.utf8.elementsEqual(spelling.utf8), reported.insert(key).inserted {
                    issues.append(ArchiveIssue(spelling, "目标磁盘无法区分此名称和「\(other)」",
                                               suggestion: "请选择能同时保留这些名称的磁盘；软件不会改名、合并或覆盖。"))
                } else { nodes[key] = spelling }
            }
        }
        return issues
    }

    public static func contains(_ child: URL, in parent: URL) -> Bool {
        let a = child.standardizedFileURL.path
        let b = parent.standardizedFileURL.path
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }
}
