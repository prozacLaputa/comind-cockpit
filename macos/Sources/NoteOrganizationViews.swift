import SwiftUI

struct NoteWritebackStrip: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    let area: String
    private var targets: Set<UUID> { store.defaultWritebackSources(area: area) }
    private var enabled: Bool { store.noteWritebackPolicies[area]?.enabled == true && !targets.isEmpty }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: enabled ? "checkmark.arrow.trianglehead.counterclockwise" : "doc.badge.gearshape").foregroundStyle(theme.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text(enabled ? "自动整理已开启" : "默认写回笔记").font(CockpitTypography.body)
                Caption(text: enabled ? "每晚一次 · \(targets.count) 份原笔记 · 不确定的集中核对" : (targets.isEmpty ? "设置一次，后续的新信息自动归拢" : "已保存 \(targets.count) 份默认笔记 · 自动整理关闭"))
            }
            Spacer(minLength: 8)
            Button(targets.isEmpty ? "设置" : "管理") { store.noteActionArea = area; store.sheet = .noteWriteback }.buttonStyle(OutlinedButton())
        }.padding(12).background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 0.5))
    }
}

struct NoteWritebackSettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: Set<UUID> = []
    @State private var enabled = false
    @State private var issue: String?
    @State private var sources: [NoteWritebackTarget] = []
    @State private var loading = true
    @State private var saving = false
    private var area: String { store.noteActionArea }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Caption(text: "为「\(store.areaName(area))」选择默认原笔记（最多 5 份）。只保存到这些已有文件，不再每次选位置。")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sources) { source in
                        Toggle(source.title, isOn: Binding(get: { selected.contains(source.id) }, set: { value in if value { selected.insert(source.id) } else { selected.remove(source.id) } })).toggleStyle(CockpitToggleStyle())
                    }
                    if loading { HStack { CockpitSpinner(); Caption(text: "正在核对原文件；如有系统访问提示，请先处理。") } }
                    else if sources.isEmpty { Caption(text: "请先到资料页关联已有主题笔记；日记、插件和协作规则不在此列。") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.frame(maxHeight: 200)
            Toggle("每天自动整理新信息", isOn: $enabled).toggleStyle(CockpitToggleStyle())
            Caption(text: "由 Codex 现有的每晚 22:00 任务执行，无需一直打开驾驶舱。只处理开启或更换设置后的新增对话，空闲满 10 分钟再整理；不会每条消息调用模型。积压较多时分天处理。")
            Caption(text: "明确自述和决定自动增量写回；推断、歧义和冲突留在同页待核对。保留原会话和修改历史。开启后授权按此范围整理，可随时关闭；用于聊天的开关仍分别控制。")
            if let issue { Caption(text: issue) }
            HStack {
                Button("取消") { store.sheet = nil }.buttonStyle(QuietButton())
                Spacer()
                Button(saving ? "保存中…" : "保存设置") {
                    saving = true
                    Task {
                        do {
                            try await store.saveWritebackPolicy(area: area, sources: selected, enabled: enabled)
                            store.sheet = nil; store.notify(enabled ? "已开启每日自动整理" : "默认写回设置已保存")
                        } catch { issue = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(PrimaryButton()).disabled(saving || (enabled && (loading || selected.isEmpty)) || selected.count > 5 || !store.canEdit)
            }
        }.task {
            selected = store.defaultWritebackSources(area: area)
            enabled = store.noteWritebackPolicies[area]?.enabled == true
            do { sources = try await store.eligibleWritebackSources(area: area) }
            catch { issue = error.localizedDescription }
            loading = false
        }
    }
}

struct OrganizationResultsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let area: String
    @State private var expanded = false
    @State private var refreshing = false
    private var runs: [NoteOrganization] { store.noteOrganizations.filter { $0.area == area && $0.belongs(to: store.coMind?.repository) }.reversed() }
    private var key: String { runs.map { $0.id + $0.state }.joined() + store.coMindSources(for: area).map { store.originalStates[$0.id]?.fingerprint ?? "" }.joined() }
    var body: some View {
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("整理结果", systemImage: "checklist").font(CockpitTypography.section)
                    Spacer()
                    if runs.count > 1 {
                        Button(expanded ? "收起历史" : "历史 · \(runs.count)") { expanded.toggle() }.buttonStyle(QuietButton())
                    }
                    Button { Task { await refresh() } } label: {
                        if refreshing { CockpitSpinner() } else { Image(systemName: "arrow.clockwise") }
                    }.buttonStyle(QuietButton()).help("核对原件与整理回执，不调用 AI").accessibilityLabel("刷新整理结果").disabled(refreshing)
                }
                ForEach(Array(runs.prefix(expanded ? runs.count : 1))) { run in
                    OrganizationResultCard(run: run)
                }
            }.animation(reduceMotion ? nil : CockpitMotion.presentation, value: expanded)
                .task(id: key) { await refresh() }
        }
    }
    private func refresh() async { refreshing = true; await store.refreshOrganizationResults(area: area); refreshing = false }
}

private struct OrganizationResultCard: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    let run: NoteOrganization
    private var receipt: OrganizationReceipt? { store.organizationReceipts[run.id] }
    private var running: Bool { run.state == "running" && store.codex.runningThreadID == run.thread }
    private var status: String {
        if running { return "正在整理" }
        if receipt?.complete == true { return "本次范围已整理" }
        if receipt?.targets.contains(where: \.verifiedWrite) == true { return "部分写回，仍有未完成项" }
        return "结果待核实"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if running { CockpitSpinner() }
                else { Image(systemName: receipt?.complete == true ? "checkmark.circle" : "circle.dashed").foregroundStyle(theme.emphasis) }
                Text(status).font(CockpitTypography.body)
                if run.automatic == true { Caption(text: "自动整理") }
                Spacer()
                Caption(text: run.started.formatted(date: .abbreviated, time: .shortened))
            }
            if let receipt {
                Caption(text: receipt.coverage)
                ForEach(receipt.targets) { target in targetRow(target) }
                if !receipt.complete && !running { Caption(text: "没有完整成功回执，不会自动重发或重写。已验证的写回仍保留，可从原会话继续核对。") }
            } else { Caption(text: store.organizationErrors[run.id] ?? "正在读取本次回执…") }
            HStack {
                Button("回到来源会话") { openThread() }.buttonStyle(QuietButton())
                Spacer()
                if store.coMindSources(for: run.area).contains(where: { store.pendingNoteCount($0) > 0 }) {
                    Button("核对原笔记") { store.noteActionArea = run.area; store.sheet = .reviewNotes }.buttonStyle(OutlinedButton())
                }
            }
        }.padding(14).background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border.opacity(0.7), lineWidth: 1))
    }
    private func targetRow(_ target: OrganizationReceipt.Target) -> some View {
        let source = store.organizationSource(target, run: run)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "doc.text").foregroundStyle(theme.muted)
                Text(URL(fileURLWithPath: target.path).deletingPathExtension().lastPathComponent).font(CockpitTypography.body).lineLimit(1)
                Spacer()
                Caption(text: target.label)
                if let source {
                    if target.verifiedWrite {
                        Button("查看差异") { store.noteComparisonRunID = run.id; store.editingCoMindSource = source; store.sheet = .noteChanges }.buttonStyle(QuietButton())
                    }
                    Button("原文") { store.openCoMindSource(source) }.buttonStyle(QuietButton())
                }
            }
            if target.verified == true && target.current_matches == false { Caption(text: "写回之后原件又有变化，后续聊天以当前原文为准。") }
            HStack {
                Caption(text: store.organizationChatLabel(target, run: run))
                Spacer()
                if let source, store.coMind?.selectedSources(for: run.area).contains(source.id) != true {
                    Button("用于后续聊天") {
                        do { try store.setCoMindChatSource(source.id, area: run.area, enabled: true) }
                        catch { store.notify(error.localizedDescription) }
                    }.buttonStyle(OutlinedButton())
                }
            }
            if let source, store.pendingNoteCount(source) > 0 { Caption(text: "原文仍有 \(store.pendingNoteCount(source)) 项待核对，不能作为已确认事实。") }
        }.padding(.vertical, 5)
    }
    private func openThread() {
        store.openArea(run.area)
        Task {
            await store.codex.resolveLinks([run.thread])
            if let thread = store.codex.threadMap[run.thread] { store.lastAreaThread[run.area] = run.thread; await store.codex.read(thread) }
            else { store.notify("来源会话暂不可用，原笔记与回执仍保留。") }
        }
    }
}
