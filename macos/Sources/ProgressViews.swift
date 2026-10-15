import SwiftUI

struct AreaProgressView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    let area: Area
    private var links: [String] { store.threadLinks.filter { $0.areaID == area.id }.map(\.threadID) }
    private var busy: Bool { store.reviewingAreas.contains(area.id) }
    private var report: AreaProgressReport? { store.progressReports[area.id] }
    private var key: String { area.id + area.name + area.purpose + links.sorted().joined() + store.captures.filter { $0.areaID == area.id }.map { $0.id.uuidString + $0.text }.joined() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SectionHeading(title: "AI 进展")
                Spacer()
                Button(busy ? "正在整理…" : "检查更新") { store.requestReview(area.id) }.buttonStyle(QuietButton()).disabled(busy)
            }
            Caption(text: store.employeeProfile(for: area.id).autoReview
                    ? "自动更新会合并变化：安静 10 分钟后整理，两次至少间隔 30 分钟。点击「检查更新」可立即检查；没有变化不调用模型。"
                    : "自动进展已关闭。点击「检查更新」可手动整理；没有变化不调用模型。")
            if store.progressSchedules[area.id]?.changedAt != nil && !busy && store.employeeProfile(for: area.id).autoReview { Caption(text: "有新变化，等待合并更新 · 需保持驾驶舱运行，退出后下次打开接续。") }
            if store.coMind?.prefersOriginals(for: area.id) == true {
                Caption(text: "这里是会话与随手记的阶段总结，未与原笔记自动核对。聊天会重新读取所选原笔记，不再自动携带这些摘要。")
            }
            if busy { HStack { ProgressView().progressViewStyle(CockpitProgressStyle()); Text("正在整理阶段进展…").font(CockpitTypography.caption) } }
            if let error = store.reviewErrors[area.id] { Text(error).font(CockpitTypography.caption).foregroundStyle(theme.emphasis); if report != nil { Caption(text: "以下保留上次成功生成的进展。") } }
            if let report {
                Caption(text: "AI 总结 · " + report.generatedAt.formatted(date: .abbreviated, time: .shortened) + " · 可点击来源核对")
                section("当前状态", icon: "scope", items: report.content.current, report: report)
                section("已完成", icon: "checkmark.circle", items: report.content.completed, report: report)
                section("下一步", icon: "arrow.right.circle", items: report.content.next, report: report)
                section("待确认", icon: "questionmark.circle", items: report.content.uncertain, report: report)
                Caption(text: report.coverage)
            } else if !busy {
                EmptyPanel(icon: "sparkles", title: "进展由 AI 整理", detail: "关联一段有内容的会话，或留下随手记，AI 会根据这些记录整理当前状态与下一步。")
            }
        }
        .task(id: key) { store.requestReview(area.id, automatically: true) }
    }

    private func section(_ title: String, icon: String, items: [ProgressItem], report: AreaProgressReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(CockpitTypography.section).foregroundStyle(theme.emphasis)
            if items.isEmpty { Caption(text: "暂无明确记录") }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.text).font(CockpitTypography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    ForEach(item.sources, id: \.self) { id in
                        if let source = report.sources.first(where: { $0.id == id }) {
                            Button {
                                store.openProgressSource(source, area: area.id)
                            } label: { Label(source.title, systemImage: "arrow.up.right").font(CockpitTypography.caption).lineLimit(1) }.buttonStyle(InteractiveButton()).foregroundStyle(theme.muted)
                        }
                    }
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CaptureEditor: View {
    @EnvironmentObject var store: AppStore
    @State private var text = ""
    @State private var confirmingDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CockpitEditor(title: "随手记", text: $text)
            Caption(text: "修改后，AI 将在下次进入进展页时重新核对内容。")
            if confirmingDelete { Caption(text: "删除这条随手记？已发送到会话中的文字不会被删除。") }
            HStack {
                Button(confirmingDelete ? "确认删除" : "删除记录…") {
                    if confirmingDelete, let id = store.editingCaptureID { store.deleteCapture(id) }
                    else { confirmingDelete = true }
                }.buttonStyle(QuietButton())
                Spacer()
                Button("取消") { store.sheet = nil }.buttonStyle(QuietButton())
                Button("保存修改") { if let id = store.editingCaptureID { store.editCapture(id, text: text) } }.buttonStyle(PrimaryButton()).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.onAppear { text = store.captures.first { $0.id == store.editingCaptureID }?.text ?? "" }
    }
}
