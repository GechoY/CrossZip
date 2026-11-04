import SwiftUI
import AppKit
import CrossZipCore

private enum WorkspaceStyle {
    static let accent = adaptive(0x625CE5, 0xA6A1FF)
    static let canvas = adaptive(0xFAFAFC, 0x17171C)
    static let sidebar = adaptive(0xF0F0F4, 0x111115)
    static let surface = adaptive(0xFFFFFF, 0x202026)
    static let border = adaptive(0xE4E4EB, 0x33333D)
    static let muted = adaptive(0x737380, 0xA2A2AF)
    static let onAccent = adaptive(0xFFFFFF, 0x17132F)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var isDropTarget = false
    @State private var showIssues = false

    private var compressing: Bool { model.mode == .compress }
    private var title: String { compressing ? "压缩" : "解压" }
    private var selection: [URL] { compressing ? model.sources : model.archiveURL.map { [$0] } ?? [] }
    private var statusTitle: String {
        if model.isBusy { return model.update?.phase.rawValue ?? "准备中" }
        if model.result != nil { return "已完成" }
        if model.verified { return "校验通过" }
        if !model.blockers.isEmpty || model.errorMessage != nil { return "请查看提示" }
        if model.canRun { return "准备就绪" }
        return model.hasInput ? "等待文件检查" : "等待添加文件"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 192)
            Rectangle().fill(WorkspaceStyle.border).frame(width: 1).ignoresSafeArea(edges: .top)
            VStack(spacing: 0) {
                toolbar
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let result = model.result { completion(result) }
                        if !model.issues.isEmpty { issuePanel }
                        if let message = model.errorMessage { errorNotice(message) }
                        if model.hasInput {
                            loadedWorkspace
                        } else {
                            emptyWorkspace
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                footer
            }
            .background(WorkspaceStyle.canvas)
        }
        .tint(WorkspaceStyle.accent)
        .preferredColorScheme(model.appearance.colorScheme)
        .onAppear { model.applyAppearance() }
        .onChange(of: model.blockers.count) { _, count in if count > 0 { showIssues = true } }
        .sheet(isPresented: $model.showHelp) { help }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(WorkspaceStyle.onAccent)
                    .frame(width: 33, height: 33)
                    .background(WorkspaceStyle.accent, in: RoundedRectangle(cornerRadius: 10))
                Text("CrossZip").font(.system(size: 17, weight: .semibold))
            }.padding(.horizontal, 19).padding(.top, 25).padding(.bottom, 29)

            VStack(spacing: 5) {
                modeButton(.compress, title: "压缩", icon: "archivebox")
                modeButton(.extract, title: "解压", icon: "tray.and.arrow.down")
            }.padding(.horizontal, 12)

            if !selection.isEmpty {
                Rectangle().fill(WorkspaceStyle.border).frame(height: 1).padding(.horizontal, 20).padding(.vertical, 22)
                HStack {
                    Text(compressing ? "已添加" : "压缩包").font(.system(size: 10, weight: .medium))
                    Spacer()
                    Text("\(selection.count)").font(.system(size: 10).monospacedDigit())
                }.foregroundStyle(WorkspaceStyle.muted).padding(.horizontal, 22).padding(.bottom, 12)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(selection, id: \.self) { source in sidebarSource(source) }
                    }.padding(.horizontal, 12)
                }
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(WorkspaceStyle.muted)
                    Picker("外观", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().controlSize(.small)
                }
                Button { model.showHelp = true } label: {
                    HStack {
                        Label("使用说明", systemImage: "questionmark.circle")
                        Spacer()
                    }.font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
                }.buttonStyle(.plain)
            }.padding(22)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspaceStyle.sidebar)
    }

    private func modeButton(_ mode: WorkMode, title: String, icon: String) -> some View {
        let selected = model.mode == mode
        return Button {
            guard model.mode != mode else { return }
            model.mode = mode
            model.modeChanged()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                    .foregroundStyle(selected ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
                if selected { Circle().fill(WorkspaceStyle.accent).frame(width: 5, height: 5) }
            }
            .foregroundStyle(selected ? Color.primary : WorkspaceStyle.muted)
            .padding(.horizontal, 12).frame(height: 39)
            .background(selected ? WorkspaceStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? WorkspaceStyle.border : .clear, lineWidth: 0.7))
        }.buttonStyle(.plain).disabled(model.isBusy)
            .accessibilityValue(selected ? "已选择" : "")
    }

    private func sidebarSource(_ source: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: compressing ? "doc.on.doc" : "doc.zipper")
                .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted)
            Text(source.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).help(source.path)
            Spacer(minLength: 0)
            if compressing {
                Button { model.removeSource(source) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(WorkspaceStyle.muted).frame(width: 20, height: 24)
                }.buttonStyle(.plain).help("移除 \(source.lastPathComponent)")
                    .accessibilityLabel("移除 \(source.lastPathComponent)").disabled(model.isBusy)
            }
        }.padding(.leading, 10).padding(.trailing, 5).frame(width: 168, height: 33)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Spacer()
            if model.hasInput {
                Button {
                    if compressing { model.previewSources() } else { model.previewArchive() }
                } label: { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).help("重新检查").accessibilityLabel("重新检查").disabled(model.isBusy)
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 24).frame(height: 64)
        .background(WorkspaceStyle.surface.opacity(0.55))
        .overlay(alignment: .bottom) { Rectangle().fill(WorkspaceStyle.border).frame(height: 1) }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 0) {
            archiveArtwork.padding(.top, 46).padding(.bottom, 23)
            Text(compressing ? "拖入文件或文件夹" : "拖入压缩包")
                .font(.system(size: 20, weight: .medium))
            Button(action: chooseInput) {
                HStack(spacing: 9) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text(compressing ? "选择文件…" : "打开…").font(.system(size: 12, weight: .medium))
                }.padding(.horizontal, 19).frame(height: 35)
            }.buttonStyle(WorkspacePrimaryButtonStyle()).padding(.top, 24).padding(.bottom, 49)
        }
        .frame(maxWidth: .infinity)
        .background(isDropTarget ? WorkspaceStyle.accent.opacity(0.06) : WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isDropTarget ? WorkspaceStyle.accent : WorkspaceStyle.border,
                    style: StrokeStyle(lineWidth: isDropTarget ? 1.5 : 1, dash: isDropTarget ? [6, 4] : [])))
        .dropDestination(for: URL.self) { urls, _ in model.receive(urls) } isTargeted: { isDropTarget = $0 }
        .disabled(model.isBusy)
    }

    private var archiveArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 21).fill(WorkspaceStyle.accent.opacity(0.035))
                .frame(width: 116, height: 89).rotationEffect(.degrees(-9))
            RoundedRectangle(cornerRadius: 17).fill(WorkspaceStyle.accent.opacity(0.07))
                .frame(width: 91, height: 85).rotationEffect(.degrees(9)).offset(x: 12, y: -4)
            RoundedRectangle(cornerRadius: 17).fill(WorkspaceStyle.surface)
                .overlay(RoundedRectangle(cornerRadius: 17).stroke(WorkspaceStyle.accent.opacity(0.16), lineWidth: 1))
                .frame(width: 78, height: 82).shadow(color: .black.opacity(0.035), radius: 12, y: 5)
            Image(systemName: compressing ? "archivebox" : "tray.and.arrow.down")
                .font(.system(size: 33, weight: .light)).foregroundStyle(WorkspaceStyle.accent)
            Image(systemName: compressing ? "plus" : "arrow.down")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(WorkspaceStyle.onAccent)
                .frame(width: 25, height: 25).background(WorkspaceStyle.accent, in: Circle())
                .overlay(Circle().stroke(WorkspaceStyle.surface, lineWidth: 3)).offset(x: 38, y: 33)
        }.frame(height: 103).accessibilityHidden(true)
    }

    private var loadedWorkspace: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 16) {
                addMoreBar
                preview
            }.frame(maxWidth: .infinity)
            VStack(spacing: 16) {
                if compressing || model.inspection != nil { summary }
                if compressing { destinationControls }
                if !compressing && (model.inspection?.supportsFilenameEncoding == true || model.inspection == nil) { encodingControls }
                if !compressing && model.inspection != nil {
                    Button(action: model.verifyArchive) {
                        Label("校验", systemImage: "checkmark.seal").font(.system(size: 11)).frame(maxWidth: .infinity)
                    }.disabled(model.isBusy || model.inspection?.canProceed != true)
                }
            }.frame(width: 280)
        }
    }

    private var addMoreBar: some View {
        HStack(spacing: 10) {
            Image(systemName: compressing ? "plus.circle" : "doc.zipper")
                .font(.system(size: 18, weight: .light)).foregroundStyle(WorkspaceStyle.accent)
            Text(compressing ? "拖入文件或文件夹" : model.archiveURL?.lastPathComponent ?? "压缩包")
                .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .help(compressing ? "可一次添加多个文件或文件夹" : model.archiveURL?.path ?? "")
            Spacer(minLength: 3)
            Button(compressing ? "添加…" : "更换…", action: chooseInput)
                .font(.system(size: 11)).controlSize(.small)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceStyle.accent.opacity(isDropTarget ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.accent.opacity(isDropTarget ? 0.65 : 0.16),
                                                                style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        .dropDestination(for: URL.self) { urls, _ in model.receive(urls) } isTargeted: { isDropTarget = $0 }
        .disabled(model.isBusy)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("文件").font(.system(size: 12, weight: .semibold))
                if !compressing && model.inspection != nil {
                    Button(model.allEntriesSelected ? "取消全选" : "全选", action: model.selectAllEntries)
                        .font(.system(size: 10)).buttonStyle(.borderless).disabled(model.isBusy)
                        .help("切换全部条目，包括搜索结果之外的文件")
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                    TextField("搜索文件", text: $model.search).textFieldStyle(.plain).font(.system(size: 11))
                }.padding(.horizontal, 8).frame(width: 134, height: 26)
                    .background(WorkspaceStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
            }.padding(.horizontal, 14).frame(height: 47)
            Rectangle().fill(WorkspaceStyle.border).frame(height: 1)
            HStack {
                Text("名称")
                Spacer()
                Text("类型").frame(width: 61, alignment: .leading)
                Text("大小").frame(width: 65, alignment: .trailing)
                if compressing { Color.clear.frame(width: 24) }
            }.font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                .padding(.horizontal, 16).frame(height: 31).background(WorkspaceStyle.canvas.opacity(0.75))
            Rectangle().fill(WorkspaceStyle.border).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.previewItems) { item in
                        FilePreviewRow(item: item,
                                       selected: compressing ? nil : model.selectedEntryIDs.contains(item.id),
                                       partiallySelected: !compressing && model.isPartiallySelected(item),
                                       selectionEnabled: !model.isBusy,
                                       onSelect: { model.toggleEntry(item.id) },
                                       onRemove: compressing ? { model.removeItem(item) } : nil)
                    }
                }
                if model.previewItems.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: model.isBusy ? "hourglass" : "doc.text.magnifyingglass")
                            .font(.system(size: 24, weight: .light))
                        Text(model.isBusy ? "正在读取文件清单…" : model.search.isEmpty ? "没有可显示的条目" : "没有匹配的文件")
                            .font(.system(size: 11))
                        if !model.search.isEmpty { Button("清除搜索") { model.search = "" }.font(.system(size: 11)) }
                    }.foregroundStyle(WorkspaceStyle.muted).frame(maxWidth: .infinity).padding(.top, 75)
                }
            }.frame(height: 300)
            Rectangle().fill(WorkspaceStyle.border).frame(height: 1)
            HStack {
                Text(compressing ? "\(model.fileCount + model.directoryCount) 项" : "已选 \(model.selectedCount) / \(model.fileCount + model.directoryCount) 项")
                    .help("清单最多显示前 500 个匹配条目，可搜索其他文件；全选会选择整个压缩包。")
                if model.previewItems.count == 500 {
                    Text("显示前 500 项").foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer()
                Button(compressing ? "全部移除" : "关闭", action: model.clear).buttonStyle(.plain).disabled(model.isBusy)
                    .help(compressing ? "清空本次选择，不删除磁盘原文件" : "关闭当前压缩包预览")
            }.font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).padding(.horizontal, 14).frame(height: 33)
        }
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(WorkspaceStyle.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(compressing ? "压缩设置" : "概览").font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: "doc.zipper").font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted)
                    .accessibilityHidden(true)
            }
            if compressing {
                compressionControls
                Rectangle().fill(WorkspaceStyle.border).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(byteString(model.totalBytes)).font(.system(size: 23, weight: .medium)).monospacedDigit()
                Text("总大小").font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                if !compressing && !model.allEntriesSelected {
                    Text("已选 \(byteString(model.selectedBytes))").font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                }
            }
            if compressing {
                detailRow("预计大小", model.estimateDescription)
                    .help(model.estimateDetail)
                if let estimate = model.estimate, estimate.isSampled {
                    Text("已抽样 " + byteString(estimate.sampledBytes))
                        .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                        .help(model.estimateDetail)
                }
            }
            VStack(spacing: 12) {
                detailRow("文件", "\(model.fileCount)")
                detailRow("文件夹", "\(model.directoryCount)")
                if !compressing { detailRow("格式", model.inspection?.formatName ?? "待识别") }
            }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(WorkspaceStyle.border, lineWidth: 1))
    }

    private var compressionControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("格式").font(.system(size: 11, weight: .medium))
            Picker("格式", selection: $model.format) {
                ForEach(ArchiveFormat.allCases) { Text(formatName($0)).tag($0) }
            }.labelsHidden().controlSize(.small).frame(maxWidth: .infinity)
                .help(model.format.note)
                .onChange(of: model.format) { _, _ in model.compressionOptionsChanged() }
            if model.format.supportsLevel {
                Picker("压缩等级", selection: $model.level) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level == .fast ? "快速" : level == .standard ? "标准" : "体积优先").tag(level)
                    }
                }.font(.system(size: 10)).controlSize(.small)
                    .onChange(of: model.level) { _, _ in model.compressionOptionsChanged() }
                    .disabled(model.storeOnly)
                    .help("体积优先会比较 9、6、1 三个等级，保留较小结果；耗时与临时空间会增加。")
            }
            if model.format == .zip {
                Toggle("仅打包", isOn: $model.storeOnly).font(.system(size: 10)).toggleStyle(.checkbox)
                    .help("保持 ZIP 格式，不压缩文件数据。")
                    .onChange(of: model.storeOnly) { _, _ in model.compressionOptionsChanged() }
            }
        }.disabled(model.isBusy)
    }

    private var destinationControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("保存位置").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 5) {
                TextField(String(model.effectiveArchiveName.dropLast(model.format.rawValue.count + 1)), text: $model.archiveName)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .onChange(of: model.archiveName) { _, _ in model.compressionOptionsChanged() }
                    .help("留空使用默认名称；无需填写扩展名")
                    .accessibilityLabel("压缩包名称")
                Text("." + model.format.rawValue).font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(WorkspaceStyle.accent)
                Text(model.effectiveSaveDirectory?.path ?? "原位置")
                    .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.effectiveSaveDirectory?.path ?? "默认保存在第一个所选项目的所在目录")
            }.font(.system(size: 11))
            HStack {
                Button("选择…", action: model.chooseSaveDirectory).controlSize(.small)
                if model.saveDirectory != nil {
                    Button("原位置") { model.saveDirectory = nil }.controlSize(.small)
                }
                Spacer()
            }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(WorkspaceStyle.border, lineWidth: 1))
            .disabled(model.isBusy)
    }

    private func detailRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(WorkspaceStyle.muted)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 11))
    }

    private var encodingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("文件名编码").font(.system(size: 12, weight: .semibold))
            Picker("文件名编码", selection: $model.encoding) {
                ForEach(FilenameEncoding.allCases) { Text($0 == .automatic ? "自动" : $0.title).tag($0) }
            }.labelsHidden().frame(maxWidth: .infinity).controlSize(.small)
                .onChange(of: model.encoding) { _, _ in model.previewArchive() }
                .help("文件名乱码时切换编码；不会改变文件内的文字。")
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(WorkspaceStyle.border, lineWidth: 1))
            .disabled(model.isBusy)
    }

    private var issuePanel: some View {
        let blocked = !model.blockers.isEmpty
        let color: Color = blocked ? .red : .orange
        return VStack(alignment: .leading, spacing: 0) {
            Button { showIssues.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: blocked ? "exclamationmark.circle" : "info.circle").font(.system(size: 15)).foregroundStyle(color)
                    Text(blocked ? "\(model.blockers.count) 项问题" : "\(model.issues.count) 项兼容提示")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: showIssues ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(WorkspaceStyle.muted)
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showIssues {
                Rectangle().fill(color.opacity(0.12)).frame(height: 1).padding(.horizontal, 14)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        ForEach(model.issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.path).font(.system(size: 10, weight: .medium))
                                Text(issue.reason + (issue.suggestion.isEmpty ? "" : "。" + issue.suggestion))
                                    .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).lineSpacing(3)
                            }.textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.frame(maxHeight: 120)
            }
        }.background(color.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.16), lineWidth: 1))
    }

    private func errorNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 11)).foregroundStyle(Color.red).textSelection(.enabled)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func completion(_ result: OperationResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 25)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 6) {
                Text(compressing ? "压缩完成" : "解压完成").font(.system(size: 12, weight: .semibold))
                Text(result.url.path).font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let size = model.resultSizeDescription {
                    Text(size).font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                }
            }
            Spacer(minLength: 12)
            Button("在 Finder 中显示", action: model.revealResult).font(.system(size: 11))
        }.padding(15).background(Color.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.14), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 20) {
            HStack(spacing: 10) {
                if model.isBusy { ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 20, height: 20) }
                else { Image(systemName: model.result != nil ? "checkmark.circle" : "circle.dotted").font(.system(size: 17)).foregroundStyle(WorkspaceStyle.muted) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(statusTitle)
                        .font(.system(size: 11, weight: .medium))
                    if model.isBusy {
                        Text(model.update?.path.isEmpty == false ? model.update!.path : model.update?.detail ?? "正在读取…")
                            .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).lineLimit(1).truncationMode(.middle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isBusy {
                VStack(spacing: 5) {
                    if let fraction = model.update?.fraction {
                        Text("\(Int(fraction * 100))%").font(.system(size: 10).monospacedDigit()).foregroundStyle(WorkspaceStyle.muted)
                        ProgressView(value: fraction)
                    } else { ProgressView().progressViewStyle(.linear) }
                }.frame(width: 125)
                Button("取消", action: model.cancel).controlSize(.large)
            } else {
                Button(action: model.start) {
                    HStack(spacing: 18) {
                        Text(compressing ? "压缩…" : "解压…").font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
                    }.frame(minWidth: 137, minHeight: 28)
                }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(!model.canRun)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(compressing ? "选择保存位置并压缩为 \(formatName(model.format))" : "选择保存位置并解压勾选的内容")
            }
        }
        .padding(.horizontal, 24).frame(height: 68)
        .background(WorkspaceStyle.surface)
        .overlay(alignment: .top) { Rectangle().fill(WorkspaceStyle.border).frame(height: 1) }
    }

    private var help: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox").font(.system(size: 23)).foregroundStyle(WorkspaceStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("使用 CrossZip").font(.system(size: 20, weight: .semibold))
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.1")")
                        .font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer()
                Button("完成") { model.showHelp = false }.keyboardShortcut(.defaultAction)
            }.padding(25)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    helpSection("开始使用", icon: "cursorarrow.click", text: "压缩：拖入文件或文件夹，在右侧选择格式、名称和保存位置。未选择保存位置时，使用第一个项目的所在目录。点击“压缩”直接保存，同名时自动编号。多选项目会增加一个外层目录，单选文件夹保留原文件夹。\n\n每行的 × 和“全部移除”只改变本次选择，不删除磁盘原文件。可以重新添加。\n\n解压：拖入压缩包，预览并勾选需要的内容，再选择位置。默认全选；勾选文件夹包含其全部内容。新建同名文件夹，已有目标时自动编号。\n\n左下角可选择跟随系统、浅色或深色，选择会保存。Finder 右键 → 服务 → 使用 CrossZip 压缩；系统自带的“压缩”仍保留。")
                    helpSection("格式与兼容性", icon: "textformat", text: "创建 ZIP、7z、TAR、TAR.GZ、TAR.BZ2、TAR.XZ。体积优先会比较 9、6、1 三个等级，保留较小结果；耗时和临时空间会增加。TAR 仅打包。ZIP 使用通用 Deflate，也可仅打包。\n\n可读取上述格式及 RAR / RAR5、CAB、CPIO、ISO、AR、GZIP、BZIP2、XZ、LZMA、LZIP、Unix compress。RAR 只解压；加密、分卷、多重嵌套压缩流暂不处理。单独 .gz 等解开一层，.tar.gz 等组合格式展开目录。\n\n旧 ZIP 名称乱码时，可切换 UTF-8、GB18030 / GBK 或 CP437；不改变文件内文字。Windows 特殊名称和长路径只提示，不自动改名。目标磁盘不能区分的名称在解压时会停止，避免覆盖。")
                    helpSection("预计大小与完整性", icon: "checkmark.shield", text: "普通小选择会完整试压；较大选择累计抽样最多 8 MiB，并估算元数据开销。大选择显示经过粗略取整的“粗估”，并标明实际抽样量。样本偏向较大文件，误差未经过标定，不能据此保证最终大小。估算在后台进行，切换设置或开始任务会取消旧估算。\n\n文件字节、名称、已有隐藏文件和目录层级保持原样，不生成额外附带文件。符号链接按链接本身保留，TAR 硬链接按相同字节内容还原。成功通过内容校验后才发布正式结果，失败或取消会清理临时内容。\n\n请将压缩包保存在源文件夹之外。文件被打开但仍可读取时可以压缩；真正读取失败、无权限、空间不足或处理中变化时停止。\n\n所有内容在本机处理。Finder 标签、资源叉、扩展属性和完整系统权限不属于备份范围。TAR 本身不含文件内容校验码，不能仅凭外来 TAR 判断其内容是否曾被修改。")
                }.padding(26)
            }
        }.frame(width: 590, height: 590).background(WorkspaceStyle.canvas).tint(WorkspaceStyle.accent)
    }

    private func helpSection(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func chooseInput() {
        if compressing { model.chooseSources() } else { model.chooseArchive() }
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func formatName(_ format: ArchiveFormat) -> String {
        format == .sevenZip ? "7z" : format.rawValue.uppercased()
    }
}

private struct FilePreviewRow: View {
    let item: PreviewItem
    var selected: Bool? = nil
    var partiallySelected = false
    var selectionEnabled = true
    var onSelect: () -> Void = {}
    var onRemove: (() -> Void)? = nil
    @State private var hovering = false
    private var name: String { (item.path as NSString).lastPathComponent }
    private var parent: String { (item.path as NSString).deletingLastPathComponent }
    private var icon: String { item.kind == .directory ? "folder.fill" : item.kind == .symlink ? "link" : "doc.text" }
    private var kind: String {
        if item.kind == .directory { return "文件夹" }
        if item.kind == .symlink { return "链接" }
        let ext = (item.path as NSString).pathExtension
        return ext.isEmpty || ext.count > 5 ? "文件" : ext.uppercased()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let selected {
                Button(action: onSelect) {
                    Image(systemName: selected ? "checkmark.square.fill" : partiallySelected ? "minus.square.fill" : "square")
                        .font(.system(size: 13)).foregroundStyle(selected || partiallySelected ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                        .frame(width: 17, height: 28)
                }.buttonStyle(.plain).disabled(!selectionEnabled)
                    .accessibilityLabel("\(selected ? "取消选择" : "选择") \(item.path)")
            }
            Image(systemName: icon).font(.system(size: 14, weight: .regular))
                .foregroundStyle(item.kind == .directory ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                .frame(width: 29, height: 32)
                .background(WorkspaceStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if !parent.isEmpty && parent != "." {
                    Text(parent).font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).lineLimit(1).truncationMode(.middle)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).help(item.path)
            Text(kind).font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).frame(width: 61, alignment: .leading)
            Text(item.kind == .directory ? "—" : item.size < 1024 ? "\(item.size) B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: item.size), countStyle: .file))
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(WorkspaceStyle.muted).frame(width: 65, alignment: .trailing)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        .frame(width: 22, height: 28).foregroundStyle(WorkspaceStyle.muted)
                }.buttonStyle(.plain).disabled(!selectionEnabled)
                    .help("移出本次压缩，不删除原文件")
                    .accessibilityLabel("移除 \(item.path)")
            }
        }
        .padding(.horizontal, 16).frame(height: 53).background(hovering ? WorkspaceStyle.accent.opacity(0.035) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(WorkspaceStyle.border.opacity(0.55)).frame(height: 0.5).padding(.leading, 55) }
        .onHover { hovering = $0 }.accessibilityElement(children: .combine)
    }
}

private struct WorkspacePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 15).frame(height: 38)
            .foregroundStyle(enabled ? WorkspaceStyle.onAccent : WorkspaceStyle.muted.opacity(0.55))
            .background(enabled ? WorkspaceStyle.accent.opacity(configuration.isPressed ? 0.82 : 1) : WorkspaceStyle.sidebar.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(enabled ? .clear : WorkspaceStyle.border.opacity(0.7), lineWidth: 0.7))
    }
}
