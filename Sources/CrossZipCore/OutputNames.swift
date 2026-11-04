import Foundation

public enum OutputNames {
    public static func availableArchiveURL(for stem: String, format: ArchiveFormat, in directory: URL) -> URL {
        var number = 1
        while true {
            let suffix = (number == 1 ? "" : " (\(number))") + "." + format.rawValue
            let candidate = directory.appendingPathComponent(fit(stem.isEmpty ? "归档" : stem, suffix: suffix, limit: 255))
            if (try? FileFingerprint.read(candidate)) == nil { return candidate }
            number += 1
        }
    }

    public static func archiveName(for sourceName: String, format: ArchiveFormat = .zip) -> String {
        fit(sourceName.isEmpty ? "归档" : sourceName, suffix: "." + format.rawValue, limit: 255)
    }

    static func extractionName(for stem: String, number: Int) -> String {
        let base = stem.isEmpty || stem == "." || stem == ".." ? "解压文件" : stem
        return fit(base, suffix: number == 1 ? "" : " (\(number))", limit: 255)
    }

    private static func fit(_ base: String, suffix: String, limit: Int) -> String {
        var prefix = base
        while !prefix.isEmpty && prefix.utf16.count + suffix.utf16.count > limit { prefix.removeLast() }
        return (prefix.isEmpty ? "归档" : prefix) + suffix
    }
}
