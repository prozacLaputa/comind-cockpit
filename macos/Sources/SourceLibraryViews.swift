import SwiftUI
import AppKit

struct CoMindSourcesSection: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let areaID: String
    @State private var items: [SourceLibraryItem] = []
    @State private var loading = true
    @State private var refreshed: Date?
    @State private var refreshID = UUID()
    @State private var pendingOnly = false
    @State private var issue: String?
    private var sources: [CoMindSource] { store.coMindSources(for: areaID) }
    private var selected: Set<UUID> { store.coMind?.selectedSources(for: areaID) ?? [] }
    private var refreshKey: String { areaID + (store.coMind?.repository.path ?? "") + sources.map { $0.id.uuidString + $0.path }.joined() + sources.map { store.originalStates[$0.id]?.fingerprint ?? "" }.joined() + refreshID.uuidString }
    private func pendingCount(_ item: SourceLibraryItem) -> Int {
        guard store.originalStates[item.id]?.fingerprint == item.fingerprint else { return item.reviews.count }
        return store.pendingNoteCount(item.source)
    }
    private var pendingFiles: Int { items.filter { pendingCount($0) > 0 }.count }
    private var hasDeferred: Bool { items.contains { !$0.reviews.isEmpty && pendingCount($0) == 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("原文件 \(sources.count) 份").font(CockpitTypography.body)
                Text("·").foregroundStyle(theme.muted)
                Text("用于聊天 \(sources.filter { selected.contains($0.id) }.count) 份").font(CockpitTypography.body)
                Spacer(minLength: 0)
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuietButton()).help("重新读取已关联原文件").accessibilityLabel("刷新原文件状态").disabled(loading)
            }
            Caption(text: "开启「用于聊天」后，每次发送前检查最新原文，按问题提供片段；需要更多背景时 AI 补读原件。关联只保存引用，关闭开关不移除已发送的历史内容。")
            if sources.isEmpty {
                EmptyPanel(icon: "book.closed", title: "让聊天了解这个主题", detail: "点击上方「关联原笔记」，选择已有文件，再开启「用于聊天」。")
            } else if loading {
                HStack { CockpitSpinner(); Caption(text: "正在核对已关联原文件…") }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: pendingFiles > 0 ? "text.badge.checkmark" : "doc.text.magnifyingglass").foregroundStyle(theme.muted)
                    Caption(text: pendingFiles > 0 ? "\(pendingFiles) 份原文件需要核对" : (hasDeferred ? "当前没有待处理项，暂留条目仍保留在原文" : "已读取的原文件中未见待核对标记"))
                    Spacer(minLength: 0)
                    if pendingFiles > 0 || pendingOnly {
                        Button(pendingOnly ? "显示全部" : "仅看待核对") { pendingOnly.toggle() }.buttonStyle(QuietButton())
                    }
                }
                ForEach(SourceLibraryGroup.allCases, id: \.self) { group in
                    let grouped = items.filter { $0.group == group && (!pendingOnly || pendingCount($0) > 0 || $0.issue != nil) }
                    if !grouped.isEmpty { section(group, items: grouped) }
                }
                if pendingOnly && pendingFiles == 0 { Caption(text: "没有检测到待核对段落；你可以显示全部原文件。") }
                if items.contains(where: { $0.issue != nil }) { Caption(text: "部分原文件未能读取，其待核对状态未知。请查看对应提示，不会使用旧结果代替。") }
                Caption(text: "待核对入口只定位原文中的明确标记，不自动判断或确认内容。" + (refreshed.map { " 核对于 " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
            }
            if let issue { Text(issue).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
        }
        .task(id: refreshKey) { await inspect() }
        .onChange(of: store.sheet) { _, sheet in if sheet == nil { refreshID = UUID() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshID = UUID() }
        .animation(reduceMotion ? nil : CockpitMotion.presentation, value: pendingOnly)
    }

    private func section(_ group: SourceLibraryGroup, items: [SourceLibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Label(group.rawValue, systemImage: group.symbol).font(CockpitTypography.section); Spacer(); Caption(text: "\(items.count) 份") }
                Caption(text: group.detail)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(theme.soft)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { theme.border.frame(height: 0.5).padding(.horizontal, 14) }
                row(item)
            }
        }.background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 0.5))
    }

    private func row(_ item: SourceLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.group.symbol).foregroundStyle(theme.muted).frame(width: 18).padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(CockpitTypography.body).fixedSize(horizontal: false, vertical: true)
                    Text(item.location).font(CockpitTypography.caption).foregroundStyle(theme.muted).lineLimit(2).help(item.location)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("打开原文") { store.openCoMindSource(item.source) }.buttonStyle(QuietButton())
                Button {
                    do { try store.detachCoMindSource(item.id, area: areaID); issue = nil }
                    catch { issue = error.localizedDescription }
                } label: { Image(systemName: "minus.circle") }.buttonStyle(QuietButton())
                    .help("解除当前阵地的关联，保留原文件").accessibilityLabel("解除关联：" + item.title)
            }
            HStack(spacing: 12) {
                Toggle("用于聊天", isOn: Binding(get: { selected.contains(item.id) }, set: { enabled in
                    do { try store.setCoMindChatSource(item.id, area: areaID, enabled: enabled); issue = nil }
                    catch { issue = error.localizedDescription }
                })).toggleStyle(CockpitToggleStyle()).accessibilityLabel(item.title + "：用于聊天")
                Caption(text: selected.contains(item.id) ? "发送前重读" : "仅关联，未加入背景")
                Spacer(minLength: 0)
                if !item.reviews.isEmpty {
                    Button { store.openCoMindSource(item.source, focusReview: true) } label: {
                        Label(pendingCount(item) > 0 ? "待核对 · \(pendingCount(item)) 项" : "已暂留 · 查看原文", systemImage: pendingCount(item) > 0 ? "text.badge.checkmark" : "clock")
                    }.buttonStyle(OutlinedButton()).help("定位原文中的待核对段落")
                }
            }.font(CockpitTypography.caption)
            if let failure = item.issue {
                Label("状态未知 · " + failure, systemImage: "exclamationmark.circle").font(CockpitTypography.caption).foregroundStyle(theme.emphasis).fixedSize(horizontal: false, vertical: true)
                RelocateOriginalButton(source: item.source) { refreshID = UUID() }
            }
        }.padding(14)
    }

    @MainActor private func inspect() async {
        loading = true; items = []
        guard let connection = store.coMind else { loading = false; return }
        let scope = sources
        let result = await Task.detached(priority: .userInitiated) { scope.map { SourceLibraryItem.inspect($0, repository: connection.repository) } }.value
        guard !Task.isCancelled, store.coMind == connection else { return }
        items = result; refreshed = Date(); loading = false
        store.markSourcesViewed(scope, versions: Dictionary(uniqueKeysWithValues: result.compactMap { item in item.fingerprint.map { (item.id, $0) } }), area: areaID)
    }
}
