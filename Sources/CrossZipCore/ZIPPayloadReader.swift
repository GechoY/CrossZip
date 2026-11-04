import Foundation
import zlib

/// The pinned engine writes ZIPs; validated index offsets plus system zlib read payloads.
/// This also handles legal ZIP64 zero-size/zero-offset fields that ZIPFoundation 0.9.20
/// interprets as missing. Compressed bytes are never read beyond the indexed member range.
enum ZIPPayloadReader {
    static func read(_ member: ZIPMember, from handle: FileHandle, context: JobContext,
                     onProgress: (UInt64) -> Void = { _ in }, consumer: (Data) throws -> Void) throws -> UInt32 {
        try handle.seek(toOffset: member.dataOffset)
        var remaining = member.compressedSize
        var produced: UInt64 = 0
        var checksum: UInt32 = 0
        func consume(_ data: Data) throws {
            try context.checkCancellation()
            guard produced <= member.size, UInt64(data.count) <= member.size - produced else {
                throw CrossZipError.message("实际解压大小超过目录声明：\(member.path)")
            }
            produced += UInt64(data.count)
            checksum = FileSupport.crc(data, seed: checksum)
            try consumer(data)
            onProgress(produced)
        }
        func nextInput() throws -> Data {
            try context.checkCancellation()
            let count = Int(min(64 * 1024, remaining))
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw CrossZipError.message("ZIP 内容读取不完整：\(member.path)") }
            remaining -= UInt64(count)
            return data
        }
        switch member.method {
        case 0:
            guard member.compressedSize == member.size else { throw CrossZipError.message("Stored 条目的两种大小不一致：\(member.path)") }
            while remaining > 0 { try consume(nextInput()) }
        case 8:
            var stream = z_stream()
            let initialized = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initialized == Z_OK else { throw CrossZipError.message("无法初始化 ZIP 解压引擎。") }
            defer { inflateEnd(&stream) }
            var output = [UInt8](repeating: 0, count: 64 * 1024)
            var ended = false
            while remaining > 0 && !ended {
                let input = try nextInput()
                try input.withUnsafeBytes { rawInput in
                    stream.next_in = UnsafeMutablePointer(mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    while true {
                        try context.checkCancellation()
                        let previousInput = stream.avail_in
                        let previousProduced = produced
                        let code: Int32 = try output.withUnsafeMutableBytes { rawOutput in
                            stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
                            stream.avail_out = uInt(rawOutput.count)
                            let code = inflate(&stream, Z_NO_FLUSH)
                            let count = rawOutput.count - Int(stream.avail_out)
                            if count > 0 { try consume(Data(rawOutput.prefix(count))) }
                            return code
                        }
                        if code == Z_STREAM_END {
                            guard stream.avail_in == 0, remaining == 0 else { throw CrossZipError.message("Deflate 数据后存在额外字节：\(member.path)") }
                            ended = true
                            break
                        }
                        if code == Z_BUF_ERROR && stream.avail_in == 0 { break }
                        guard code == Z_OK else { throw CrossZipError.message("Deflate 数据损坏：\(member.path)") }
                        if stream.avail_in == 0 && stream.avail_out > 0 { break }
                        guard stream.avail_in != previousInput || produced != previousProduced else {
                            throw CrossZipError.message("Deflate 数据无法继续解码：\(member.path)")
                        }
                    }
                }
            }
            guard ended else { throw CrossZipError.message("Deflate 数据被截断：\(member.path)") }
        default: throw CrossZipError.message("不支持的 ZIP 压缩方法：\(member.method)")
        }
        guard produced == member.size, checksum == member.checksum else {
            throw CrossZipError.message("文件大小或 CRC 校验失败：\(member.path)")
        }
        return checksum
    }
}
