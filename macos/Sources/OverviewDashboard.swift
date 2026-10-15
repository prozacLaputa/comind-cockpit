import SwiftUI

/// A result-oriented home: derived from existing records, with no automatic AI work.
struct OverviewDashboard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 1000
    @State private var scope = ""
    @State private var showAllResults = false
    @State private var showFinishedActions = false
    @State private var expandedAttention: Set<String> = []

    private var areas: [Area] { store.areas.filter { scope.isEmpty || $0.id == scope } }
    private var ordered: [Area] {
        areas.sorted {
            let lhs = store.progressReports[$0.id]?.generatedAt ?? .distantPast
            let rhs = store.progressReports[$1.id]?.generatedAt ?? .distantPast
            return lhs == rhs ? $0.createdAt < $1.createdAt : lhs > rhs
        }
    }
    private func pending(_ area: Area) -> Int { store.employeeMemories.filter { $0.areaID == area.id && $0.state == .pending }.count }
    private func attentionCount(_ area: Area) -> Int {
        (pending(area) > 0 ? 1 : 0) + (store.reviewErrors[area.id] != nil ? 1 : 0) + (store.progressReports[area.id]?.content.uncertain.count ?? 0)
    }
    private var attention: [Area] { ordered.filter { attentionCount($0) > 0 } }
    private var next: [Area] { ordered.filter { !(store.progressReports[$0.id]?.content.next.isEmpty ?? true) } }
    private var results: [Area] { ordered.filter { !(store.progressReports[$0.id]?.content.completed.isEmpty ?? true) } }
    private var captures: [CaptureRecord] { store.captures.filter { scope.isEmpty || $0.areaID == scope } }
    private var newest: Date? { areas.compactMap { store.progressReports[$0.id]?.generatedAt }.max() }
    private var columns: Int { width >= 1000 ? 4 : width >= 680 ? 3 : width >= 440 ? 2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            if store.areas.isEmpty {
                EmptyPanel(icon: "square.stack.3d.up", title: "从第一个阵地开始", detail: "让每一个长期关注的主题，都有一个可以随时继续的地方。")
            } else {
                metrics
                areaShelf
                EmployeeSetupOverview()
                if width >= 820 {
                    HStack(alignment: .top, spacing: 20) {
                        attentionPanel.frame(maxWidth: .infinity)
                        nextPanel.frame(width: (width - 20) * 0.43)
                    }
                } else {
                    attentionPanel
                    nextPanel
                }
                resultsPanel
                if !captures.isEmpty { capturesPanel }
                HStack(spacing: 6) {
                    if !store.reviewingAreas.isEmpty { CockpitSpinner(); Text("正在整理 \(store.reviewingAreas.count) 个阵地") }
                    else { Image(systemName: "sparkles"); Text("来自各阵地最近一次 AI 整理，点开可核对来源。") }
                    Spacer(minLength: 4)
                    if let newest { Text("最近整理 \(newest.formatted(.dateTime.month().day().hour().minute()))") }
                }.font(CockpitTypography.font(size: 10)).foregroundStyle(theme.muted)
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, value in if abs(width - value) > 1 { width = value } }
        })
        .animation(reduceMotion ? nil : CockpitMotion.presentation, value: scope)
        .animation(reduceMotion ? nil : CockpitMotion.presentation, value: showAllResults)
        .animation(reduceMotion ? nil : CockpitMotion.presentation, value: expandedAttention)
        .onChange(of: store.areas.map(\.id)) { _, ids in if !scope.isEmpty && !ids.contains(scope) { scope = "" } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("工作总览").font(CockpitTypography.title(22))
                Text("看清进展，接着往前。").font(CockpitTypography.font(size: 12)).foregroundStyle(theme.muted)
            }
            Spacer(minLength: 8)
            if !store.areas.isEmpty {
                CockpitSelect(title: "筛选阵地", selection: $scope,
                              options: [.init(id: "", label: "全部阵地", symbol: "square.grid.2x2")] + store.areas.map { .init(id: $0.id, label: $0.name, symbol: $0.symbol) }, showsLabel: false).frame(width: 165)
            }
            Button { store.sheet = .area } label: { Label("新建阵地", systemImage: "plus") }.buttonStyle(QuietButton())
        }
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric("长期阵地", value: areas.count, unit: "个", symbol: "square.grid.2x2")
            separator
            metric("旧条目待核对", value: areas.reduce(0) { $0 + pending($1) }, unit: "条", symbol: "brain", emphasized: !attention.isEmpty)
            separator
            metric("可以继续", value: next.count, unit: "个阵地", symbol: "arrow.up.right")
            separator
            metric("关联会话", value: Set(store.threadLinks.filter { scope.isEmpty || $0.areaID == scope }.map(\.threadID)).count, unit: "个", symbol: "bubble.left.and.bubble.right")
        }.padding(.vertical, 18)
            .modifier(DashboardModuleSurface())
    }
    private var separator: some View { theme.border.opacity(theme.opacity(0.7)).frame(width: 0.5, height: 38) }
    private func metric(_ title: String, value: Int, unit: String, symbol: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(CockpitTypography.font(size: 11)).foregroundStyle(theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(value)").font(CockpitTypography.font(size: 25, weight: .regular, design: .rounded)).monospacedDigit().foregroundStyle(emphasized && value > 0 ? theme.emphasis : theme.text)
                Text(unit).font(CockpitTypography.font(size: 10)).foregroundStyle(theme.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, width < 650 ? 12 : 20)
            .accessibilityElement(children: .combine)
    }

    private var areaShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("长期阵地", symbol: "square.stack.3d.up")
                Spacer()
                Button { store.navigate(.areas) } label: { Label("管理阵地", systemImage: "arrow.up.right").font(CockpitTypography.font(size: 11)) }.buttonStyle(InteractiveButton()).foregroundStyle(theme.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: min(columns, max(1, areas.count))), spacing: 12) {
                ForEach(areas) { area in
                    DashboardAreaTile(area: area, threadCount: store.threadLinks.filter { $0.areaID == area.id }.count, pendingCount: pending(area))
                }
            }.animation(reduceMotion ? nil : CockpitMotion.selection, value: areas.map(\.id))
        }.padding(18).modifier(DashboardModuleSurface())
    }

    private var attentionPanel: some View {
        DashboardPanel(title: "需要你处理", subtitle: "历史条目与阶段待确认事项", symbol: "tray", count: attention.count, countUnit: "个阵地") {
            if attention.isEmpty { dashboardEmpty("暂时没有待处理事项", detail: "新的核对项会集中出现在这里。", symbol: "checkmark.circle") }
            else {
                VStack(spacing: 14) {
                    ForEach(attention) { area in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 7) {
                                Image(systemName: area.symbol).foregroundStyle(theme.muted).frame(width: 15)
                                Text(area.name).font(CockpitTypography.font(size: 12, weight: .medium))
                                Spacer(minLength: 6)
                                if pending(area) > 0 {
                                    Button { open(area, tab: "资料") } label: {
                                        Label("\(pending(area)) 条旧记录待核对", systemImage: "brain")
                                            .font(CockpitTypography.font(size: 10)).foregroundStyle(theme.emphasis).padding(.horizontal, 8).padding(.vertical, 5)
                                            .background(theme.accentSoft.opacity(theme.opacity(0.65)), in: Capsule())
                                    }.buttonStyle(InteractiveButton()).help("核对\(area.name)的旧记录")
                                }
                            }
                            if store.reviewErrors[area.id] != nil {
                                DashboardItem(title: "上次整理未完成，查看原因", symbol: "exclamationmark.circle", actionTitle: "查看") { open(area, tab: "资料") }
                            }
                            let items = store.progressReports[area.id]?.content.uncertain ?? []
                            ForEach(Array((expandedAttention.contains(area.id) ? items : Array(items.prefix(1))).enumerated()), id: \.offset) { _, item in
                                DashboardItem(title: item.text, symbol: "questionmark.circle", actionTitle: "核对") { open(area, tab: "进展") }
                            }
                            if items.count > 1 {
                                Button {
                                    if expandedAttention.contains(area.id) { expandedAttention.remove(area.id) } else { expandedAttention.insert(area.id) }
                                } label: {
                                    Label(expandedAttention.contains(area.id) ? "收起" : "还有 \(items.count - 1) 项待确认", systemImage: expandedAttention.contains(area.id) ? "chevron.up" : "chevron.down").font(CockpitTypography.font(size: 10)).padding(.vertical, 3)
                                }.buttonStyle(InteractiveButton()).foregroundStyle(theme.muted)
                            }
                        }
                        if area.id != attention.last?.id { theme.border.opacity(theme.opacity(0.6)).frame(height: 0.5) }
                    }
                }
            }
        }
    }

    private var nextPanel: some View {
        let visible = store.actions.filter { action in areas.contains(where: { $0.id == action.areaID }) && (showFinishedActions || ![ActionState.done, .dismissed].contains(action.state)) }
        return DashboardPanel(title: "接下来", subtitle: "建议与已确认事项分开保留", symbol: "arrow.up.right", count: visible.count, countUnit: "项") {
            VStack(alignment: .leading, spacing: 12) {
                if visible.isEmpty { dashboardEmpty("从一个阵地开始", detail: "AI 提议的下一步会留在这里，新的总结不会覆盖你的选择。", symbol: "arrow.up.right.circle") }
                ForEach(visible) { action in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(store.areaName(action.areaID)).font(CockpitTypography.caption).foregroundStyle(theme.muted)
                            Spacer()
                            Text(action.state.rawValue).font(CockpitTypography.caption).foregroundStyle(theme.accent)
                        }
                        Text(action.text).font(CockpitTypography.body).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("继续") { store.continueAction(action) }.buttonStyle(OutlinedButton())
                            CockpitSelect(title: "事项状态", selection: Binding(get: { action.state.rawValue }, set: { if let state = ActionState(rawValue: $0) { store.feedback(action, state: state) } }), options: ActionState.allCases.map { .init(id: $0.rawValue, label: $0.rawValue) }, showsLabel: false)
                        }
                        if Date().timeIntervalSince(action.seenAt) > 604800 { Caption(text: "超过一周未核对，继续前建议确认现状") }
                        if let last = action.feedback.last { Caption(text: "你的反馈 · " + last.date.formatted(date: .abbreviated, time: .shortened)) }
                        if let source = action.sources.first { Button("查看依据") { store.openProgressSource(source, area: action.areaID) }.buttonStyle(InteractiveButton()).font(CockpitTypography.caption) }
                    }.padding(12).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
                }
                Button(showFinishedActions ? "隐藏已结束事项" : "查看已完成 / 不做的事项") { showFinishedActions.toggle() }.buttonStyle(InteractiveButton()).font(CockpitTypography.caption)
            }
        }
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("近期成果", symbol: "checkmark.circle")
                Text("\(results.count)").font(CockpitTypography.font(size: 10)).foregroundStyle(theme.muted)
                Spacer()
                if results.count > 3 {
                    Button(showAllResults ? "收起" : "查看全部") { showAllResults.toggle() }.buttonStyle(InteractiveButton()).font(CockpitTypography.font(size: 11))
                }
            }
            if results.isEmpty {
                dashboardEmpty("成果会慢慢积累在这里", detail: "只展示已有进展里记录的成果。", symbol: "checkmark.seal")
            } else {
                let shown = showAllResults ? results : Array(results.prefix(3))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: min(width >= 1000 ? 3 : width >= 650 ? 2 : 1, shown.count)), alignment: .leading, spacing: 12) {
                    ForEach(shown) { area in
                        if let item = store.progressReports[area.id]?.content.completed.first {
                            DashboardItem(title: item.text, eyebrow: area.name, symbol: "checkmark.circle", actionTitle: "查看", bordered: true,
                                          footnote: store.progressReports[area.id]?.generatedAt.formatted(.dateTime.month().day().hour().minute())) { open(area, tab: "进展") }
                        }
                    }
                }
            }
        }.padding(18).modifier(DashboardModuleSurface())
    }

    private var capturesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("最近记录", symbol: "book.closed")
            ForEach(Array(captures.prefix(3))) { note in
                DashboardItem(title: note.text, eyebrow: store.areaName(note.areaID), symbol: "text.alignleft", actionTitle: "编辑") {
                    store.editingCaptureID = note.id; store.sheet = .editCapture
                }
            }
        }.padding(18).modifier(DashboardModuleSurface())
    }
    private func sectionLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(CockpitTypography.font(size: 12, weight: .medium)).foregroundStyle(theme.text)
    }
    private func dashboardEmpty(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(CockpitTypography.font(size: 17, weight: .light)).foregroundStyle(theme.muted)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(CockpitTypography.font(size: 12))
                Text(detail).font(CockpitTypography.font(size: 11)).foregroundStyle(theme.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
    }
    private func open(_ area: Area, tab: String) { store.openArea(area.id); store.areaTab = tab }
}

/// Shared shell for top-level modules; inner rows retain the lighter treatment.
private struct DashboardModuleSurface: ViewModifier {
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .background {
                shape.fill(theme.surface)
                    .shadow(color: .black.opacity(theme.binary ? 0 : theme.dark ? 0.16 : 0.035), radius: 7, y: 3)
            }
            .overlay {
                shape.strokeBorder(theme.border.opacity(theme.opacity(contrast == .increased ? 1 : 0.95)),
                                   lineWidth: contrast == .increased ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct DashboardPanel<Content: View>: View {
    @Environment(\.cockpitTheme) private var theme
    var title: String
    var subtitle: String
    var symbol: String
    var count: Int
    var countUnit: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).font(CockpitTypography.font(size: 14)).foregroundStyle(theme.accent).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(CockpitTypography.font(size: 14, weight: .medium))
                    Text(subtitle).font(CockpitTypography.font(size: 10)).foregroundStyle(theme.muted)
                }
                Spacer()
                Text("\(count) \(countUnit)").font(CockpitTypography.font(size: 10)).monospacedDigit().foregroundStyle(theme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 4).background(theme.soft, in: Capsule())
            }
            theme.border.opacity(theme.opacity(0.6)).frame(height: 0.5)
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(DashboardModuleSurface())
    }
}

private struct DashboardItem: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String
    var eyebrow: String? = nil
    var symbol: String
    var actionTitle: String
    var prominent = false
    var bordered = false
    var footnote: String? = nil
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                if let eyebrow {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).foregroundStyle(theme.accent)
                        Text(eyebrow).foregroundStyle(theme.muted)
                        Spacer(minLength: 6)
                        Image(systemName: "arrow.up.right").foregroundStyle(hovered ? theme.accent : theme.muted.opacity(0.55))
                            .offset(x: hovered && !reduceMotion ? 1 : 0, y: hovered && !reduceMotion ? -1 : 0)
                    }.font(CockpitTypography.font(size: 10))
                }
                HStack(alignment: .top, spacing: 7) {
                    if eyebrow == nil { Image(systemName: symbol).font(CockpitTypography.font(size: 11)).foregroundStyle(theme.muted).padding(.top, 2) }
                    Text(title).font(CockpitTypography.font(size: 13)).foregroundStyle(theme.text).lineLimit(bordered ? 3 : 2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    if eyebrow == nil { Image(systemName: "chevron.right").font(CockpitTypography.font(size: 9)).foregroundStyle(hovered ? theme.accent : theme.muted.opacity(0.5)).padding(.top, 3) }
                }
                if prominent || footnote != nil {
                    HStack {
                        if let footnote { Text(footnote) }
                        Spacer()
                        Text(actionTitle).foregroundStyle(hovered ? theme.emphasis : theme.muted)
                    }.font(CockpitTypography.font(size: 10))
                }
            }.padding(eyebrow == nil ? 9 : 12).frame(maxWidth: .infinity, minHeight: bordered ? 120 : nil, alignment: .topLeading)
                .background(hovered ? theme.accentSoft.opacity(theme.opacity(0.5)) : (prominent || bordered ? theme.soft.opacity(theme.opacity(0.55)) : theme.soft.opacity(theme.opacity(0.35))), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(hovered ? theme.accent.opacity(theme.opacity(0.35)) : bordered ? theme.border.opacity(theme.opacity(0.55)) : .clear, lineWidth: 0.5))
        }.buttonStyle(InteractiveButton()).onHover { hovered = $0 }
            .animation(reduceMotion ? nil : CockpitMotion.feedback, value: hovered)
            .help(title).accessibilityLabel((eyebrow.map { $0 + "，" } ?? "") + title).accessibilityHint(actionTitle)
    }
}

private struct DashboardAreaTile: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var area: Area
    var threadCount: Int
    var pendingCount: Int
    @State private var hovered = false
    var body: some View {
        Button { store.openArea(area.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: area.symbol).font(CockpitTypography.font(size: 15)).foregroundStyle(theme.emphasis)
                        .frame(width: 30, height: 30).background(theme.accentSoft.opacity(theme.opacity(0.55)), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(area.name).font(CockpitTypography.font(size: 13, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                        Text(area.purpose.isEmpty ? "一个持续关注的主题" : area.purpose).font(CockpitTypography.font(size: 10)).foregroundStyle(theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Text("\(threadCount) 个会话").foregroundStyle(theme.muted)
                    Spacer(minLength: 4)
                    if pendingCount > 0 { Circle().fill(theme.accent).frame(width: 4, height: 4); Text("待核对").foregroundStyle(theme.emphasis) }
                    Image(systemName: "arrow.up.right").foregroundStyle(hovered ? theme.accent : theme.muted.opacity(0.45))
                        .offset(x: hovered && !reduceMotion ? 1 : 0, y: hovered && !reduceMotion ? -1 : 0)
                }.font(CockpitTypography.font(size: 10))
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? theme.accentSoft.opacity(theme.opacity(0.5)) : theme.soft.opacity(theme.opacity(0.55)), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(hovered ? theme.accent.opacity(theme.opacity(0.35)) : theme.border.opacity(theme.opacity(0.65)), lineWidth: 0.5))
                .shadow(color: .black.opacity(hovered && !theme.binary ? (theme.dark ? 0.1 : 0.035) : 0), radius: 8, y: 3)
                .modifier(AreaReorder(id: area.id))
        }.buttonStyle(InteractiveButton()).onHover { hovered = $0 }
            .animation(reduceMotion ? nil : CockpitMotion.feedback, value: hovered)
            .contextMenu {
                Button("重命名与编辑…", systemImage: "square.and.pencil") { store.manageArea(area.id) }
                Divider()
                Button("删除阵地…", systemImage: "trash", role: .destructive) { store.confirmAreaDeletion(area.id) }
            }
            .accessibilityLabel("打开\(area.name)")
    }
}
