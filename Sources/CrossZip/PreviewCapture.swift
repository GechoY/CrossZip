import AppKit
import Foundation
import CrossZipCore

/// Developer-only invocation for reproducible visual QA; normal launches never enter this path.
@MainActor
enum PreviewCapture {
    private static var started = false
    static func startIfRequested(model: AppModel) {
        let arguments = CommandLine.arguments
        guard !started, let index = arguments.firstIndex(of: "--capture-preview"), index + 1 < arguments.count else { return }
        started = true
        let destination = URL(fileURLWithPath: arguments[index + 1])
        if arguments.contains("--dark") { model.appearance = .dark }
        if arguments.contains("--light") { model.appearance = .light }
        if arguments.contains("--preview-extract") { model.mode = .extract }
        if let input = arguments.firstIndex(of: "--preview-format"), input + 1 < arguments.count,
           let format = ArchiveFormat(rawValue: arguments[input + 1]) { model.format = format }
        let inputs = arguments.indices.filter { arguments[$0] == "--preview-source" && $0 + 1 < arguments.count }
            .map { URL(fileURLWithPath: arguments[$0 + 1]) }
        if let input = arguments.firstIndex(of: "--preview-name"), input + 1 < arguments.count { model.archiveName = arguments[input + 1] }
        if let input = arguments.firstIndex(of: "--preview-save-directory"), input + 1 < arguments.count {
            model.saveDirectory = URL(fileURLWithPath: arguments[input + 1])
        }
        if !inputs.isEmpty { model.addSources(inputs) }
        if let input = arguments.firstIndex(of: "--preview-archive"), input + 1 < arguments.count {
            model.openArchive(URL(fileURLWithPath: arguments[input + 1]))
        }
        var ticks = 0
        var showingProgress = false
        var showingHelp = false
        var appliedSelection = false
        let timer = Timer(timeInterval: 0.2, repeats: true) { timer in
            MainActor.assumeIsolated {
                ticks += 1
                guard ticks < 150 else { timer.invalidate(); exit(1) }
                guard ticks >= 3, (!model.isBusy || showingProgress), !model.isEstimating,
                      let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.canBecomeMain }) else { return }
                if arguments.contains("--wait-for-finder-service") && model.sources.isEmpty { return }
                if arguments.contains("--preview-select-one") && !appliedSelection, let inspection = model.inspection,
                   let member = inspection.records.first(where: { $0.kind == .file }) {
                    model.selectedEntryIDs = [member.id]
                    appliedSelection = true
                    return
                }
                if arguments.contains("--preview-help") && !showingHelp {
                    showingHelp = true
                    model.showHelp = true
                    return
                }
                if arguments.contains("--preview-progress") && !showingProgress {
                    showingProgress = true
                    let previewContext = JobContext { update in Task { @MainActor in model.update = update } }
                    previewContext.report(.compressing, path: model.sourcePlan?.items.last?.path ?? "资料/文件.bin",
                                          fraction: 0.46, detail: "按原名和原始内容写入 \(model.format.rawValue.uppercased())…", force: true)
                    model.isBusy = true
                    return
                }
                let captureWindow: NSWindow
                if arguments.contains("--preview-help") {
                    guard let sheet = window.attachedSheet else { return }
                    captureWindow = sheet
                } else { captureWindow = window }
                guard let view = captureWindow.contentView else { return }
                timer.invalidate()
                func dimension(_ option: String, fallback: Double) -> Double {
                    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count,
                          let value = Double(arguments[index + 1]) else { return fallback }
                    return value
                }
                window.setContentSize(NSSize(width: dimension("--capture-width", fallback: 1180),
                                             height: dimension("--capture-height", fallback: 800)))
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                do {
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                    try png.write(to: destination)
                    let state: [String: Any] = ["mode": model.mode.rawValue, "canRun": model.canRun,
                                               "fileCount": model.fileCount, "issueCount": model.issues.count,
                                               "format": model.inspection?.formatName ?? model.format.rawValue,
                                               "selectedCount": model.selectedCount,
                                               "appearance": model.appearance.rawValue,
                                               "estimate": model.estimateDescription,
                                               "saveDirectory": model.effectiveSaveDirectory?.path ?? "",
                                               "enclosingFolder": model.enclosingFolderName ?? "",
                                               "error": model.errorMessage ?? "", "sources": model.sources.map(\.path)]
                    try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                        .write(to: destination.appendingPathExtension("json"))
                    if showingProgress { model.isBusy = false }
                    // The capture process owns no active job. Exit directly so a
                    // modal help sheet cannot defer this developer-only shutdown.
                    exit(0)
                } catch { fputs("\(error)\n", stderr); exit(1) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
}
