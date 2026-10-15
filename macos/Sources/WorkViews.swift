import SwiftUI

struct WorkActivity: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var bridge: CodexBridge
    @Environment(\.cockpitTheme) var theme
    var body: some View {
        if let recovery = bridge.recovery {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: recovery.blocksSending ? "arrow.clockwise.circle" : "checkmark.circle").foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(recovery.thread.title).font(CockpitTypography.body).lineLimit(1)
                    Text(recovery.detail).font(CockpitTypography.caption).foregroundStyle(theme.muted)
                    HStack {
                        if recovery.blocksSending {
                            Button(bridge.recovering ? "正在核对…" : "核对原会话状态") { Task { await bridge.checkRecovery() } }.buttonStyle(OutlinedButton()).disabled(bridge.recovering)
                        }
                        Button("查看原会话") { store.navigate(.codex); Task { if bridge.connected { await bridge.read(recovery.thread) } } }.buttonStyle(QuietButton())
                        Button("打开 Codex") { Task { await bridge.openInCodex(recovery.thread) } }.buttonStyle(QuietButton())
                        if !recovery.blocksSending { Button("知道了") { bridge.dismissRecovery() }.buttonStyle(QuietButton()) }
                    }
                }
                Spacer(minLength: 0)
            }.padding(14).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
        }
        if !bridge.needsRecovery && (bridge.runningThreadID != nil || !bridge.approvals.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProgressView().progressViewStyle(CockpitProgressStyle())
                    Text(bridge.runStatus).font(CockpitTypography.body)
                    Spacer()
                    if let id = bridge.runningThreadID, let thread = bridge.threadMap[id] {
                        Button("查看当前会话") {
                            store.navigate(.codex)
                            Task { await bridge.read(thread) }
                        }.buttonStyle(QuietButton())
                    }
                    Button("停止") { Task { await bridge.stop() } }.buttonStyle(QuietButton()).disabled(bridge.runningTurnID == nil)
                }
                ForEach(bridge.questions) { request in QuestionCard(bridge: bridge, request: request).id(request.id) }
                ForEach(bridge.approvals) { approval in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(approval.method.contains("fileChange") ? "Codex 请求修改文件" : "Codex 请求执行操作").font(CockpitTypography.section)
                        ScrollView { Text(approval.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                        HStack {
                            Button("拒绝") { bridge.answerApproval(approval, accept: false) }.buttonStyle(QuietButton())
                            Button("仅允许这一次") { bridge.answerApproval(approval, accept: true) }.buttonStyle(PrimaryButton())
                        }
                    }.padding(14).background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(16).background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct WorkComposer: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var bridge: CodexBridge
    var thread: CodexThread? = nil
    var areaID: String?
    var seedReady = true
    @State private var includeArea = true
    @State private var includeProgress = true
    @State private var includeMemory = true
    @State private var includeProfile = true
    @State private var includeActions = true
    @State private var selectedDocuments: Set<UUID> = []
    private var selectedCoMindSources: Set<UUID> { store.coMind?.selectedSources(for: areaID ?? "") ?? [] }
    private var originalsOnly: Bool { store.coMind?.prefersOriginals(for: areaID ?? "") == true || !selectedCoMindSources.isEmpty }
    @State private var selectedThreads: Set<String> = []
    @State private var selectingContext = false
    @State private var selectingSkills = false
    @State private var preparing = false
    @State private var issue: String?
    @State private var failedDocument: UUID?
    @State private var previewText: String?
    private var key: String { thread?.id ?? "new:" + (areaID ?? "global") }
    private var draftScope: String { store.draftOwners[key] ?? areaID ?? "" }
    private var draft: Binding<String> { Binding(get: { store.conversationDrafts[key] ?? "" }, set: { if store.draftOwners[key] == nil { store.draftOwners[key] = areaID ?? "" }; store.conversationDrafts[key] = $0 }) }
    private var skills: Binding<[CodexSkill]> { Binding(get: { store.conversationSkills[key] ?? [] }, set: { store.conversationSkills[key] = $0 }) }
    private var modelSelection: Binding<CodexModelSelection?> { Binding(get: { store.conversationModels[key] }, set: { store.conversationModels[key] = $0 }) }
    private var skillDirectory: String { thread?.cwd ?? areaID.map { store.workDirectory(for: $0).path } ?? "" }
    private var area: Area? { store.areas.first { $0.id == areaID } }
    private var report: AreaProgressReport? { areaID.flatMap { store.progressReports[$0] } }
    private var profile: EmployeeProfile? {
        guard let areaID else { return nil }
        let value = store.employeeProfile(for: areaID)
        return value.hasContent ? value : nil
    }
    private var memories: [EmployeeMemory] { areaID.map { MemoryContext.select(store.employeeMemories, areaID: $0, request: draft.wrappedValue) } ?? [] }
    private var documents: [DocumentRecord] { areaID.map { store.documents(for: $0) } ?? [] }
    private var references: [CodexThread] {
        store.threadLinks.filter { $0.areaID == areaID && $0.threadID != thread?.id }.compactMap { bridge.threadMap[$0.threadID] }
    }
    private var contextLabel: String {
        var labels: [String] = []
        if includeArea && area != nil { labels.append("阵地目标") }
        if includeProfile && profile != nil { labels.append("职责") }
        if includeMemory && !originalsOnly && !memories.isEmpty { labels.append("\(memories.count) 条记忆") }
        if !selectedCoMindSources.isEmpty { labels.append("\(selectedCoMindSources.count) 份原文件 · 按需读取") }
        if includeProgress && !originalsOnly && report != nil { labels.append("AI 进展") }
        if includeActions && !originalsOnly, let areaID, !store.actionContext(areaID).isEmpty { labels.append("事项状态") }
        if !selectedThreads.isEmpty { labels.append("\(selectedThreads.count) 个参考会话") }
        if !selectedDocuments.isEmpty { labels.append("\(selectedDocuments.count) 份资料") }
        return labels.isEmpty ? "仅发送本次输入" : labels.joined(separator: " · ")
    }
    private var attachments: [ChatAttachment] { store.conversationAttachments[key] ?? [] }
    private var pending: PendingChatMessage? { store.pendingMessages.first { $0.key == key || ($0.threadID == thread?.id && thread != nil) } }
    private var busy: Bool { bridge.runningThreadID != nil || bridge.sending || store.pendingDispatching }
    private var canSend: Bool {
        (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && bridge.connected &&
        !preparing && !bridge.reading && !bridge.needsRecovery && pending == nil && store.composerWritable
    }
    private var backgroundOptions: ConversationBackgroundOptions {
        .init(area: includeArea, profile: includeProfile, memory: includeMemory, progress: includeProgress,
              actions: includeActions, documents: selectedDocuments, sources: selectedCoMindSources, threads: selectedThreads)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { selectingContext.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "text.badge.plus")
                        Text("给 AI 的背景").fontWeight(.medium)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(selectingContext ? 180 : 0))
                    }.font(CockpitTypography.caption).padding(.vertical, 4)
                }.buttonStyle(InteractiveButton(selected: selectingContext))
                    .help("查看和调整随消息发送的背景信息")
                    .accessibilityLabel(selectingContext ? "收起给 AI 的背景" : "展开给 AI 的背景")
                    .accessibilityValue(contextLabel).disabled(preparing)
                    .popover(isPresented: $selectingContext, arrowEdge: .top) { contextPanel }
                Text(contextLabel).font(CockpitTypography.caption).foregroundStyle(theme.muted).lineLimit(1)
                Spacer()
                Text(thread == nil ? "新会话" : "续聊原会话").font(CockpitTypography.caption).foregroundStyle(theme.muted)
            }
            if !skills.wrappedValue.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(skills.wrappedValue) { skill in
                            Button { skills.wrappedValue.removeAll { $0.id == skill.id } } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                    Text(skill.title).lineLimit(1)
                                    Image(systemName: "xmark").font(.system(size: 9))
                                }.font(CockpitTypography.caption).padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(theme.accentSoft, in: Capsule())
                            }.buttonStyle(InteractiveButton()).disabled(preparing || bridge.sending)
                                .accessibilityLabel("移除 Skill：" + skill.name).help("仅随下一条消息调用；点击移除")
                        }
                    }
                }.frame(height: 32).scrollIndicators(.hidden)
            }
            if !draft.wrappedValue.isEmpty {
                Caption(text: store.composerWarning ?? (store.composerSaving ? "正在保存草稿…" : "草稿已保存 · " + store.storageLabel))
            }
            if let pending { pendingCard(pending) }
            if !attachments.isEmpty { ChatAttachmentStrip(items: attachments) { store.removeImage($0, key: key) } }
            ChatInput(text: draft, canSend: canSend, send: send, receiveImages: receiveImages)
            if busy && pending == nil {
                Caption(text: bridge.needsRecovery ? "发送结果待核对，输入已保留。" : !bridge.approvals.isEmpty ? "正在等待授权；可以先写下一条，加入待发送。" : !bridge.questions.isEmpty ? "AI 正在等你回答；下一条可先加入待发送。" : "正在处理上一条消息；下一条可加入待发送，完成后依次发送。")
            }
            if let issue { Text(issue).foregroundStyle(theme.emphasis).font(CockpitTypography.caption) }
            if let id = failedDocument {
                HStack {
                    Button("重新定位资料…") { store.relocateDocument(id); previewText = nil }.buttonStyle(QuietButton())
                    Button("取消携带这份资料") { selectedDocuments.remove(id); failedDocument = nil; issue = nil; previewText = nil }.buttonStyle(QuietButton())
                }
            }
            HStack {
                Button { chooseImages() } label: { Image(systemName: "photo.badge.plus").frame(width: 26, height: 26) }
                    .buttonStyle(InteractiveButton()).help("添加图片，也可粘贴截图或拖入图片").accessibilityLabel("添加图片").disabled(preparing || attachments.count >= ChatAttachments.maximumCount)
                Button { selectingSkills.toggle() } label: {
                    Label("Skills", systemImage: "sparkles").font(.system(size: 12))
                }.buttonStyle(OutlinedButton()).disabled(preparing || bridge.sending || !bridge.connected)
                    .accessibilityLabel("选择 Skills").help("查找并调用本机 Codex Skills")
                    .popover(isPresented: $selectingSkills, arrowEdge: .top) {
                        SkillPicker(bridge: bridge, cwd: skillDirectory, selection: skills, dismiss: { selectingSkills = false })
                            // A cached popover can retain the parent modal's disabled environment.
                            .environment(\.isEnabled, bridge.connected && !preparing && !bridge.sending)
                    }
                ModelControl(bridge: bridge, cwd: skillDirectory, thread: thread, selection: modelSelection,
                             locked: preparing)
                    .frame(maxWidth: 240, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    Caption(text: "↵ 发送 · Shift+↵ 换行").fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }.layoutPriority(-1)
                Spacer()
                if let id = thread?.id, bridge.runningThreadID == id {
                    Button("停止") { Task { await bridge.stop() } }.buttonStyle(QuietButton()).disabled(bridge.runningTurnID == nil)
                }
                Button(busy ? "加入待发送" : "发送") { send() }.buttonStyle(PrimaryButton())
                    .disabled(!canSend)
            }
        }.padding(ChatLayout.contentInset).background(theme.soft, in: RoundedRectangle(cornerRadius: 12))
        .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.presentation, value: selectingContext)
        .onChange(of: seedReady, initial: true) { _, _ in consumeSeed() }
        .onChange(of: store.composerSeed) { _, _ in consumeSeed() }
    }
    private func consumeSeed() {
        guard seedReady, let seed = store.composerSeed else { return }
        draft.wrappedValue = draft.wrappedValue.isEmpty ? seed : draft.wrappedValue + "\n\n" + seed
        store.composerSeed = nil
    }
    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("给 AI 的背景").font(CockpitTypography.section)
                Spacer()
                Button { selectingContext = false } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }.buttonStyle(InteractiveButton()).accessibilityLabel("关闭背景设置").keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("这些背景会随你下一条消息一起发给 AI，可按需关闭。")
                        .font(CockpitTypography.caption).foregroundStyle(theme.muted)
                    if let area {
                        Toggle("阵地名称与目标", isOn: $includeArea).toggleStyle(CockpitToggleStyle())
                        Text(area.name + " · " + (area.purpose.isEmpty ? "尚未填写目标" : area.purpose))
                            .font(CockpitTypography.caption).foregroundStyle(theme.muted).textSelection(.enabled)
                    }
                    if let profile {
                        Toggle("携带员工职责与工作方式", isOn: $includeProfile).toggleStyle(CockpitToggleStyle())
                        Text(profile.contextText).font(CockpitTypography.caption).foregroundStyle(theme.muted)
                    }
                    if originalsOnly {
                        Caption(text: "背景直接读取「资料」中启用的原文件。旧记忆、AI 进展及事项摘要保留在各页面查看，不自动随消息发送。来源选择按阵地保存，切换会话和重启后继续有效。")
                    }
                    if !originalsOnly {
                    if !memories.isEmpty {
                        Toggle("携带已确认记忆 · \(memories.count) 条", isOn: $includeMemory).toggleStyle(CockpitToggleStyle())
                        ForEach(memories) { memory in
                            Text(memory.topic + " · " + memory.text).font(CockpitTypography.caption).foregroundStyle(theme.muted).textSelection(.enabled)
                        }
                    }
                    if area != nil { Caption(text: "记忆仅来自当前阵地，优先匹配本次输入，最多携带 12 条；待核对及冲突中的记忆不会携带。") }
                    if let report {
                        Toggle("携带 AI 进展 · " + report.generatedAt.formatted(date: .abbreviated, time: .shortened), isOn: $includeProgress).toggleStyle(CockpitToggleStyle())
                        Text(ConversationContext.progressText(report)).font(CockpitTypography.caption).foregroundStyle(theme.muted).textSelection(.enabled)
                    } else if area != nil { Caption(text: "尚无 AI 进展；可先到进展页生成，或在下方选择参考会话。") }
                    if let areaID, !store.actionContext(areaID).isEmpty {
                        Toggle("携带已反馈的事项状态", isOn: $includeActions).toggleStyle(CockpitToggleStyle())
                        Text(store.actionContext(areaID)).font(CockpitTypography.caption).foregroundStyle(theme.muted).textSelection(.enabled)
                    }
                    }
                    if !store.coMindSources(for: areaID ?? "").isEmpty {
                        Caption(text: "原文件 · 发送前重读，按问题选取原文；不确定时 AI 补读所选原件")
                        ForEach(store.coMindSources(for: areaID ?? "")) { source in
                            Toggle(CoMindFiles.title(source, connection: store.coMind), isOn: Binding(get: { selectedCoMindSources.contains(source.id) }, set: { enabled in
                                do { try store.setCoMindChatSource(source.id, area: areaID ?? "", enabled: enabled); previewText = nil }
                                catch { showPreparationError(error) }
                            })).toggleStyle(CockpitToggleStyle())
                            if CoMindFiles.kind(source.path) == .formal { Caption(text: "CoMind 协作约定，说明 AI 如何配合，不作为个人事实。") }
                            if CoMindFiles.kind(source.path) == .candidates { Caption(text: "CoMind 规则待审草稿，包含候选与审核记录，不代表已确认事实。") }
                        }
                    }
                    if area != nil && selectedCoMindSources.isEmpty {
                        Caption(text: "当前没有启用原文件。可在「资料 → 关联原笔记」中选择文件，再开启「用于聊天」。未关联的笔记不会自动读取。")
                    }
                    if !references.isEmpty {
                        Caption(text: "参考其他会话 · 最多 3 个，每个取最近 6 轮、至多 12000 字")
                        ForEach(references) { reference in
                            Toggle(reference.title, isOn: Binding(get: { selectedThreads.contains(reference.id) }, set: { if $0 { selectedThreads.insert(reference.id) } else { selectedThreads.remove(reference.id) } }))
                                .toggleStyle(CockpitToggleStyle()).disabled(!selectedThreads.contains(reference.id) && selectedThreads.count >= 3)
                        }
                    }
                    ForEach(documents) { doc in
                        Toggle(doc.name, isOn: Binding(get: { selectedDocuments.contains(doc.id) }, set: { if $0 { selectedDocuments.insert(doc.id) } else { selectedDocuments.remove(doc.id) } })).toggleStyle(CockpitToggleStyle())
                    }
                    Caption(text: "只携带上面启用的内容快照，不会合并会话或自动同步其他会话的后续消息。")
                    Button("预览本次发送内容") {
                        preparing = true; issue = nil; failedDocument = nil
                        Task {
                            defer { preparing = false }
                            do { previewText = try await prepareMessage(request: draft.wrappedValue) }
                            catch { showPreparationError(error); selectingContext = false }
                        }
                    }.buttonStyle(OutlinedButton())
                    if let previewText {
                        Caption(text: "以下为读取时的发送预览；修改选择后请重新预览，发送时会重新核对资料。")
                        Text(previewText).font(CockpitTypography.caption).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.frame(height: 300).background(theme.surface, in: RoundedRectangle(cornerRadius: 8)).disabled(preparing)
        }.padding(16).frame(width: 430).background(theme.canvas).foregroundStyle(theme.text)
            .preferredColorScheme(theme.dark ? .dark : .light)
            .onExitCommand { selectingContext = false }
    }
    private func prepareMessage(request: String, threadID: String? = nil) async throws -> String {
        try await store.prepareConversationMessage(request: request, areaID: areaID,
            options: .init(area: includeArea, profile: includeProfile, memory: includeMemory, progress: includeProgress,
                           actions: includeActions, documents: selectedDocuments, sources: nil, threads: selectedThreads),
            sourceThreadID: threadID ?? thread?.id,
            referenceText: { try await bridge.referenceText($0) })
    }
    private func showPreparationError(_ error: Error) {
        issue = error.localizedDescription; failedDocument = (error as? DocumentReadFailure)?.id
    }
    private func pendingCard(_ item: PendingChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(item.state == "sending" ? "发送中" : item.state == "waiting" ? "待发送" : "已暂停", systemImage: "clock").font(CockpitTypography.caption)
                Spacer()
                if item.state == "uncertain", let id = item.threadID {
                    Button("查看原会话") { Task { await bridge.resolveLinks([id], refresh: true); if let thread = bridge.threadMap[id] { await bridge.read(thread) } } }.buttonStyle(InteractiveButton())
                }
                if item.state == "paused" {
                    Button("继续发送") { store.resumePendingMessage(item.id) }.buttonStyle(InteractiveButton()).disabled(bridge.needsRecovery)
                }
                if item.state != "sending" && item.state != "uncertain" {
                    Button("编辑") {
                        if let value = store.editPendingMessage(item.id, targetKey: key) {
                            includeArea = value.options.area; includeProfile = value.options.profile; includeMemory = value.options.memory
                            includeProgress = value.options.progress; includeActions = value.options.actions
                            selectedDocuments = value.options.documents; selectedThreads = value.options.threads
                        }
                    }.buttonStyle(InteractiveButton())
                }
                if item.state != "sending" { Button("撤回") { store.cancelPendingMessage(item.id) }.buttonStyle(InteractiveButton()) }
            }
            Text(item.text.isEmpty ? "图片消息 · \(item.attachments.count) 张" : item.text).font(CockpitTypography.body).lineLimit(2).textSelection(.enabled)
            Caption(text: item.detail)
        }.padding(10).background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
    }
    private func chooseImages() {
        let panel = NSOpenPanel(); panel.title = "添加聊天图片"; panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do { try store.addImages(store.imageInputs(panel.urls), key: key, area: areaID ?? ""); issue = nil }
        catch { showPreparationError(error) }
    }
    private func receiveImages(_ pasteboard: NSPasteboard) {
        do {
            let urls = ChatAttachments.imageURLs(pasteboard)
            let inputs: [(Data, String)]
            if !urls.isEmpty { inputs = try store.imageInputs(urls) }
            else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { inputs = [(data, "粘贴的图片")] }
            else { return }
            try store.addImages(inputs, key: key, area: areaID ?? ""); issue = nil
        } catch { showPreparationError(error) }
    }
    private func send() {
        guard canSend else { return }
        issue = nil; failedDocument = nil
        if !store.enqueueMessage(key: key, area: areaID, thread: thread, options: backgroundOptions) { issue = store.composerWarning }
    }
}
