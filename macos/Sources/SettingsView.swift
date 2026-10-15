import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CockpitTabs(selection: $store.settingsTab, options: ["外观", "数据", "恢复", "Codex"].map { .init(id: $0, label: $0 == "数据" ? "资料与存储" : $0) })
            switch store.settingsTab {
            case "数据": KnowledgeSettings()
            case "恢复": RecoverySettings()
            case "Codex": CodexRelationshipView(bridge: store.codex)
            default: ThemeSettings()
            }
        }
    }
}


struct RecoverySettings: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @State private var areaID = "__choose_scope__"
    @State private var history: [(String, Date)] = []
    @State private var candidate: String?
    @State private var issue: String?
    private var scopes: [Area] {
        (store.areas + store.archivedAreas + [.init(id: "", name: "未归类资料与全局草稿", purpose: "")]).filter { store.knowledge[$0.id] != nil }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StorageRecoveryPanel()
                Divider()
                AttachmentCleanupSettings()
                Divider()
                Text("原笔记历史").font(CockpitTypography.section)
                Caption(text: "在「资料」打开对应原文件，点击「历史」预览并恢复。修改前的版本与未完成编辑均留在原文件同目录。")
                Button("打开资料") { store.openMaterialsFromSettings() }.buttonStyle(QuietButton())
                Divider()
                Text("已归档阵地").font(CockpitTypography.section)
                if store.archivedAreas.isEmpty { Caption(text: "没有归档阵地") }
                ForEach(store.archivedAreas) { area in
                    HStack { Label(area.name, systemImage: area.symbol); Spacer(); Button("恢复") { store.restoreArea(area.id) }.buttonStyle(QuietButton()) }
                }
                Divider()
                Text("已移除资料").font(CockpitTypography.section)
                if store.discardedDocuments.isEmpty { Caption(text: "回收站为空") }
                ForEach(store.discardedDocuments) { doc in
                    HStack { Text(doc.name).lineLimit(1); Spacer(); Button("恢复") { store.restoreDocument(doc.id) }.buttonStyle(QuietButton()) }
                }
                Divider()
                if !scopes.isEmpty {
                Text("旧版资料存档").font(CockpitTypography.section)
                CockpitSelect(title: "选择知识范围", selection: $areaID, options: [.init(id: "__choose_scope__", label: "请选择")] + scopes.map { .init(id: $0.id, label: $0.name) })
                if let issue { Text(issue).foregroundStyle(theme.emphasis) }
                if candidate != nil {
                    Caption(text: "将恢复这个知识范围的资料、记忆、配置、进展、事项与草稿。当前版本继续保留；Codex 会话不会改变。")
                    HStack {
                        Button("取消") { candidate = nil }.buttonStyle(QuietButton())
                        Button("确认恢复此版本") { if let candidate { store.restoreKnowledge(area: areaID, revision: candidate); self.candidate = nil; reload() } }.buttonStyle(PrimaryButton())
                    }
                }
                ForEach(history, id: \.0) { id, date in
                    HStack {
                        Text(date.formatted(date: .abbreviated, time: .standard)).font(CockpitTypography.caption)
                        Spacer()
                        if store.knowledge[areaID]?.revision == id { Text("当前版本").font(CockpitTypography.caption).foregroundStyle(theme.muted) }
                        else { Button("选择恢复") { candidate = id }.buttonStyle(QuietButton()) }
                    }
                }
                Caption(text: "这里只恢复旧版范围，不替换当前原笔记或聊天草稿。")
                }
            }.padding(2)
        }.frame(height: 430).onChange(of: areaID) { _, _ in candidate = nil; reload() }
    }
    private func reload() {
        issue = nil
        guard let reference = store.knowledge[areaID] else { history = []; return }
        do { history = try KnowledgeVault.history(reference); issue = nil } catch { issue = error.localizedDescription }
    }
}
