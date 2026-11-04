import Foundation
import zlib

/// Libarchive 3.8.11 consumes GZIP trailers without checking CRC/ISIZE.
/// zlib's GZIP wrapper validates both, including concatenated GZIP members.
enum GzipValidator {
    static func read(_ url: URL, fingerprint: FileFingerprint, context: JobContext,
                     consume: (Data) throws -> Void = { _ in }) throws {
        let file = try FileSupport.openRegularFile(url, expected: fingerprint)
        defer { try? file.close() }
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CrossZipError.message("无法初始化 GZIP 校验器。")
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 64 * 1024)
        var ended = false
        var members = 0
        var padding = false
        while let input = try file.read(upToCount: 64 * 1024), !input.isEmpty {
            try context.checkCancellation()
            try input.withUnsafeBytes { raw in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                while stream.avail_in > 0 || !ended {
                    try context.checkCancellation()
                    if ended {
                        // gzip tools commonly append zero padding. It is allowed
                        // only after the final member, never before another header.
                        while stream.avail_in > 0 && stream.next_in.pointee == 0 {
                            padding = true; stream.next_in += 1; stream.avail_in -= 1
                        }
                        if stream.avail_in == 0 { break }
                        guard !padding, inflateReset2(&stream, MAX_WBITS + 16) == Z_OK else {
                            throw CrossZipError.message("GZIP 结束记录之后存在非预期数据。")
                        }
                        ended = false
                    }
                    let previous = stream.avail_in
                    var produced = 0
                    let code = try output.withUnsafeMutableBytes { bytes -> Int32 in
                        stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(bytes.count)
                        let status = inflate(&stream, Z_NO_FLUSH)
                        produced = bytes.count - Int(stream.avail_out)
                        if produced > 0 { try consume(Data(bytes.prefix(produced))) }
                        return status
                    }
                    if code == Z_STREAM_END { ended = true; members += 1; continue }
                    guard code == Z_OK || (code == Z_BUF_ERROR && stream.avail_in == 0) else {
                        throw CrossZipError.message("GZIP 数据、CRC 或原始大小校验失败。")
                    }
                    if stream.avail_in == 0 && stream.avail_out > 0 { break }
                    guard stream.avail_in != previous || produced > 0 else { throw CrossZipError.message("GZIP 数据无法继续解码。") }
                }
            }
        }
        guard ended && members > 0 else { throw CrossZipError.message("GZIP 数据流被截断，缺少完整结束记录。") }
    }
}
