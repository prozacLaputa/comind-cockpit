import SwiftUI
import AppKit

struct StorageWarningBanner: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    var body: some View {
        if store.hasSaveProblems {
            HStack(alignment: .top) {
                Label("部分修改尚未保存，当前输入仍保留", systemImage: "exclamationmark.circle")
                Spacer()
                Button("处理保存问题") { store.settingsTab = "恢复"; store.sheet = .theme }.buttonStyle(QuietButton())
            }.font(CockpitTypography.caption).foregroundStyle(theme.emphasis).padding(10)
                .background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct StorageRecoveryPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @State private var copies: [WorkRecoveryCopy] = []
    @State private var issue: String?
    @State private var selected: WorkRecoveryCopy?
    @State private var savedDrafts: [String: String] = [:]
    @State private var confirmRepair = false
    @State private var indexRestore: WorkRecoveryCopy?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("保存与工作草稿", systemImage: "externaldrive.badge.checkmark").font(CockpitTypography.section)
            Caption(text: "这里处理尚未保存的输入和应用数据。原笔记正文及其历史仍在原文件旁，恢复不会覆盖笔记。")
            if let warning = store.storageWarning ?? store.composerWarning { Text(warning).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
            if store.hasSaveProblems {
                HStack {
                    Button("重试保存") { run { if !store.flushAllWork() { throw CoMindFiles.failure("仍未保存，请保留副本并读取最新数据") } } }.buttonStyle(OutlinedButton())
                    Button("保留副本并读取最新数据") { run { try store.reloadSavedWork() } }.buttonStyle(PrimaryButton())
                }
                if !store.composerWritable {
                    Button("修复不可读的草稿文件…") { confirmRepair.toggle() }.buttonStyle(QuietButton())
                    if confirmRepair {
                        Caption(text: "先保留不可读原文件和当前工作副本，再恢复当前草稿的保存。不会清空笔记或主索引；等待下载的文件不会被替代。")
                        HStack { Button("取消") { confirmRepair = false }.buttonStyle(QuietButton()); Button("保留原件并修复") { run { try store.repairUnreadableComposer(); confirmRepair = false } }.buttonStyle(OutlinedButton()) }
                    }
                }
            } else { Caption(text: "当前没有保存错误。") }
            if store.noteSeed != nil {
                HStack {
                    Button("继续保存摘录") { store.sheet = .note }.buttonStyle(OutlinedButton())
                    Button("放弃待保存摘录") { store.noteSeed = nil; _ = store.saveComposerState() }.buttonStyle(QuietButton())
                }
            }
            if !store.editorReferences.isEmpty {
                Text("未完成的笔记编辑").font(CockpitTypography.body)
                ForEach(Array(store.editorReferences.values).sorted { $0.id < $1.id }) { reference in
                    Button { store.resumeEditingDraft(reference) } label: { Label(reference.source.path, systemImage: "square.and.pencil").lineLimit(1) }.buttonStyle(QuietButton())
                }
            }
            if !copies.isEmpty {
                Text("工作恢复副本").font(CockpitTypography.body)
                ForEach(copies.prefix(8)) { copy in
                    HStack {
                        Text(copy.date.formatted(date: .abbreviated, time: .shortened)).font(CockpitTypography.caption)
                        Spacer()
                        Button("查看草稿") {
                            do {
                                let value = try JSONDecoder().decode(ComposerState.self, from: Data(contentsOf: copy.url.appendingPathComponent("composer-state.json")))
                                savedDrafts = value.drafts.filter { !$0.value.isEmpty }
                                for item in value.pending ?? [] { savedDrafts["待发送 · " + item.id.uuidString] = item.text }
                                selected = copy; issue = nil
                            } catch { issue = error.localizedDescription }
                        }.buttonStyle(QuietButton())
                        Button("恢复索引…") { indexRestore = copy }.buttonStyle(QuietButton())
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([copy.url]) }.buttonStyle(QuietButton())
                    }
                }
            }
            if let copy = indexRestore {
                Caption(text: "恢复此时间的阵地、关联和应用设置，不替换任何原笔记。当前状态会先留存；聊天草稿单独找回。")
                HStack {
                    Button("取消") { indexRestore = nil }.buttonStyle(QuietButton())
                    Button("保留当前状态并恢复索引") { run { try store.restoreAppIndex(from: copy); indexRestore = nil } }.buttonStyle(OutlinedButton())
                }
            }
            if let selected {
                Caption(text: "找回只填入空的输入框；冲突的文字可在这里复制，不会覆盖当前草稿或自动发送。")
                ForEach(savedDrafts.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .top) {
                        Text(savedDrafts[key] ?? "").font(CockpitTypography.caption).lineLimit(4).textSelection(.enabled)
                        Spacer()
                        Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(savedDrafts[key] ?? "", forType: .string); store.notify("已复制") }.buttonStyle(QuietButton())
                    }.padding(8).background(theme.soft, in: RoundedRectangle(cornerRadius: 8))
                }
                Button("找回到空输入框") { run {
                    let conflicts = try store.recoverDrafts(from: selected)
                    if !conflicts.isEmpty { issue = "有 \(conflicts.count) 处现有草稿不同，已保留两份，请在上方复制需要的内容。" }
                    else { store.notify("草稿已找回，待发送消息保持暂停") }
                } }.buttonStyle(OutlinedButton())
            }
            if let issue { Text(issue).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
        }.disabled(store.recoveryBusy).onAppear { copies = store.recoveryCopies() }
    }
    private func run(_ work: () throws -> Void) {
        issue = nil
        do { try work(); copies = store.recoveryCopies() } catch { issue = error.localizedDescription }
    }
}
