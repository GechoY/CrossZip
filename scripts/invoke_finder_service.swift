import AppKit
import Foundation

// Developer integration check: invokes the same macOS service used by Finder,
// using a private pasteboard so the user's clipboard is untouched.
var arguments = Array(CommandLine.arguments.dropFirst())
var serviceName = "使用 CrossZip 压缩"
if arguments.first == "--service-name", arguments.count >= 3 {
    arguments.removeFirst()
    serviceName = arguments.removeFirst()
}
let selection = arguments.map { URL(fileURLWithPath: $0) as NSURL }
guard !selection.isEmpty else {
    fputs("传入要载入 CrossZip 的测试文件或文件夹路径。\n", stderr)
    exit(2)
}
let application = NSApplication.shared
let pasteboard = NSPasteboard.withUniqueName()
guard pasteboard.writeObjects(selection) else { exit(1) }
guard NSPerformService(serviceName, pasteboard) else {
    fputs("macOS 未能调用 CrossZip 文件服务。\n", stderr)
    exit(1)
}
print("macOS service accepted \(selection.count) selected item(s).")
