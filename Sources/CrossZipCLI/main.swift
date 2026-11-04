import Foundation
import Darwin
import CrossZipCore

func emitJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func issueJSON(_ issue: ArchiveIssue) -> [String: Any] {
    ["path": issue.path, "reason": issue.reason, "suggestion": issue.suggestion, "severity": issue.severity.rawValue]
}

func inspectionJSON(_ inspection: ArchiveInspection) -> [String: Any] {
    ["archive": inspection.url.path, "canProceed": inspection.canProceed,
     "encoding": inspection.encoding.rawValue, "zip64": inspection.isZIP64, "format": inspection.formatName,
     "fileCount": inspection.fileCount, "directoryCount": inspection.directoryCount,
     "totalBytes": inspection.totalBytes, "excludedCount": inspection.excludedCount,
     "issues": inspection.issues.map(issueJSON),
     "members": inspection.records.map { ["path": $0.path, "kind": $0.kind.rawValue, "size": $0.size,
                                            "crc32": $0.checksum, "excluded": $0.isExcluded] as [String: Any] }]
}

func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else {
        print("""
        CrossZip 开发/验收工具
          crosszip-cli pack --output archive.zip [--format zip|7z|tar|tar.gz|tar.bz2|tar.xz] [--level 1|6|9] [--store] [--root 外层目录] [--exclude 原文件路径]... <文件或文件夹>...
          crosszip-cli scan <文件或文件夹>...
          crosszip-cli inspect archive.zip [--encoding automatic|utf8|gb18030|cp437]
          crosszip-cli extract archive --to <目标文件夹> [--include 包内路径]... [--encoding ...]
          crosszip-cli verify archive.zip [--encoding ...]
        添加 --quiet 可隐藏进度。输出为 JSON；Windows 实机验收状态见 README。
        """)
        return
    }
    let command = arguments.removeFirst()
    func option(_ name: String) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard index + 1 < arguments.count else { throw CrossZipError.message("\(name) 缺少参数。") }
        let value = arguments.remove(at: index + 1)
        arguments.remove(at: index)
        return value
    }
    let quiet = arguments.contains("--quiet")
    arguments.removeAll { $0 == "--quiet" }
    let encodingValue = try option("--encoding") ?? "automatic"
    guard let encoding = FilenameEncoding(rawValue: encodingValue) else { throw CrossZipError.message("未知编码：\(encodingValue)") }
    let output = try option("--output")
    let target = try option("--to")
    let formatValue = try option("--format")
    let levelValue = try option("--level") ?? "9"
    let enclosingFolder = try option("--root")
    var excluded: [URL] = []
    while let path = try option("--exclude") { excluded.append(URL(fileURLWithPath: path)) }
    guard let levelNumber = Int(levelValue), let level = CompressionLevel(rawValue: levelNumber) else {
        throw CrossZipError.message("压缩等级可选 1（快速）、6（标准）或 9（体积优先，比较三个等级）。")
    }
    let storeOnly = arguments.contains("--store")
    arguments.removeAll { $0 == "--store" }
    var included: [String] = []
    while let path = try option("--include") { included.append(path.hasSuffix("/") ? String(path.dropLast()) : path) }
    if !included.isEmpty && command != "extract" { throw CrossZipError.message("--include 仅用于解压。") }
    if (!excluded.isEmpty || enclosingFolder != nil) && command != "pack" && command != "scan" {
        throw CrossZipError.message("--root / --exclude 仅用于压缩和扫描。")
    }
    let context = JobContext { update in
        guard !quiet else { return }
        let progress = update.fraction.map { " \(Int($0 * 100))%" } ?? ""
        FileHandle.standardError.write(Data("[\(update.phase.rawValue)\(progress)] \(update.path) \(update.detail)\n".utf8))
    }
    var signals: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { context.cancel() }
        source.resume()
        signals.append(source)
    }
    defer { signals.forEach { $0.cancel() } }
    let service = ArchiveManager()
    let result: OperationResult
    switch command {
    case "scan":
        let plan = try SourceScanner.scan(arguments.map { URL(fileURLWithPath: $0) }, context: context,
                                          excluding: excluded, enclosingFolderName: enclosingFolder)
        try emitJSON(["canProceed": plan.canProceed, "fileCount": plan.fileCount, "directoryCount": plan.directoryCount,
                      "totalBytes": plan.totalBytes, "excluded": plan.excluded, "issues": plan.issues.map(issueJSON)])
        if !plan.canProceed { exit(2) }
        return
    case "pack":
        guard let output else { throw CrossZipError.message("pack 需要 --output。") }
        let inferred = ArchiveFormat.allCases.first { output.lowercased().hasSuffix("." + $0.rawValue) } ?? .zip
        guard let format = formatValue.map(ArchiveFormat.init(rawValue:)) ?? inferred else {
            throw CrossZipError.message("可创建 ZIP、7z、TAR、TAR.GZ、TAR.BZ2、TAR.XZ。RAR 仅支持解压。")
        }
        if storeOnly && format != .zip { throw CrossZipError.message("--store 仅用于 ZIP；TAR 本身不压缩。") }
        result = try service.compress(arguments.map { URL(fileURLWithPath: $0) }, to: URL(fileURLWithPath: output),
                                      format: format, level: level, storeOnly: storeOnly,
                                      excluding: excluded, enclosingFolderName: enclosingFolder, context: context)
    case "inspect", "verify", "extract":
        guard arguments.count == 1 else { throw CrossZipError.message("请选择一个压缩包。") }
        let url = URL(fileURLWithPath: arguments[0])
        if command == "verify" {
            try emitJSON(inspectionJSON(service.verify(url, encoding: encoding, context: context)))
            return
        }
        let inspection = try service.inspect(url, encoding: encoding, context: context)
        if command == "inspect" {
            try emitJSON(inspectionJSON(inspection))
            if !inspection.canProceed { exit(2) }
            return
        }
        guard let target else { throw CrossZipError.message("extract 需要 --to。") }
        var selected: Set<Int>?
        if !included.isEmpty {
            var ids: Set<Int> = []
            for path in included {
                guard let member = inspection.records.first(where: { $0.path.utf8.elementsEqual(path.utf8) }) else {
                    throw CrossZipError.message("归档内不存在所选路径：\(path)")
                }
                ids.insert(member.id)
            }
            selected = ids
        }
        result = try service.extract(inspection, to: URL(fileURLWithPath: target), selectedIDs: selected, context: context)
    default: throw CrossZipError.message("未知命令：\(command)")
    }
    try emitJSON(["status": "ok", "outputPath": result.url.path, "fileCount": result.fileCount,
                  "directoryCount": result.directoryCount, "totalBytes": result.totalBytes, "excludedCount": result.excludedCount])
}

do { try run() }
catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    if case CrossZipError.cancelled = error { exit(130) }
    exit(1)
}
