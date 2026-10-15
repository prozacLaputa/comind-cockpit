import SwiftUI
import AppKit

struct AreaActivityObserver: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var bridge: CodexBridge
    private var metadataKey: String { bridge.threadMap.values.map { $0.id + String($0.updated.timeIntervalSince1970) }.sorted().joined() }
    private var progressKey: String { store.progressReports.map { $0.key + String($0.value.generatedAt.timeIntervalSince1970) }.sorted().joined() }
    private var linkKey: String { String(bridge.connected) + store.threadLinks.map { $0.areaID + $0.threadID }.sorted().joined() }
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: metadataKey, initial: true) { _, _ in store.observeThreadActivity() }
            .onChange(of: progressKey, initial: true) { _, _ in store.observeThreadActivity(); if store.areaTab == "进展", let area = store.areaID { store.markProgressViewed(area) } }
            .onChange(of: (store.areaID ?? "") + store.areaTab) { _, _ in if store.areaTab == "进展", let area = store.areaID { store.markProgressViewed(area) } }
            .task(id: linkKey) { await bridge.resolveLinks(store.threadLinks.map(\.threadID), refresh: true) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.refreshOriginalActivity()
                Task {
                    await bridge.resolveLinks(store.threadLinks.map(\.threadID), refresh: true)
                    await bridge.refreshVisibleHistory()
                    await store.refreshOrganizationResults()
                    if let area = store.areaID {
                        if store.areaTab == "进展" { store.markProgressViewed(area) }
                        if store.areaTab == "开始工作", !bridge.reading, let thread = bridge.selected,
                           store.threadLinks.contains(where: { $0.areaID == area && $0.threadID == thread.id }) { store.markThreadViewed(thread.id, area: area) }
                    }
                }
            }
    }
}

struct AreaStatusMark: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var bridge: CodexBridge
    @Environment(\.cockpitTheme) private var theme
    let area: String
    private var notice: AreaNotice { store.areaNotice(area) }
    private var label: String {
        switch notice {
        case .working: "正在处理"
        case .attention: "需要你处理：授权、待核对资料或连接状态"
        case .unread: "有未读回复、进展或资料更新"
        case .none: ""
        }
    }
    var body: some View {
        Group {
        if notice != .none {
            Button { store.openAreaNotice(area)
            } label: {
                Group {
                    if notice == .working { CockpitSpinner() }
                    else if notice == .attention { Image(systemName: "circle.dotted").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.emphasis) }
                    else { Circle().fill(theme.accent).frame(width: 6, height: 6) }
                }.frame(width: 20, height: 26).contentShape(Rectangle())
            }.buttonStyle(InteractiveButton()).help(label).accessibilityLabel(store.areaName(area) + " · " + label)
        }
        }
    }
}

struct NoteActivitySection: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let area: String
    @State private var updates: [NoteUpdate] = []
    @State private var issues: [String] = []
    @State private var expanded = false
    @State private var loading = true
    private var key: String { store.coMindSources(for: area).map { $0.id.uuidString + (store.originalStates[$0.id]?.fingerprint ?? "") }.joined() }
    private var pending: Int { store.coMindSources(for: area).map { store.pendingNoteCount($0) }.reduce(0, +) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoteWritebackStrip(area: area)
            OrganizationResultsView(area: area)
            HStack(spacing: 14) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) { Image(systemName: "clock.arrow.circlepath"); Text("最近更新"); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9)) }
                }.buttonStyle(InteractiveButton())
                Caption(text: loading ? "核对中…" : "\(updates.count) 份原笔记有历史")
                Spacer()
                if pending > 0 || store.coMindSources(for: area).contains(where: { source in store.deferredNoteReviews.contains { $0.hasPrefix(source.id.uuidString + ":") } }) {
                    Button { store.noteActionArea = area; store.sheet = .reviewNotes } label: {
                        Label(pending > 0 ? "集中核对 · \(pending)" : "查看暂留", systemImage: "text.badge.checkmark")
                    }.buttonStyle(OutlinedButton())
                }
            }
            if expanded {
                if updates.isEmpty && !loading { Caption(text: "尚无可比较的原件历史。后续写回后会显示在这里。") }
                ForEach(updates.prefix(8)) { update in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text").foregroundStyle(theme.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(update.title).font(CockpitTypography.body)
                            Caption(text: "文件更新于 " + update.date.formatted(date: .abbreviated, time: .shortened))
                        }
                        Spacer()
                        Button("查看改动") { store.noteComparisonRunID = nil; store.editingCoMindSource = update.source; store.sheet = .noteChanges }.buttonStyle(QuietButton())
                    }.padding(.vertical, 5)
                }
                ForEach(issues, id: \.self) { Caption(text: $0) }
                Caption(text: "来自原文件和同目录历史，包含人工与 AI 更新；文件时间不代表事实发生时间。")
            }
        }.padding(14).background(theme.soft, in: RoundedRectangle(cornerRadius: 12))
            .animation(reduceMotion ? nil : CockpitMotion.presentation, value: expanded)
            .task(id: key) { await load(); await store.refreshOrganizationResults(area: area) }
            .onChange(of: store.sheet) { _, value in if value == nil { Task { await load() }; store.refreshOriginalActivity() } }
    }
    private func load() async {
        guard let connection = store.coMind else { loading = false; return }
        loading = true
        let sources = store.coMindSources(for: area)
        let result = await Task.detached(priority: .userInitiated) { () -> ([NoteUpdate], [String]) in
            var values: [NoteUpdate] = [], issues: [String] = []
            for source in sources {
                do {
                    guard try KnowledgeSourceLocator.resolve(source.path, repo: connection.repository) != nil else { continue }
                    if let value = try NoteUpdate.load(source, repository: connection.repository) { values.append(value) }
                } catch { issues.append("部分原件历史暂不可用：" + error.localizedDescription) }
            }
            return (values.sorted { $0.date > $1.date }, Array(Set(issues)))
        }.value
        guard !Task.isCancelled, store.coMind == connection else { return }
        updates = result.0; issues = result.1; loading = false
    }
}

struct NoteChangesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @State private var update: NoteUpdate?
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let update {
                Text(update.title).font(CockpitTypography.section)
                Caption(text: store.noteComparisonRunID == nil ? "当前原文与最近不同版本比较；较长内容仅预览变化区段。" : "本次整理写前与写后版本比较；之后的手动修改不混入本次结果。")
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        let diff = update.difference
                        changeBlock("此前", text: diff.removed.isEmpty ? "（无）" : diff.removed)
                        changeBlock("现在", text: diff.added.isEmpty ? "（无）" : diff.added)
                        if diff.truncated { Caption(text: "变化区段较长，每侧显示前 80 行；请打开原文查看完整内容。") }
                    }
                }.frame(height: 320)
                HStack {
                    Caption(text: "历史与来源保留在原笔记中。")
                    Spacer()
                    Button("打开原文与历史") { store.openCoMindSource(update.source) }.buttonStyle(PrimaryButton())
                }
            } else if let issue { Text(issue).font(CockpitTypography.body) }
            else { HStack { CockpitSpinner(); Caption(text: "读取原件历史…") } }
        }.task {
            guard let source = store.editingCoMindSource, let connection = store.coMind else { issue = "来源已解除关联。"; return }
            do {
                if let id = store.noteComparisonRunID, let run = store.noteOrganizations.first(where: { $0.id == id }), let target = store.organizationReceipts[id]?.targets.first(where: { $0.reference == source.path }) {
                    update = try await Task.detached { try NoteUpdate.organization(target, source: source, repository: connection.repository, date: run.started) }.value
                } else { update = try await Task.detached { try NoteUpdate.load(source, repository: connection.repository) }.value }
                if update == nil { issue = "没有可验证的差异，请打开原文与历史核对。" }
            }
            catch { issue = error.localizedDescription }
        }
    }
    private func changeBlock(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(CockpitTypography.caption).foregroundStyle(theme.muted)
            Text(text).font(CockpitTypography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ReviewDocument: Identifiable {
    let source: CoMindSource
    let version: CoMindFileVersion
    let entries: [NoteReviewEntry]
    let genericMarkers: Bool
    var id: UUID { source.id }
}
struct NoteReviewView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @State private var documents: [ReviewDocument] = []
    @State private var issues: [String] = []
    @State private var loading = true
    @State private var saving = false
    @State private var selected: String?
    @State private var conclusion = ""
    @State private var showBody = false
    @State private var corrections: [Int: String] = [:]
    @State private var showDeferred = false
    @State private var loadedConnection: CoMindConnection?
    private func key(_ doc: ReviewDocument, _ entry: NoteReviewEntry) -> String { doc.id.uuidString + ":" + entry.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "只处理当前阵地已关联原件。填写你的结论后写回；忽略会保留旧记录，暂留不改原文。协作规则仍到原文件审核。")
            Toggle("显示暂留的条目", isOn: $showDeferred).toggleStyle(CockpitToggleStyle())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading { HStack { CockpitSpinner(); Caption(text: "读取原文…") } }
                    if !loading && documents.isEmpty { Caption(text: "当前没有检测到待核对内容。") }
                    ForEach(documents) { doc in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(CoMindFiles.title(doc.source, connection: store.coMind)).font(CockpitTypography.section)
                                Spacer()
                                Button("原文与来源") { store.openCoMindSource(doc.source, focusReview: true) }.buttonStyle(QuietButton())
                            }
                            ForEach(doc.entries.filter { showDeferred || !store.deferredNoteReviews.contains(key(doc, $0)) }) { entry in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(entry.display).font(CockpitTypography.body).textSelection(.enabled)
                                    if selected == key(doc, entry) {
                                        CockpitField(title: "你的确认结论", text: $conclusion, placeholder: "请填写事实、选择或修正后的说法")
                                        Button(showBody ? "收起正文修正" : "正文有旧说法？同步修正…") { showBody.toggle() }.buttonStyle(QuietButton())
                                        if showBody { bodyCorrections(doc) }
                                        if !corrections.isEmpty { Caption(text: "将同时修正正文 \(corrections.count) 处，并保存这一版的完整历史。") }
                                        HStack {
                                            Button("取消") { selected = nil; conclusion = ""; corrections = [:]; showBody = false }.buttonStyle(QuietButton())
                                            Spacer()
                                            Button("确认写回") { resolve(doc, entry, ignore: false) }.buttonStyle(PrimaryButton()).disabled(conclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        }
                                    } else {
                                        HStack {
                                            Button("确认或修正…") {
                                                selected = key(doc, entry); conclusion = ""
                                                let suggested = NoteReview.suggestedBodyLines(entry, text: doc.version.text)
                                                corrections = Dictionary(uniqueKeysWithValues: suggested.map { ($0.line, $0.original) }); showBody = !suggested.isEmpty
                                            }.buttonStyle(OutlinedButton())
                                            Button("忽略") { resolve(doc, entry, ignore: true) }.buttonStyle(QuietButton())
                                            Button(store.deferredNoteReviews.contains(key(doc, entry)) ? "恢复待办" : "暂留") {
                                                let id = key(doc, entry)
                                                if store.deferredNoteReviews.contains(id) { store.deferredNoteReviews.remove(id) } else { store.deferredNoteReviews.insert(id) }
                                                store.persist()
                                            }.buttonStyle(InteractiveButton())
                                        }
                                    }
                                }.padding(12).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
                            }
                            if !showDeferred && !doc.entries.isEmpty && doc.entries.allSatisfy({ store.deferredNoteReviews.contains(key(doc, $0)) }) { Caption(text: "这些条目已暂留。开启上方开关可重新查看。") }
                            if doc.genericMarkers { Caption(text: "还有表格、段落或规则草稿标记，请打开原文核对，避免将整段推断一键确认为事实。") }
                        }.padding(12).background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 370).disabled(saving)
            ForEach(issues, id: \.self) { Text($0).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
            if saving { HStack { CockpitSpinner(); Caption(text: "核对版本并写回原笔记…") } }
        }.task { await load() }
    }
    private func load() async {
        guard let connection = store.coMind else { loading = false; return }
        let sources = store.coMindSources(for: store.noteActionArea)
        let result = await Task.detached { () -> ([ReviewDocument], [String]) in
            var docs: [ReviewDocument] = [], errors: [String] = []
            for source in sources {
                do {
                    let version = try CoMindFiles.read(source.path, in: connection.repository)
                    let markers = SourceReviewLocations.find(in: version.text, candidateFile: CoMindFiles.kind(source.path) == .candidates)
                    guard !markers.isEmpty else { continue }
                    let isNote = try KnowledgeSourceLocator.resolve(source.path, repo: connection.repository) != nil
                    let entries = isNote ? NoteReview.entries(version.text) : []
                    docs.append(.init(source: source, version: version, entries: entries, genericMarkers: !isNote || NoteReview.hasUnstructuredPending(version.text)))
                } catch { errors.append(error.localizedDescription) }
            }
            return (docs.sorted { !$0.entries.isEmpty && $1.entries.isEmpty }, Array(Set(errors)))
        }.value
        guard !Task.isCancelled, store.coMind == connection else { return }
        loadedConnection = connection
        documents = result.0; issues = result.1; loading = false
    }
    private func bodyCorrections(_ doc: ReviewDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(text: "选择同页需要更正的原句，再填写新说法。只修改你选择的位置。")
            ForEach(NoteReview.bodyCandidates(doc.version.text)) { candidate in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if corrections[candidate.line] == nil { corrections[candidate.line] = candidate.original }
                        else { corrections.removeValue(forKey: candidate.line) }
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: corrections[candidate.line] == nil ? "square" : "checkmark.square.fill")
                            Text(candidate.original).lineLimit(2).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(InteractiveButton())
                    if corrections[candidate.line] != nil {
                        CockpitField(title: "修正为", text: Binding(get: { corrections[candidate.line] ?? "" }, set: { corrections[candidate.line] = $0 }), placeholder: "填写修正后的原句")
                    }
                }.padding(.vertical, 4)
            }
        }
    }
    private func resolve(_ doc: ReviewDocument, _ entry: NoteReviewEntry, ignore: Bool) {
        guard !saving, store.coMind == loadedConnection, store.coMindSources(for: store.noteActionArea).contains(where: { $0.id == doc.id }) else { return }
        do {
            if !ignore, NoteReview.bodyCandidates(doc.version.text).contains(where: { corrections[$0.line] == $0.original }) {
                throw CoMindFiles.failure("选中的正文还没有修改。请填写修正后的原句，或取消不需要改的选择。")
            }
            let changes = ignore ? [] : NoteReview.bodyCandidates(doc.version.text).compactMap { candidate -> NoteBodyCorrection? in
                guard let replacement = corrections[candidate.line], replacement != candidate.original else { return nil }
                return .init(line: candidate.line, original: candidate.original, replacement: replacement)
            }
            let after = try NoteReview.resolve(entry, version: doc.version, conclusion: conclusion, ignore: ignore, corrections: changes)
            saving = true; issues = []
            Task {
                do {
                    _ = try await Task.detached { try CoMindFiles.commit(.init(before: doc.version, after: after)) }.value
                    selected = nil; conclusion = ""; corrections = [:]; showBody = false; store.refreshOriginalActivity(); await load()
                    store.notify(ignore ? "已忽略，原记录与历史保留" : "已写回原笔记，上一版已保留")
                } catch { issues = [error.localizedDescription] }
                saving = false
            }
        } catch { issues = [error.localizedDescription] }
    }
}

struct ConsolidateNotesView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var bridge: CodexBridge
    @State private var selected: Set<UUID> = []
    @State private var sources: [NoteWritebackTarget] = []
    @State private var sending = false
    @State private var issue: String?
    private var area: String { store.noteActionArea }
    private var modelLabel: String {
        guard let thread = store.managingThread else { return "会话模型" }
        return (store.conversationModels[thread.id] ?? thread.modelSettings)?.label ?? "沿用会话模型"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.managingThread?.title ?? "会话已不可用").font(CockpitTypography.section).lineLimit(2)
            Caption(text: "可沿用本阵地默认笔记，也可调整本次目标。提供最近最多 20 轮文字，AI 只补有价值的增量；结果与覆盖范围保留在资料页。")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sources) { source in
                        Toggle(source.title, isOn: Binding(get: { selected.contains(source.id) }, set: { if $0 { selected.insert(source.id) } else { selected.remove(source.id) } })).toggleStyle(CockpitToggleStyle())
                    }
                    if sources.isEmpty { Caption(text: "请先在「资料」页关联已有主题笔记。") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 190)
            Caption(text: "模型：" + modelLabel + "。本次会发送一条整理请求并使用 Codex 额度；仅执行一次，文件写入仍需通过现有审批。")
            if let issue { Text(issue).font(CockpitTypography.caption) }
            HStack {
                Button("取消") { store.sheet = nil }.buttonStyle(QuietButton())
                Spacer()
                Button(sending ? "准备中…" : "开始整理") { start() }.buttonStyle(PrimaryButton()).disabled(selected.isEmpty || sending || !bridge.connected || bridge.reading || bridge.sending || bridge.runningThreadID != nil || bridge.needsRecovery)
            }
        }.task {
            guard store.coMind != nil else { return }
            do { sources = try await store.eligibleWritebackSources(area: area) }
            catch { issue = error.localizedDescription }
            selected = store.defaultWritebackSources(area: area)
        }
    }
    private func start() {
        guard let thread = store.managingThread else { return }
        let targetArea = area, chosen = selected, model = store.conversationModels[thread.id] ?? thread.modelSettings
        sending = true; issue = nil
        Task {
            do {
                let accepted = try await store.startOrganization(thread: thread, area: targetArea, sources: chosen, model: model)
                if accepted {
                    if store.sheet == .consolidateNotes && store.managingThread?.id == thread.id && store.noteActionArea == targetArea {
                        store.sheet = nil; store.areaTab = "开始工作"
                    }
                    store.notify("已发送整理请求，完成后可在资料页查看实际改动")
                }
                else { store.manualConsolidationThreads.remove(thread.id); issue = bridge.error ?? "未发送，请检查连接或当前任务状态。" }
            } catch { issue = error.localizedDescription }
            sending = false
        }
    }
}
