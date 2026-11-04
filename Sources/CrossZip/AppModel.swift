import Foundation
import AppKit
import SwiftUI
import CrossZipCore

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "跟随系统" : self == .light ? "浅色" : "深色" }
    var colorScheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
    var native: NSAppearance? { self == .system ? nil : NSAppearance(named: self == .light ? .aqua : .darkAqua) }
}

enum WorkMode: String, CaseIterable, Identifiable {
    case compress = "压缩", extract = "解压"
    var id: String { rawValue }
}

struct PreviewItem: Identifiable {
    let id: Int
    let path: String
    let kind: ItemKind
    let size: UInt64
    var sourceURL: URL? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: WorkMode = .compress
    @Published var sources: [URL] = []
    @Published var sourcePlan: SourcePlan?
    @Published var archiveURL: URL?
    @Published var inspection: ArchiveInspection?
    @Published var format: ArchiveFormat = .zip
    @Published var level: CompressionLevel = .maximum
    @Published var storeOnly = false
    @Published var selectedEntryIDs: Set<Int> = []
    @Published var encoding: FilenameEncoding = .automatic
    @Published var isBusy = false
    @Published var update: JobUpdate?
    @Published var result: OperationResult?
    @Published var verified = false
    @Published var errorMessage: String?
    @Published var extraIssues: [ArchiveIssue] = []
    @Published var search = ""
    @Published var showHelp = false
    @Published var archiveName = ""
    @Published var saveDirectory: URL?
    @Published var omittedURLs: Set<URL> = []
    @Published var estimate: ArchiveSizeEstimate?
    @Published var isEstimating = false
    @Published var estimateError: String?
    @Published var appearance: AppAppearance = .system {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance"); applyAppearance() }
    }
    var onIdle: (() -> Void)?
    private var context: JobContext?
    private var activeID: UUID?
    private let defaults: UserDefaults
    private let estimatesEnabled: Bool
    private var estimateTask: Task<Void, Never>?
    private var estimateContext: JobContext?
    private var estimateID: UUID?
    var hasBackgroundWork: Bool { isBusy || estimateTask != nil }

    init(defaults: UserDefaults = .standard, estimatesEnabled: Bool = false) {
        self.defaults = defaults; self.estimatesEnabled = estimatesEnabled
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "system") ?? .system
    }

    func applyAppearance() { NSApp?.appearance = appearance.native }

    var effectiveSaveDirectory: URL? { saveDirectory ?? sources.first?.standardizedFileURL.deletingLastPathComponent() }
    var effectiveArchiveName: String {
        let roots = sourcePlan?.rootCount ?? sources.count
        let base = archiveName.isEmpty ? (roots == 1 ? (sourcePlan?.sources.first ?? sources.first)?.lastPathComponent ?? "归档" : "归档") : archiveName
        return OutputNames.archiveName(for: base, format: format)
    }
    var enclosingFolderName: String? {
        (sourcePlan?.rootCount ?? sources.count) > 1 ? String(effectiveArchiveName.dropLast(format.rawValue.count + 1)) : nil
    }
    var validArchiveName: Bool {
        !effectiveArchiveName.contains("/") && !effectiveArchiveName.utf8.contains(0)
    }
    var estimateDescription: String {
        if isEstimating { return "估算中…" }
        guard let estimate else { return estimateError == nil ? "—" : "暂不可用" }
        func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
        if estimate.isSampled {
            let magnitude = pow(10, max(0, floor(log10(max(1, Double(estimate.bytes)))) - 1))
            let rounded = UInt64((Double(estimate.bytes) / magnitude).rounded() * magnitude)
            return "粗估 " + size(rounded)
        }
        return "约 " + size(estimate.bytes)
    }

    var estimateDetail: String {
        if let estimateError { return estimateError }
        guard let estimate else { return "使用当前格式与等级进行试压估算。" }
        guard estimate.isSampled else { return "已试压所选文件数据与归档元数据；源文件变化会影响最终大小。" }
        let coverage = estimate.sourceFileBytes == 0 ? 0 : Double(estimate.sampledBytes) / Double(estimate.sourceFileBytes) * 100
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(clamping: estimate.sampledBytes), countStyle: .file)
        return "已抽样 \(bytes)，来自 \(estimate.sampledFileCount) / \(estimate.totalFileCount) 个普通文件，约占文件数据的 \(String(format: "%.2f", coverage))%。\n样本偏向较大文件，误差未经过标定；不能据此保证最终大小。"
    }

    var issues: [ArchiveIssue] {
        var seen: Set<String> = []
        let nameIssues = mode == .compress && hasInput ?
            (!validArchiveName ? [ArchiveIssue("压缩包名称", "名称不能包含 / 或空字符")] :
                enclosingFolderName.map { PathRules.validateTree([($0, .directory)]) } ?? []) : []
        return (extraIssues + nameIssues + (mode == .compress ? sourcePlan?.issues ?? [] : inspection?.issues ?? []))
            .filter { seen.insert($0.id).inserted }
    }
    var blockers: [ArchiveIssue] { issues.filter { $0.severity == .error } }
    var hasInput: Bool { mode == .compress ? !sources.isEmpty : archiveURL != nil }
    var canRun: Bool {
        !isBusy && blockers.isEmpty && (mode == .compress ? sourcePlan?.canProceed == true && validArchiveName :
            inspection?.canProceed == true && (inspection?.records.isEmpty == true || !selectedEntryIDs.isEmpty))
    }
    var fileCount: Int { mode == .compress ? sourcePlan?.fileCount ?? 0 : inspection?.fileCount ?? 0 }
    var directoryCount: Int { mode == .compress ? (sourcePlan?.directoryCount ?? 0) + (enclosingFolderName == nil ? 0 : 1) : inspection?.directoryCount ?? 0 }
    var totalBytes: UInt64 { mode == .compress ? sourcePlan?.totalBytes ?? 0 : inspection?.totalBytes ?? 0 }
    var selectedCount: Int { selectedEntryIDs.count }
    var selectedBytes: UInt64 { inspection?.records.filter { selectedEntryIDs.contains($0.id) }.reduce(0) { $0 + $1.size } ?? 0 }
    var allEntriesSelected: Bool { inspection?.records.allSatisfy { selectedEntryIDs.contains($0.id) } == true }
    var resultSizeDescription: String? {
        guard mode == .compress, let result,
              let size = try? result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return "原始 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: result.totalBytes), countStyle: .file)) → 归档 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }
    var previewItems: [PreviewItem] {
        let query = search
        if mode == .compress {
            let prefix = enclosingFolderName.map { $0 + "/" } ?? ""
            var rows = Array((sourcePlan?.items ?? []).enumerated().lazy
                .filter { query.isEmpty || (prefix + $0.element.path).localizedCaseInsensitiveContains(query) }.prefix(500).map {
                PreviewItem(id: $0.offset, path: prefix + $0.element.path, kind: $0.element.kind,
                            size: $0.element.size, sourceURL: $0.element.url)
            })
            if let root = enclosingFolderName, sourcePlan != nil, query.isEmpty || root.localizedCaseInsensitiveContains(query) {
                rows.insert(PreviewItem(id: -1, path: root, kind: .directory, size: 0), at: 0)
            }
            return Array(rows.prefix(500))
        } else {
            return Array((inspection?.records ?? []).lazy
                .filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }.prefix(500).map {
                PreviewItem(id: $0.id, path: $0.path, kind: $0.kind, size: $0.size)
            })
        }
    }

    func chooseSources() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择文件或文件夹"
        panel.prompt = "添加"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addSources(panel.urls) }
    }

    func chooseArchive() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "打开压缩包"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openArchive(url) }
    }

    @discardableResult
    func receive(_ urls: [URL]) -> Bool {
        guard !isBusy, !urls.isEmpty else { return false }
        guard urls.allSatisfy(\.isFileURL) else { errorMessage = "请拖入本机的文件、文件夹或压缩包。"; return false }
        // A folder may also end in .zip. Only a regular archive starts extraction;
        // all other selections switch back to compression, including multi-select.
        if urls.count == 1, ArchiveFormat.recognizes(urls[0]),
           (try? urls[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
           (try? urls[0].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            openArchive(urls[0])
        } else { addSources(urls) }
        return true
    }

    func addSources(_ urls: [URL]) {
        guard !isBusy else { return }
        mode = .compress
        for url in urls {
            omittedURLs = omittedURLs.filter { !PathRules.contains($0, in: url) }
            if !sources.contains(where: { $0.path.utf8.elementsEqual(url.path.utf8) }) { sources.append(url) }
        }
        previewSources()
    }

    func prepareCompressionSelection(_ urls: [URL]) throws {
        guard !isBusy else {
            throw CrossZipError.message("CrossZip 正在处理另一项任务，请等待完成后再使用右键压缩。")
        }
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else {
            throw CrossZipError.message("请在 Finder 中选择本机文件或文件夹。")
        }
        mode = .compress
        // A context-menu command means exactly this selection, never previous inputs.
        sources = urls
        omittedURLs = []; archiveName = ""
        search = ""
        previewSources()
    }

    func removeSource(_ url: URL) {
        guard !isBusy else { return }
        sources.removeAll { $0.path.utf8.elementsEqual(url.path.utf8) }
        omittedURLs.insert(url.standardizedFileURL)
        if sources.isEmpty { clear() } else { previewSources() }
    }

    func openArchive(_ url: URL) {
        guard !isBusy else { return }
        mode = .extract
        archiveURL = url
        encoding = .automatic
        previewArchive()
    }

    func previewSources() {
        sourcePlan = nil
        let urls = sources
        let omitted = Array(omittedURLs)
        run({ try SourceScanner.scan(urls, context: $0, excluding: omitted) }) { self.sourcePlan = $0 }
    }

    func removeItem(_ item: PreviewItem) {
        guard !isBusy, mode == .compress else { return }
        if let url = item.sourceURL { removeSource(url) }
        else if item.id == -1 { clear() }
    }

    func chooseSaveDirectory() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "压缩包保存位置"; panel.prompt = "选择"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = effectiveSaveDirectory
        if panel.runModal() == .OK { saveDirectory = panel.url }
    }

    func previewArchive() {
        guard !isBusy, let url = archiveURL else { return }
        inspection = nil
        selectedEntryIDs = []
        let selectedEncoding = encoding
        run({ try ArchiveManager().inspect(url, encoding: selectedEncoding, context: $0) }) {
            self.inspection = $0
            self.selectedEntryIDs = Set($0.records.map(\.id))
        }
    }

    func start() {
        guard canRun else { return }
        if mode == .compress {
            guard let directory = effectiveSaveDirectory else { return }
            let stem = String(effectiveArchiveName.dropLast(format.rawValue.count + 1))
            let destination = OutputNames.availableArchiveURL(for: stem, format: format, in: directory)
            compress(to: destination)
        } else if let inspection {
            let panel = NSOpenPanel()
            panel.title = "选择解压位置"
            panel.message = "解压到新建文件夹"
            panel.prompt = "解压到这里"
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.directoryURL = archiveURL?.deletingLastPathComponent()
            guard panel.runModal() == .OK, let parent = panel.url else { return }
            let selected = selectedEntryIDs
            run({ try ArchiveManager().extract(inspection, to: parent, selectedIDs: selected, context: $0) }) { self.result = $0 }
        }
    }

    func compress(to destination: URL) {
        guard canRun, mode == .compress else { return }
        let urls = sources, omitted = Array(omittedURLs), root = enclosingFolderName
        let selectedFormat = format, selectedLevel = level, selectedStore = storeOnly
        run({ try ArchiveManager().compress(urls, to: destination, format: selectedFormat, level: selectedLevel,
                                            storeOnly: selectedStore, excluding: omitted, enclosingFolderName: root,
                                            context: $0) }) { self.result = $0 }
    }

    func verifyArchive() {
        guard !isBusy, let url = archiveURL else { return }
        let selectedEncoding = encoding
        let selectedPaths = inspection.map { current in
            Set(current.records.filter { selectedEntryIDs.contains($0.id) }.map { Data($0.path.utf8) })
        }
        run({ try ArchiveManager().verify(url, encoding: selectedEncoding, context: $0) }) {
            self.inspection = $0; self.verified = true
            self.selectedEntryIDs = Set($0.records.filter { selectedPaths?.contains(Data($0.path.utf8)) ?? true }.map(\.id))
        }
    }

    func cancel() { context?.cancel() }
    func cancelForTermination(_ completion: @escaping () -> Void) {
        let pending = stopEstimate()
        context?.cancel()
        Task {
            if let pending { await pending.value }
            estimateTask = nil; estimateContext = nil
            if isBusy { onIdle = completion } else { completion() }
        }
    }
    func selectAllEntries() {
        guard !isBusy else { return }
        selectedEntryIDs = allEntriesSelected ? [] : Set(inspection?.records.map(\.id) ?? [])
    }
    func toggleEntry(_ id: Int) {
        guard !isBusy, let records = inspection?.records, let item = records.first(where: { $0.id == id }) else { return }
        let chosen = !selectedEntryIDs.contains(id)
        let affected = records.filter { $0.id == id || (item.kind == .directory && $0.path.hasPrefix(item.path + "/")) }.map(\.id)
        if chosen { selectedEntryIDs.formUnion(affected) }
        else {
            selectedEntryIDs.subtract(affected)
            for parent in records where parent.kind == .directory && item.path.hasPrefix(parent.path + "/") {
                selectedEntryIDs.remove(parent.id)
            }
        }
    }
    func isPartiallySelected(_ item: PreviewItem) -> Bool {
        item.kind == .directory && !selectedEntryIDs.contains(item.id) &&
            inspection?.records.contains(where: { $0.path.hasPrefix(item.path + "/") && selectedEntryIDs.contains($0.id) }) == true
    }
    func compressionOptionsChanged() {
        guard !isBusy else { return }
        if format != .zip { storeOnly = false }
        result = nil; update = nil
        refreshEstimate()
    }
    func revealResult() {
        if let result { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
    }
    func clear() {
        guard !isBusy else { return }
        _ = stopEstimate()
        if mode == .compress { sources = []; sourcePlan = nil; omittedURLs = []; archiveName = "" }
        else { archiveURL = nil; inspection = nil; selectedEntryIDs = [] }
        result = nil; verified = false; errorMessage = nil; extraIssues = []; update = nil; search = ""
    }
    func modeChanged() {
        _ = stopEstimate()
        result = nil; verified = false; errorMessage = nil; extraIssues = []; update = nil; search = ""
        if mode == .compress { refreshEstimate() }
    }

    @discardableResult
    private func stopEstimate() -> Task<Void, Never>? {
        let pending = estimateTask
        estimateTask?.cancel(); estimateContext?.cancel(); estimateID = nil
        estimate = nil; estimateError = nil; isEstimating = false
        return pending
    }

    func refreshEstimate() {
        let previous = stopEstimate()
        guard estimatesEnabled, mode == .compress, validArchiveName, let plan = sourcePlan, plan.canProceed else { return }
        let id = UUID(), context = JobContext()
        estimateID = id; estimateContext = context; isEstimating = true
        let format = format, level = level, stored = storeOnly, root = enclosingFolderName
        estimateTask = Task { [weak self] in
            if let previous { await previous.value }
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                let value = try await Task.detached(priority: .utility) {
                    try ArchiveEstimator.estimate(plan, format: format, level: level, storeOnly: stored,
                                                  enclosingFolderName: root, context: context)
                }.value
                guard let self, self.estimateID == id else { return }
                self.estimate = value; self.isEstimating = false
                self.estimateTask = nil; self.estimateContext = nil
            } catch {
                guard let self, self.estimateID == id else { return }
                self.isEstimating = false; self.estimateError = error.localizedDescription
                self.estimateTask = nil; self.estimateContext = nil
            }
        }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable (JobContext) throws -> T,
                                  success: @escaping (T) -> Void) {
        guard !isBusy else { return }
        let pendingEstimate = stopEstimate()
        let id = UUID()
        activeID = id
        isBusy = true
        result = nil; verified = false; errorMessage = nil; extraIssues = []; update = nil
        let context = JobContext { [weak self] update in
            Task { @MainActor in
                guard let self, self.activeID == id else { return }
                self.update = update
            }
        }
        self.context = context
        Task {
            if let pendingEstimate { await pendingEstimate.value }
            do {
                let value = try await Task.detached(priority: .userInitiated) { try work(context) }.value
                success(value)
            } catch CrossZipError.issues(let issues) {
                extraIssues = issues
                errorMessage = "有内容无法读取或无法安全处理，尚未生成正式结果。请查看具体问题。"
            } catch CrossZipError.cancelled {
                errorMessage = "任务已取消，临时内容已清理。"
            } catch { errorMessage = error.localizedDescription }
            isBusy = false
            activeID = nil
            self.context = nil
            if self.mode == .compress && self.result == nil && self.errorMessage == nil { self.refreshEstimate() }
            onIdle?()
            onIdle = nil
        }
    }
}
