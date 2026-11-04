import Foundation
import CoreFoundation

public struct ArchiveIssue: Identifiable, Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning }
    public let path: String
    public let reason: String
    public let suggestion: String
    public let severity: Severity
    public var id: String { path + "\u{0}" + reason }

    public init(_ path: String, _ reason: String, suggestion: String = "", severity: Severity = .error) {
        self.path = path
        self.reason = reason
        self.suggestion = suggestion
        self.severity = severity
    }
}

public enum CrossZipError: LocalizedError {
    case message(String)
    case issues([ArchiveIssue])
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .issues(let issues):
            return issues.prefix(8).map { "\($0.path)：\($0.reason)" }.joined(separator: "\n")
        case .cancelled: return "任务已取消，临时内容已清理。"
        }
    }
}

public enum FilenameEncoding: String, CaseIterable, Identifiable, Sendable {
    case automatic, utf8, gb18030, cp437
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "自动（遵循 ZIP 声明）"
        case .utf8: return "UTF-8"
        case .gb18030: return "GB18030 / GBK"
        case .cp437: return "CP437"
        }
    }
    var stringEncoding: String.Encoding {
        switch self {
        case .automatic, .cp437:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        case .utf8: return .utf8
        case .gb18030:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
    }
}

public enum JobPhase: String, Sendable {
    case scanning = "扫描"
    case compressing = "压缩"
    case extracting = "解压"
    case verifying = "校验"
    case finished = "完成"
}

public struct JobUpdate: Sendable {
    public let phase: JobPhase
    public let path: String
    public let fraction: Double?
    public let detail: String
}

/// Each task owns one context; streaming operations check cancellation between blocks.
public final class JobContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastEmission: TimeInterval = 0
    private let callback: @Sendable (JobUpdate) -> Void

    public init(onUpdate: @escaping @Sendable (JobUpdate) -> Void = { _ in }) {
        callback = onUpdate
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func checkCancellation() throws {
        lock.lock()
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { throw CrossZipError.cancelled }
    }

    public func report(_ phase: JobPhase, path: String = "", fraction: Double? = nil,
                       detail: String = "", force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let emit = force || now - lastEmission >= 0.08
        if emit { lastEmission = now }
        lock.unlock()
        if emit {
            callback(JobUpdate(phase: phase, path: path,
                               fraction: fraction.map { $0.isFinite ? min(1, max(0, $0)) : 0 }, detail: detail))
        }
    }


}

public enum ItemKind: String, Sendable { case file, directory, symlink }

public struct OperationResult: Sendable {
    public let url: URL
    public let fileCount: Int
    public let directoryCount: Int
    public let totalBytes: UInt64
    public let excludedCount: Int
}
