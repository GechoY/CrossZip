import SwiftUI
import AppKit
import CrossZipCore

@main
struct CrossZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup("CrossZip") {
            MainView(model: model)
                .frame(minWidth: 940, minHeight: 670)
                .onOpenURL { model.receive([$0]) }
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    PreviewCapture.startIfRequested(model: model)
                }
        }
        .defaultSize(width: 1180, height: 800)
        .commands { CrossZipCommands(model: model) }
    }
}

@MainActor
private struct CrossZipCommands: Commands {
    @ObservedObject var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加文件或文件夹…", action: model.chooseSources)
                .keyboardShortcut("o").disabled(model.isBusy)
            Button("打开压缩包…", action: model.chooseArchive)
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.isBusy)
        }
        CommandGroup(replacing: .help) {
            Button("CrossZip 使用说明") { model.showHelp = true }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel = {
        if CommandLine.arguments.contains("--capture-preview") {
            let defaults = UserDefaults(suiteName: "local.echo.CrossZip.VisualTests")!
            defaults.removePersistentDomain(forName: "local.echo.CrossZip.VisualTests")
            return AppModel(defaults: defaults, estimatesEnabled: true)
        }
        return AppModel(estimatesEnabled: true)
    }()
    private lazy var finderService = FinderCompressionService(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The model already exists, including when macOS launches us for a service.
        NSApplication.shared.servicesProvider = finderService
        if CommandLine.arguments.contains("--register-finder-service") { NSUpdateDynamicServices() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasBackgroundWork else { return .terminateNow }
        model.cancelForTermination { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
