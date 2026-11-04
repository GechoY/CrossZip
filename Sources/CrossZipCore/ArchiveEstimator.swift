import Foundation

public struct ArchiveSizeEstimate: Sendable {
    public let bytes: UInt64
    public let sampledBytes: UInt64
    public let isSampled: Bool
    public let sampledFileCount: Int
    public let totalFileCount: Int
    public let sourceFileBytes: UInt64
}

/// Measures the actual selected codec. Small selections are fully trial-compressed;
/// large selections use bounded, size-weighted samples plus the real metadata size.
public enum ArchiveEstimator {
    public static let sampleLimit = 8 * 1024 * 1024

    public static func estimate(_ plan: SourcePlan, format: ArchiveFormat, level: CompressionLevel = .maximum,
                                storeOnly: Bool = false, enclosingFolderName: String? = nil,
                                context: JobContext = JobContext()) throws -> ArchiveSizeEstimate {
        guard plan.canProceed else { throw CrossZipError.issues(plan.issues) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("CrossZip-Estimate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let empty = work.appendingPathComponent("empty")
        try Data().write(to: empty)
        let directory = work.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let emptyFingerprint = try FileFingerprint.read(empty), directoryFingerprint = try FileFingerprint.read(directory)
        let root = enclosingFolderName ?? plan.enclosingFolderName
        func path(_ item: SourceItem) -> String {
            if plan.enclosingFolderName == nil, let root { return root + "/" + item.path }
            return item.path
        }
        func metadata(_ item: SourceItem) -> SourceItem {
            switch item.kind {
            case .file: return SourceItem(url: empty, path: path(item), kind: .file, fingerprint: emptyFingerprint)
            case .directory: return SourceItem(url: directory, path: path(item), kind: .directory, fingerprint: directoryFingerprint)
            case .symlink: return SourceItem(url: item.url, path: path(item), kind: .symlink,
                                             fingerprint: item.fingerprint, linkTarget: item.linkTarget)
            }
        }
        var trial = 0
        func measure(_ items: [SourceItem]) throws -> UInt64 {
            try context.checkCancellation()
            trial += 1
            let samplePlan = SourcePlan(sources: [work], items: items, excluded: [], issues: [], enclosingFolderName: root)
            return try NativeArchive.measuredSize(samplePlan, to: work.appendingPathComponent("trial-\(trial)." + format.rawValue),
                                                   format: format, level: level, storeOnly: storeOnly, context: context)
        }
        let files = plan.items.filter { $0.kind == .file }
        let fileBytes = files.reduce(UInt64(0)) { $0 + $1.size }
        let complete = fileBytes <= UInt64(sampleLimit) && plan.items.count <= 256
        var selected: [SourceItem]
        if complete { selected = files }
        else {
            // Largest representatives of each extension, then the largest remaining
            // files. Allocate samples by byte weight instead of counting files equally.
            let ordered = files.sorted { $0.size > $1.size }
            var extensions: Set<String> = []
            selected = Array(ordered.filter { extensions.insert(($0.path as NSString).pathExtension.lowercased()).inserted }.prefix(16))
            for item in ordered where selected.count < 24 && !selected.contains(where: { $0.url == item.url }) { selected.append(item) }
            selected.sort { $0.size < $1.size }
        }
        let selectedBytes = selected.reduce(UInt64(0)) { $0 + $1.size }
        var remaining = sampleLimit
        var sampled: [SourceItem] = []
        var sampledBytes: UInt64 = 0
        for (number, item) in selected.enumerated() {
            try context.checkCancellation()
            let desired = complete ? Int(item.size) : min(remaining, max(16 * 1024,
                Int(Double(sampleLimit) * Double(item.size) / Double(max(1, selectedBytes)))))
            let count = min(desired, Int(min(item.size, UInt64(sampleLimit))))
            if count == 0 && item.size > 0 { continue }
            let output = work.appendingPathComponent("sample-\(number)")
            try Data().write(to: output)
            let target = try FileHandle(forWritingTo: output)
            defer { try? target.close() }
            let source = try FileSupport.openRegularFile(item.url, expected: item.fingerprint)
            defer { try? source.close() }
            // First, middle and last segments retain coverage of large mixed files.
            let parts = item.size > UInt64(count) ? 3 : 1
            var copied = 0
            for part in 0..<parts {
                let length = part == parts - 1 ? count - copied : count / parts
                let offset = parts == 1 ? 0 : (item.size - UInt64(length)) * UInt64(part) / UInt64(parts - 1)
                try source.seek(toOffset: offset)
                var needed = length
                while needed > 0 {
                    try context.checkCancellation()
                    let data = try source.read(upToCount: min(64 * 1024, needed)) ?? Data()
                    guard !data.isEmpty else { throw CrossZipError.message("估算时源文件已改变。") }
                    try target.write(contentsOf: data)
                    needed -= data.count; copied += data.count
                }
            }
            try target.close()
            guard item.fingerprint.matches(try FileFingerprint.read(item.url)) else { throw CrossZipError.message("估算时源文件已改变。") }
            sampled.append(SourceItem(url: output, path: path(item), kind: .file, fingerprint: try FileFingerprint.read(output)))
            sampledBytes += UInt64(count); remaining -= count
        }
        func result(_ bytes: UInt64, isSampled: Bool) -> ArchiveSizeEstimate {
            ArchiveSizeEstimate(bytes: bytes, sampledBytes: sampledBytes, isSampled: isSampled,
                                sampledFileCount: sampled.count, totalFileCount: files.count, sourceFileBytes: fileBytes)
        }
        if complete {
            let byPath = Dictionary(uniqueKeysWithValues: sampled.map { (Data($0.path.utf8), $0) })
            let items = plan.items.map { byPath[Data(path($0).utf8)] ?? metadata($0) }
            return result(try measure(items), isSampled: false)
        }
        let overhead = try measure(plan.items.map(metadata))
        guard sampledBytes > 0 else { return result(overhead, isSampled: false) }
        let sampleSize = try measure(sampled)
        let emptySamples = sampled.map { SourceItem(url: empty, path: $0.path, kind: .file, fingerprint: emptyFingerprint) }
        let sampleOverhead = try measure(emptySamples)
        let payload = Double(sampleSize > sampleOverhead ? sampleSize - sampleOverhead : 0)
        let projected = Double(overhead) + payload * Double(fileBytes) / Double(sampledBytes)
        return result(UInt64(min(projected.rounded(), Double(Int64.max))), isSampled: true)
    }
}
