import SwiftUI
import AppKit

/// Global connections live here; per-area source grants are managed on the materials page.
struct KnowledgeSettings: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showLocations = false
    @State private var showInventory = false
    @State private var issue: String?
    @State private var notesURL: URL?
    @State private var repositoryAvailable = false
    @State private var connectionIssue: String?
    private var currentArea: Area? { store.materialsSettingsArea }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.coMind == nil { connectionPrompt } else { materialsShortcut }
                VStack(alignment: .leading, spacing: 10) {
                    Text("内容保存在哪里").font(CockpitTypography.section)
                    VStack(spacing: 0) {
                        locationRow("我的笔记", detail: "个人资料与长期记录 · Obsidian", symbol: "book.closed",
                                    status: notesURL == nil ? "未连接" : "已连接", available: notesURL != nil)
                        separator
                        locationRow("CoMind", detail: "AI 协作规则、Skills 与执行工具", symbol: "point.3.connected.trianglepath.dotted",
                                    status: store.coMind == nil ? "未连接" : repositoryAvailable ? "已连接" : "需检查", available: repositoryAvailable)
                        separator
                        locationRow("驾驶舱数据", detail: "阵地配置、会话引用与应用资料", symbol: "square.grid.2x2",
                                    status: store.canEdit ? store.storageLabel : "暂不可写", available: store.canEdit)
                    }
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 0.5))
                }
                if let connectionIssue {
                    HStack(alignment: .top, spacing: 12) {
                        Label(connectionIssue, systemImage: "exclamationmark.circle")
                            .font(CockpitTypography.caption).foregroundStyle(theme.emphasis)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("重新检查") { inspectConnection() }.buttonStyle(QuietButton())
                    }
                }
                if let issue {
                    Text(issue).font(CockpitTypography.caption).foregroundStyle(theme.emphasis)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Button { showLocations.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showLocations ? "chevron.down" : "chevron.right").frame(width: 12)
                            Text("位置与高级选项")
                            Spacer()
                            if !showLocations { Text("路径、连接与旧数据").foregroundStyle(theme.muted) }
                        }.font(CockpitTypography.caption).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(InteractiveButton()).accessibilityValue(showLocations ? "已展开" : "已折叠")
                    if showLocations { advancedOptions }
                }
            }.padding(2).padding(.trailing, 4)
        }
        .frame(height: 430)
        .task(id: store.coMind?.repository.path) { inspectConnection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in inspectConnection() }
        .animation(reduceMotion ? nil : CockpitMotion.presentation, value: showLocations)
        .animation(reduceMotion ? nil : CockpitMotion.presentation, value: showInventory)
    }

    private var materialsShortcut: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("选择聊天使用的资料").font(CockpitTypography.section)
                if let area = currentArea {
                    let sources = store.coMindSources(for: area.id)
                    let selected = store.coMind?.selectedSources(for: area.id) ?? []
                    Caption(text: "\(area.name) · 已关联 \(sources.count) 份 · 用于聊天 \(sources.filter { selected.contains($0.id) }.count) 份")
                } else {
                    Caption(text: "进入一个阵地，在「资料」页选择原笔记并开启「用于聊天」。")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(currentArea == nil ? "查看阵地" : "管理资料") { store.openMaterialsFromSettings() }
                .buttonStyle(PrimaryButton())
        }.padding(16).background(theme.accentSoft.opacity(theme.opacity(0.45)), in: RoundedRectangle(cornerRadius: 12))
    }

    private var connectionPrompt: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("先连接已有资料").font(CockpitTypography.section)
                Caption(text: "选择 CoMind 文件夹，读取其中绑定的 Obsidian 笔记位置。原文件保持原位。")
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("连接 CoMind…") { chooseRoot() }.buttonStyle(PrimaryButton()).disabled(!store.canEdit)
        }.padding(16).background(theme.soft, in: RoundedRectangle(cornerRadius: 12))
    }

    private var separator: some View { theme.border.frame(height: 0.5).padding(.leading, 48) }
    private func locationRow(_ title: String, detail: String, symbol: String, status: String, available: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(CockpitTypography.font(size: 16)).foregroundStyle(theme.muted).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(CockpitTypography.body)
                Caption(text: detail)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(status).font(CockpitTypography.caption).foregroundStyle(available ? theme.muted : theme.emphasis)
        }.padding(14)
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let connection = store.coMind {
                pathRow("CoMind", url: connection.repository)
                if let notesURL { pathRow("我的笔记", url: notesURL) }
                Button("更换 CoMind 位置…") { chooseRoot() }.buttonStyle(QuietButton()).disabled(!store.canEdit)
            }
            pathRow("驾驶舱数据", url: store.storageURL)
            Caption(text: "连接位置不会搬迁文件。聊天只读取你在阵地中启用的资料，发送前重新读取。")
            separator
            Button { showInventory.toggle() } label: {
                HStack {
                    Label("旧数据与归属清单", systemImage: "archivebox")
                    Spacer()
                    Image(systemName: showInventory ? "chevron.down" : "chevron.right")
                }.font(CockpitTypography.caption).padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(InteractiveButton()).accessibilityValue(showInventory ? "已展开" : "已折叠")
            if showInventory {
                let snapshot = store.snapshot()
                Caption(text: "\(snapshot.employeeMemories?.count ?? 0) 条旧版历史条目 · \(snapshot.employeeProfiles?.count ?? 0) 份员工配置 · \(snapshot.progressReports?.count ?? 0) 份进展")
                Caption(text: "这里只核对归属，不自动迁移或恢复内容。个人长期信息以原笔记为准。")
                ForEach(KnowledgeInventory.rows(snapshot)) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        let areaName = (store.areas + store.archivedAreas).first { $0.id == item.areaID }?.name ?? "未归类"
                        Text(areaName + " · " + item.kind + " · " + item.state).font(CockpitTypography.caption)
                        Caption(text: item.destination)
                    }.padding(.vertical, 5)
                }
                if !store.knowledge.isEmpty { Caption(text: "旧版文件包仍兼容读取；可在「恢复」页查看其版本。") }
                Button("导出完整归属清单…") { exportInventory() }.buttonStyle(QuietButton())
            }
        }.padding(14).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
    }

    private func pathRow(_ title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(CockpitTypography.body)
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(OutlinedButton())
            }
            Text(url.path).font(CockpitTypography.caption).foregroundStyle(theme.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inspectConnection() {
        notesURL = nil; connectionIssue = nil; repositoryAvailable = false
        guard let connection = store.coMind else { return }
        do {
            try CoMindFiles.validateRoot(connection.repository)
            repositoryAvailable = true
            notesURL = try KnowledgeSourceLocator.notesRoot(connection.repository)
            if notesURL == nil { connectionIssue = "CoMind 尚未绑定「我的笔记」。请先完成笔记来源绑定，再到阵地关联文件。" }
        } catch { connectionIssue = error.localizedDescription }
    }
    private func chooseRoot() {
        let panel = NSOpenPanel(); panel.title = "连接已有 CoMind"; panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.connectCoMind(url); issue = nil; inspectConnection() } catch { issue = error.localizedDescription }
        }
    }
    private func exportInventory() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "知识归属清单.md"
        if panel.runModal() == .OK, let url = panel.url {
            do { try KnowledgeInventory.markdown(store.snapshot()).write(to: url, atomically: true, encoding: .utf8); store.notify("归属清单已导出，未迁移数据") } catch { issue = error.localizedDescription }
        }
    }
}
