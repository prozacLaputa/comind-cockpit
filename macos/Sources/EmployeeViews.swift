import SwiftUI

struct EmployeeForm: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @State private var profile = EmployeeProfile()
    @State private var baseline = EmployeeProfile()
    @State private var loadedProfile = EmployeeProfile()
    @State private var draftID: UUID?
    @State private var sourceName = ""
    @State private var sourcePurpose = ""
    @State private var feedback = ""
    @State private var loadedFeedback = ""
    @State private var applied = false
    @State private var showOriginal = false
    var body: some View {
        if let id = store.editingAreaID, let area = store.areas.first(where: { $0.id == id }) {
            let busy = store.draftingEmployees.contains(id)
            let draft = store.employeeProfileDrafts[id]
            let stale = draft.map { $0.areaName != area.name || $0.areaPurpose != area.purpose || $0.baseline != store.employeeProfile(for: id) } ?? false
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(area.name).font(CockpitTypography.section)
                        Caption(text: busy ? "AI 正在拟定，可以关闭后稍后审核" : draft != nil ? "待你审核 · 确认后才用于后续对话" : "按用途拟定，你只需要审核和调整")
                    }
                    Spacer()
                    if busy {
                        CockpitSpinner()
                        Button("停止") { store.employeeSetupTasks[id]?.cancel() }.buttonStyle(QuietButton())
                    } else {
                        Button { generate(id) } label: { Label(draft != nil ? "重新拟定" : profile.hasContent ? "AI 补全" : "AI 拟定", systemImage: "sparkles") }
                            .buttonStyle(QuietButton()).disabled(!store.canEdit)
                    }
                }
                if let error = store.employeeSetupErrors[id] { Text(error).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
                if let warning = store.storageWarning { Text(warning).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
                if stale { Caption(text: "名称、用途或原配置已更新。请重新拟定，避免启用过期草稿。") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if busy && !profile.hasContent {
                            VStack(spacing: 12) {
                                Image(systemName: "sparkles").font(CockpitTypography.font(size: 26)).foregroundStyle(theme.accent)
                                Text("正在把用途整理成一位专属助理").font(CockpitTypography.section)
                                Caption(text: "职责、性格、能力、工作方式和边界都会在这里显示。")
                            }.frame(maxWidth: .infinity).padding(.vertical, 66)
                        } else {
                            if draft != nil && baseline.hasContent {
                                Button { showOriginal.toggle() } label: { Label(showOriginal ? "收起当前配置" : "对照当前生效配置", systemImage: showOriginal ? "chevron.down" : "chevron.right") }.buttonStyle(InteractiveButton())
                                if showOriginal { Text(baseline.contextText).font(CockpitTypography.caption).textSelection(.enabled).padding(12).background(theme.soft, in: RoundedRectangle(cornerRadius: 9)) }
                            }
                            EmployeeProfileFields(profile: $profile).disabled(busy)
                            Toggle(store.coMind?.prefersOriginals(for: id) == true ? "低频合并更新阶段进展" : "低频合并更新进展与记忆候选", isOn: $profile.autoReview).toggleStyle(CockpitToggleStyle()).disabled(busy)
                            Caption(text: "自动进展：安静 10 分钟后合并，两次至少间隔 30 分钟。原笔记的每日整理独立运行；能力描述不授予额外权限。")
                        }
                    }.padding(.trailing, 4)
                }.frame(height: 330)
                HStack(alignment: .center, spacing: 10) {
                    CockpitField(title: "告诉 AI 如何调整", text: $feedback, placeholder: "例如：更简洁，先问清楚再给建议", showsLabel: false).disabled(busy)
                    Button("按意见调整") { generate(id) }.buttonStyle(QuietButton()).disabled(busy || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canEdit)
                }
                HStack(spacing: 10) {
                    if !(draft?.revisions.isEmpty ?? true) {
                        Button("恢复上一稿") { store.restorePreviousEmployeeDraft(id) }.buttonStyle(InteractiveButton()).disabled(busy)
                    } else { Caption(text: "使用 Codex 订阅 · 只参考名称、用途和此处配置") }
                    Spacer()
                    Button("稍后审核") { store.sheet = nil }.buttonStyle(QuietButton())
                    Button(draft != nil ? "确认启用" : "保存配置") {
                        applied = store.saveEmployeeProfile(profile, area: id, expected: baseline, draftID: draftID)
                    }.buttonStyle(PrimaryButton()).disabled(busy || stale || !profile.hasContent || !store.canEdit)
                }
            }
            .onAppear { load(id) }
            .onChange(of: store.employeeProfileDrafts[id]?.id) { _, _ in if !applied { load(id) } }
            .onDisappear {
                if !applied && profile.hasContent && (profile != loadedProfile || feedback != loadedFeedback) {
                    store.retainEmployeeDraft(profile, area: id, baseline: baseline, expectedDraftID: draftID, name: sourceName, purpose: sourcePurpose, feedback: feedback)
                }
            }
        }
    }
    private func load(_ id: String) {
        let draft = store.employeeProfileDrafts[id]
        baseline = draft?.baseline ?? store.employeeProfile(for: id)
        profile = draft?.profile ?? baseline; loadedProfile = profile
        draftID = draft?.id; feedback = draft?.feedback ?? ""; loadedFeedback = feedback
        sourceName = draft?.areaName ?? store.areaName(id)
        sourcePurpose = draft?.areaPurpose ?? store.areas.first(where: { $0.id == id })?.purpose ?? ""
    }
    private func generate(_ id: String) {
        let fillOnly = draftID == nil && feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if profile.hasContent && (profile != loadedProfile || feedback != loadedFeedback) {
            store.retainEmployeeDraft(profile, area: id, baseline: baseline, expectedDraftID: draftID, name: sourceName, purpose: sourcePurpose, feedback: feedback)
        }
        store.requestEmployeeDraft(id, current: profile, feedback: feedback, fillMissingOnly: fillOnly)
    }
}

struct EmployeeProfileFields: View {
    @Binding var profile: EmployeeProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CockpitEditor(title: "负责什么", height: 70, text: $profile.responsibility)
            CockpitEditor(title: "沟通性格", height: 58, text: Binding(get: { profile.personality ?? "" }, set: { profile.personality = $0 }))
            CockpitEditor(title: "擅长与能力范围", height: 70, text: Binding(get: { profile.skills ?? "" }, set: { profile.skills = $0 }))
            CockpitEditor(title: "工作方式与交付要求", height: 70, text: $profile.workingStyle)
            CockpitEditor(title: "边界与需要先确认的事", height: 70, text: $profile.boundaries)
        }
    }
}

struct EmployeeSetupStatus: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    var areaID: String
    var body: some View {
        if store.draftingEmployees.contains(areaID) {
            Button { store.showEmployeeSetup(areaID) } label: { HStack(spacing: 6) { CockpitSpinner(); Text("正在拟定") } }.buttonStyle(InteractiveButton())
        } else if store.employeeProfileDrafts[areaID] != nil || store.employeeSetupErrors[areaID] != nil || !store.employeeProfile(for: areaID).isComplete {
            Button { store.showEmployeeSetup(areaID) } label: {
                Label(store.employeeSetupErrors[areaID] != nil ? "配置需处理" : store.employeeProfileDrafts[areaID] != nil ? "配置待审核" : "AI 拟定配置", systemImage: "sparkles")
                    .font(CockpitTypography.caption).foregroundStyle(theme.emphasis).padding(6)
            }.buttonStyle(InteractiveButton())
        }
    }
}

struct EmployeeSetupOverview: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    private var pending: [Area] { store.areas.filter { store.employeeProfileDrafts[$0.id] != nil } }
    var body: some View {
        if !store.areas.isEmpty && (!pending.isEmpty || !store.employeesNeedingSetup.isEmpty || store.employeeBatchRunning) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(theme.accent)
                    Text(store.employeeBatchRunning ? "正在为已有阵地拟定配置…" : pending.isEmpty ? "让 AI 帮你配置这些助理" : "\(pending.count) 份员工配置待审核").font(CockpitTypography.section)
                    Spacer()
                    if store.employeeBatchRunning { CockpitSpinner() }
                    else if !store.employeesNeedingSetup.isEmpty {
                        Button("补全已有阵地 · \(store.employeesNeedingSetup.count)") { store.requestEmployeeBackfill() }.buttonStyle(QuietButton())
                    }
                }
                Caption(text: "根据名称和用途补齐缺项，保留已有配置；审核确认后才会启用。")
                if !pending.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading, spacing: 6) {
                        ForEach(pending) { area in
                            Button { store.showEmployeeSetup(area.id) } label: { Label(area.name + " · 审核", systemImage: area.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(InteractiveButton())
                        }
                    }
                }
                if !store.employeeSetupErrors.isEmpty { Caption(text: "有配置未完成，可进入对应阵地重试。") }
            }.padding(14).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct MemoryEditor: View {
    @EnvironmentObject var store: AppStore
    @State private var topic = ""
    @State private var text = ""
    @State private var category = MemoryCategory.fact.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CockpitField(title: "记住哪件事", text: $topic, placeholder: "例如：工作时的声音偏好")
            CockpitSegments(title: "类型", selection: $category, options: MemoryCategory.allCases.map { .init(id: $0.rawValue, label: $0.label) })
            CockpitEditor(title: "记忆内容", height: 140, text: $text)
            Caption(text: "保存后作为你确认的记忆供本阵地使用。原来的文字会保留，支持撤销最近一次修改。")
            HStack {
                Caption(text: "主题 \(topic.count)/80 · 内容 \(text.count)/2000")
                Spacer()
                Button("保存记忆") {
                    if let id = store.editingAreaID { store.saveMemory(area: id, memoryID: store.editingMemoryID, topic: topic, text: text, category: MemoryCategory(rawValue: category) ?? .fact) }
                }.buttonStyle(PrimaryButton()).disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || topic.count > 80 || text.count > 2000)
            }
        }.onAppear {
            if let memory = store.employeeMemories.first(where: { $0.id == store.editingMemoryID }) { topic = memory.topic; text = memory.text; category = memory.category.rawValue }
        }
    }
}

struct AreaMaterialsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let area: Area
    @State private var showHistory = false
    @State private var showLegacy = false
    private var memories: [EmployeeMemory] { store.employeeMemories.filter { $0.areaID == area.id }.sorted { $0.updated > $1.updated } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SectionHeading(title: "资料")
                Spacer()
                Button { store.chooseCoMindSource(area: area.id) } label: {
                    Label("关联原笔记", systemImage: "plus")
                }.buttonStyle(OutlinedButton()).disabled(!store.canEdit)
                CockpitActionMenu(title: "更多资料操作", actions: [
                    .init(title: "选取其他文件…", symbol: "doc.badge.plus", enabled: store.canEdit) { store.chooseLocalFile() },
                    .init(title: "关联已保存资料…", symbol: "link", enabled: store.canEdit) { store.sheet = .link },
                    .init(title: "记录到原笔记", symbol: "square.and.pencil", enabled: store.canEdit) { store.openOriginalCapture() },
                    .init(title: "关联协作规则", symbol: "slider.horizontal.3", enabled: store.canEdit) { attachRule(CoMindFiles.memory) },
                    .init(title: "关联规则待审草稿", symbol: "doc.badge.clock", enabled: store.canEdit) { attachRule(CoMindFiles.candidates) }
                ])
            }
            Caption(text: "关联已有笔记，开启「用于聊天」。AI 会在每次发送前读取最新原文。")
            NoteActivitySection(area: area.id)
            CoMindSourcesSection(areaID: area.id)
            savedMaterials
            if !memories.isEmpty {
                Button { showLegacy.toggle() } label: {
                    Label("旧版历史条目 · \(memories.count)", systemImage: showLegacy ? "chevron.down" : "chevron.right")
                }.buttonStyle(QuietButton())
                if showLegacy {
                    Caption(text: "仅保留尚未归拢的旧记录供核对。个人信息应写回已有原笔记；这些条目不会作为另一套资料自动维护。")
                    group("待你核对", state: .pending)
                    group("已确认", state: .active)
                    Button { showHistory.toggle() } label: { Label(showHistory ? "收起已停用与忽略" : "已停用与忽略", systemImage: showHistory ? "chevron.down" : "chevron.right") }.buttonStyle(InteractiveButton()).foregroundStyle(theme.muted)
                    if showHistory { group("已停用", state: .archived); group("已忽略", state: .dismissed) }
                }
            }
        }.animation(reduceMotion ? nil : CockpitMotion.presentation, value: showHistory)
            .animation(reduceMotion ? nil : CockpitMotion.presentation, value: showLegacy)
    }
    private var savedMaterials: some View {
        let documents = store.documents(for: area.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("会话摘录与其他资料", systemImage: "doc.on.doc").font(CockpitTypography.section)
                Spacer()
                Caption(text: "\(documents.count) 份")
            }
            Caption(text: "保存的回复、摘录和其他文件。用于本次聊天时，在「给 AI 的背景」中选择；不会自动变成长期事实。")
            if documents.isEmpty {
                Caption(text: "还没有保存的内容。可从会话保存回复，或通过右上角「更多资料操作」选取文件。")
            } else { DocumentList(documents: documents) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 0.5))
    }
    private func attachRule(_ path: String) {
        guard store.coMind != nil else { store.settingsTab = "数据"; store.sheet = .theme; return }
        do { try store.attachCoMindSource(path: path, area: area.id); store.notify("已关联，可开启「用于聊天」使用") }
        catch { store.notify(error.localizedDescription) }
    }
    @ViewBuilder private func group(_ title: String, state: MemoryState) -> some View {
        let items = memories.filter { $0.state == state }
        if !items.isEmpty {
            HStack { Text(title).font(CockpitTypography.section); Caption(text: "\(items.count)") }
            ForEach(items) { memory in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(memory.topic).font(CockpitTypography.section); Spacer(); Caption(text: memory.category.label + " · " + memory.updated.formatted(date: .abbreviated, time: .omitted)) }
                    Text(memory.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if state == .pending, let id = memory.replaces, let old = memories.first(where: { $0.id == id }) {
                        Caption(text: "与已确认记忆不同：" + old.text + "\n核对前，旧条目暂不带入新消息。确认后旧条目保留在已停用中。")
                    } else if state == .active && memories.contains(where: { $0.state == .pending && $0.replaces == memory.id }) {
                        Caption(text: "有新证据待核对，暂不用于新消息。")
                    }
                    ForEach(Array(memory.sources.enumerated()), id: \.offset) { _, source in
                        if source.threadID != nil || source.captureID != nil {
                            Button { store.openProgressSource(source, area: area.id) } label: { Label(source.title, systemImage: "arrow.up.right").font(CockpitTypography.caption).lineLimit(1) }.buttonStyle(InteractiveButton()).foregroundStyle(theme.muted)
                        } else { Caption(text: source.title) }
                    }
                    HStack(spacing: 12) {
                        if state == .pending {
                            Button(memory.replaces == nil ? "确认记住" : "采用新内容") { store.confirmMemory(memory.id) }.buttonStyle(QuietButton())
                            Button(memory.replaces == nil ? "忽略" : "保留原内容") { store.setMemoryState(memory.id, .dismissed) }.buttonStyle(InteractiveButton())
                            Button("修正后记住") { edit(memory) }.buttonStyle(InteractiveButton())
                        } else if state == .active {
                            Button("编辑") { edit(memory) }.buttonStyle(InteractiveButton())
                            Button("停用") { store.setMemoryState(memory.id, .archived) }.buttonStyle(InteractiveButton())
                            if !memory.history.isEmpty { Button("撤销上次修改") { store.undoMemoryEdit(memory.id) }.buttonStyle(InteractiveButton()) }
                        } else {
                            Button("恢复为待核对") { store.setMemoryState(memory.id, .pending) }.buttonStyle(InteractiveButton())
                        }
                    }.font(CockpitTypography.caption)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }
    private func edit(_ memory: EmployeeMemory?) { store.editingAreaID = area.id; store.editingMemoryID = memory?.id; store.sheet = .memory }
}

