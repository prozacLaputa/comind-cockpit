import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.flushAllWork() == false {
            store?.settingsTab = "恢复"; store?.sheet = .theme
            store?.notify("还有未保存的修改，已打开恢复入口"); return .terminateCancel
        }
        return .terminateNow
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct CoMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    @AppStorage("cockpit.theme") private var themeID = "terracotta"
    @AppStorage(ChatTypography.preferenceKey) private var chatFontSize = ChatTypography.defaultSize
    var body: some Scene {
        WindowGroup("CoMind · 个人驾驶舱", id: "main") {
            CockpitView().onAppear { delegate.store = store }.environment(\.chatTypography, ChatTypography(size: chatFontSize)).environmentObject(store).environment(\.cockpitTheme, ThemeRegistry.resolve(themeID)).preferredColorScheme(ThemeRegistry.resolve(themeID).dark ? .dark : .light).frame(minWidth: 960, minHeight: 680)
        }.defaultSize(width: 1180, height: 800).windowStyle(.titleBar).windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建阵地…") { store.sheet = .area }.keyboardShortcut("n", modifiers: .command)
                Button("记录到原笔记…") { store.openOriginalCapture() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("打开本地文件…") { store.chooseLocalFile() }.keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("前往") {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in Button(page.rawValue) { store.navigate(page) }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) }
                Divider()
                Button("记录想法") { store.focusCapture = true }.keyboardShortcut("k", modifiers: .command)
                Button("统一搜索…") { store.sheet = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) { Button("设置…") { store.sheet = .theme }.keyboardShortcut(",", modifiers: .command) }
        }
    }
}
