import Foundation
import Darwin
import zlib

struct FileFingerprint: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }

    static func read(_ url: URL) throws -> FileFingerprint {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileFingerprint(value)
    }

    var kind: ItemKind? {
        switch mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return nil
        }
    }
    func matches(_ other: FileFingerprint) -> Bool {
        if kind == .directory {
            return device == other.device && inode == other.inode && mode == other.mode
        }
        return self == other
    }
}

enum FileSupport {
    static func readLink(_ url: URL, expected: FileFingerprint) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max(Int(expected.size) + 1, Int(PATH_MAX)))
        let count = buffer.withUnsafeMutableBytes { readlink(url.path, $0.baseAddress!, $0.count) }
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard count == expected.size, count < buffer.count, expected.matches(try FileFingerprint.read(url)) else {
            throw CrossZipError.message("符号链接在读取时发生变化：\(url.lastPathComponent)")
        }
        return Data(buffer.prefix(count))
    }

    /// Foundation's directory enumeration hides all ._ names on macOS, including real files.
    static func children(of url: URL) throws -> [URL] {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw CrossZipError.message("目录包含无法按 UTF-8 读取的文件名：\(url.path)") }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted().map { url.appendingPathComponent($0) }
    }

    static func openRegularFile(_ url: URL, expected: FileFingerprint? = nil) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { try? handle.close(); throw CrossZipError.message("无法读取文件状态：\(url.path)") }
        let fingerprint = FileFingerprint(value)
        guard fingerprint.kind == .file else {
            try? handle.close(); throw CrossZipError.message("不是普通文件，或文件类型已改变：\(url.path)")
        }
        if let expected, !expected.matches(fingerprint) {
            try? handle.close(); throw CrossZipError.message("文件在扫描后发生变化：\(url.path)")
        }
        return handle
    }

    static func availableBytes(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let bytes = attributes[.systemFreeSize] as? NSNumber else {
            throw CrossZipError.message("无法检查目标磁盘剩余空间。")
        }
        return bytes.uint64Value
    }

    static func requireSpace(_ bytes: UInt64, at url: URL, availableOverride: UInt64? = nil) throws {
        let available = try availableOverride ?? availableBytes(at: url)
        let margin: UInt64 = 16 * 1024 * 1024
        guard bytes <= available, available - bytes >= margin else {
            throw CrossZipError.message("目标磁盘空间不足。需要约 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))，并预留 16 MB。")
        }
    }

    static func publishIfAbsent(_ temporary: URL, to destination: URL) throws -> Bool {
        // RENAME_EXCL prevents a last-moment overwrite, including on case-insensitive volumes.
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    static func crc(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(truncatingIfNeeded: zlib.crc32(uLong(seed), buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
    }

}
