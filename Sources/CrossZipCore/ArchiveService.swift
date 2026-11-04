import Foundation
import Darwin

public struct ArchiveService {
    private let availableSpace: (URL) throws -> UInt64
    private let chunkSize = 64 * 1024

    public init() { availableSpace = FileSupport.availableBytes }
    // Used by tests to exercise insufficient-space failures without filling a real disk.
    init(availableSpace: @escaping (URL) throws -> UInt64) { self.availableSpace = availableSpace }

    public func compress(_ sources: [URL], to destination: URL,
                         storeOnly: Bool = false, level: CompressionLevel = .maximum,
                         excluding: [URL] = [], enclosingFolderName: String? = nil,
                         context: JobContext = JobContext()) throws -> OperationResult {
        try NativeArchive.compress(sources, to: destination, format: .zip, level: level, storeOnly: storeOnly,
                                   excluding: excluding, enclosingFolderName: enclosingFolderName,
                                   context: context, availableSpace: availableSpace)
    }

    public func extract(_ inspection: ZIPInspection, to parent: URL,
                        context: JobContext = JobContext()) throws -> OperationResult {
        guard inspection.canProceed else { throw CrossZipError.issues(inspection.issues) }
        try context.checkCancellation()
        guard inspection.fingerprint.matches(try FileFingerprint.read(inspection.url)) else {
            throw CrossZipError.message("压缩包在预览后发生变化，请重新预览。")
        }
        let parent = parent.standardizedFileURL
        try checkParent(parent)
        let caseSensitive = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? false
        let conflicts = PathRules.extractionConflicts(inspection.members.map { ($0.path, $0.kind) }, caseSensitive: caseSensitive)
        guard conflicts.isEmpty else { throw CrossZipError.message(conflicts.map { "\($0.path)：\($0.reason)" }.joined(separator: "\n") + "\n请选择能保留这些名称的目标磁盘。") }
        try FileSupport.requireSpace(inspection.totalBytes, at: parent, availableOverride: availableSpace(parent))
        let temporary = try makeWorkDirectory(in: parent)
        defer { try? FileManager.default.removeItem(at: temporary) }
        context.report(.extracting, fraction: 0, detail: "解压到临时目录…", force: true)
        try streamAll(inspection, context: context, phase: .extracting, output: temporary)
        context.report(.verifying, fraction: 0, detail: "复核已写入文件的大小和 CRC…", force: true)
        try verifyOutput(inspection, in: temporary, context: context)
        guard inspection.fingerprint.matches(try FileFingerprint.read(inspection.url)) else {
            throw CrossZipError.message("压缩包在解压过程中发生变化。")
        }
        try context.checkCancellation()
        let basename = inspection.url.deletingPathExtension().lastPathComponent
        var number = 1
        var destination: URL
        while true {
            try context.checkCancellation()
            destination = parent.appendingPathComponent(OutputNames.extractionName(for: basename, number: number), isDirectory: true)
            if try FileSupport.publishIfAbsent(temporary, to: destination) { break }
            number += 1
        }
        context.report(.finished, path: destination.path, fraction: 1, detail: "全部文件已通过校验", force: true)
        return OperationResult(url: destination, fileCount: inspection.fileCount, directoryCount: inspection.directoryCount,
                               totalBytes: inspection.totalBytes, excludedCount: inspection.excludedCount)
    }

    public func verify(_ archiveURL: URL, encoding: FilenameEncoding = .automatic,
                       context: JobContext = JobContext()) throws -> ZIPInspection {
        let inspection = try ZIPInspector.inspect(archiveURL, encoding: encoding, context: context, phase: .verifying)
        return try verify(inspection, context: context)
    }

    func verify(_ inspection: ZIPInspection, context: JobContext) throws -> ZIPInspection {
        guard inspection.canProceed else { throw CrossZipError.issues(inspection.issues) }
        try streamAll(inspection, context: context, phase: .verifying, output: nil)
        guard inspection.fingerprint.matches(try FileFingerprint.read(inspection.url)) else {
            throw CrossZipError.message("压缩包在校验过程中发生变化。")
        }
        context.report(.finished, fraction: 1, detail: "目录、大小和 CRC 校验通过", force: true)
        return inspection
    }

    private func streamAll(_ inspection: ZIPInspection, context: JobContext, phase: JobPhase, output: URL?) throws {
        let archive = try FileSupport.openRegularFile(inspection.url, expected: inspection.fingerprint)
        defer { try? archive.close() }
        let totalUnits = inspection.records.reduce(0.0) { $0 + Double(max(1, $1.size)) }
        var completed = 0.0
        var directoryDates: [(URL, Date)] = []
        var pendingLinks: [(URL, Data)] = []
        for record in inspection.records {
            try context.checkCancellation()
            let target = output.flatMap { record.isExcluded ? nil : $0.appendingPathComponent(record.path, isDirectory: record.kind == .directory) }
            if let target, let output, !PathRules.contains(target, in: output) {
                throw CrossZipError.message("ZIP 条目超出解压目录：\(record.path)")
            }
            if let target {
                try FileManager.default.createDirectory(at: record.kind == .directory ? target : target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            var handle: FileHandle?
            var linkTarget = Data()
            if target != nil && record.kind == .symlink && record.size >= UInt64(PATH_MAX) {
                throw CrossZipError.message("链接目标超过当前系统可保存的长度：\(record.path)")
            }
            if let target, record.kind == .file {
                let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            }
            do {
                defer { try? handle?.close() }
                let units = Double(max(1, record.size))
                _ = try ZIPPayloadReader.read(record, from: archive, context: context, onProgress: { bytes in
                    context.report(phase, path: record.path,
                                   fraction: totalUnits > 0 ? (completed + Double(bytes)) / totalUnits : 1)
                }, consumer: { data in
                    if target != nil && record.kind == .symlink { linkTarget.append(data) }
                    else { try handle?.write(contentsOf: data) }
                })
                try handle?.synchronize()
                completed += units
            }
            if let target, record.kind == .symlink {
                guard !linkTarget.isEmpty, !linkTarget.contains(0) else {
                    throw CrossZipError.message("符号链接的目标路径无效，无法按原样还原：\(record.path)")
                }
                pendingLinks.append((target, linkTarget))
            } else if let target, let date = record.modified {
                if record.kind == .directory { directoryDates.append((target, date)) }
                else { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path) }
            }
        }
        for (url, date) in directoryDates.reversed() {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        // Create links only after all ordinary writes. No entry can write through
        // an archive-provided link, even when its original target is outside output.
        for (url, target) in pendingLinks {
            try context.checkCancellation()
            let result = (target + Data([0])).withUnsafeBytes { bytes in
                symlink(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), url.path)
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private func verifyOutput(_ inspection: ZIPInspection, in output: URL, context: JobContext) throws {
        let total = max(1, inspection.totalBytes)
        var completed: UInt64 = 0
        for member in inspection.members {
            try context.checkCancellation()
            let url = output.appendingPathComponent(member.path)
            let fingerprint = try FileFingerprint.read(url)
            guard fingerprint.kind == member.kind else { throw CrossZipError.message("输出文件类型不一致：\(member.path)") }
            if member.kind == .symlink {
                let target = try FileSupport.readLink(url, expected: fingerprint)
                guard target.count == member.size, FileSupport.crc(target) == member.checksum else {
                    throw CrossZipError.message("输出链接内容不一致：\(member.path)")
                }
                completed += member.size
            } else if member.kind == .file {
                guard UInt64(fingerprint.size) == member.size else { throw CrossZipError.message("输出文件大小不一致：\(member.path)") }
                let handle = try FileSupport.openRegularFile(url, expected: fingerprint)
                defer { try? handle.close() }
                var crc: UInt32 = 0
                var count: UInt64 = 0
                while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                    try context.checkCancellation()
                    guard UInt64(chunk.count) <= member.size - count else { throw CrossZipError.message("输出文件在校验时发生变化。") }
                    count += UInt64(chunk.count)
                    crc = FileSupport.crc(chunk, seed: crc)
                    context.report(.verifying, path: member.path, fraction: Double(completed + count) / Double(total))
                }
                guard count == member.size, crc == member.checksum else { throw CrossZipError.message("输出文件 CRC 不一致：\(member.path)") }
                completed += count
            }
        }
    }

    private func checkParent(_ parent: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
            throw CrossZipError.message("目标文件夹不存在，请重新选择。")
        }
    }

    private func makeWorkDirectory(in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(".crosszip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
}
