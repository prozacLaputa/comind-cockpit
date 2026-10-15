import SwiftUI
import AppKit

struct CodexQuotaView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bridge: CodexBridge
    @Environment(\.cockpitTheme) var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "terminal").foregroundStyle(theme.accent); Text("Codex").font(CockpitTypography.font(size: 13, weight: .medium)); Spacer(); if bridge.connecting || bridge.refreshingQuota { ProgressView().progressViewStyle(CockpitProgressStyle()) } else { Circle().fill(bridge.connected && !theme.binary ? Color.green.opacity(0.75) : theme.muted).frame(width: 5, height: 5) } }
            Caption(text: bridge.connected ? bridge.accountLabel : bridge.connecting ? "正在连接本机…" : "尚未连接")
            ForEach(bridge.windows) { window in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(window.label); Spacer(); Text("剩余 \(Int(window.remaining))%").monospacedDigit() }.font(CockpitTypography.font(size: 10))
                    ProgressView(value: window.remaining, total: 100).progressViewStyle(CockpitProgressStyle())
                    if let date = window.resets { Text("重置 \(date.formatted(.dateTime.month().day().hour().minute()))").font(CockpitTypography.font(size: 10)).foregroundStyle(theme.muted) }
                }
            }
            if bridge.windows.isEmpty && bridge.connected { Caption(text: bridge.refreshingQuota ? "正在读取真实额度…" : bridge.quotaError ?? "额度暂不可用") }
            if !bridge.windows.isEmpty && bridge.quotaError != nil { Caption(text: "刷新失败，显示上次读数").help(bridge.quotaError ?? "") }
            if let date = bridge.refreshedAt { Text("更新于 \(date.formatted(date: .omitted, time: .shortened))").font(CockpitTypography.font(size: 10)).foregroundStyle(theme.muted) }
            Button(bridge.refreshingQuota ? "正在刷新…" : bridge.connected ? "刷新用量" : "连接 Codex") { Task { if bridge.connected { await bridge.refreshAccount() } else { await bridge.connect() } } }.font(CockpitTypography.font(size: 11)).buttonStyle(InteractiveButton()).foregroundStyle(theme.emphasis).disabled(bridge.connecting || bridge.refreshingQuota)
            Button { store.sheet = .codexInfo } label: {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                    Text("与 Codex 的关系")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(CockpitTypography.font(size: 9, weight: .medium))
                }.font(CockpitTypography.caption).foregroundStyle(theme.muted).padding(.vertical, 4)
            }.buttonStyle(InteractiveButton()).help("查看账号、额度消耗和会话关联规则")
        }.padding(10).background(theme.canvas.opacity(theme.opacity(0.65)), in: RoundedRectangle(cornerRadius: 9))
    }
}
struct CodexPage: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var bridge: CodexBridge
    var areaFilter: String? = nil
    @State private var search = ""
    @State private var listScope = "recent"
    @State private var showAll = false
    @State private var targetArea = ""
    private var scoped: Bool { areaFilter != nil }
    private var destination: String { areaFilter ?? targetArea }
    private var links: [ThreadLink] { store.threadLinks.filter { $0.projectID == nil && $0.areaID == areaFilter } }
    private var linkedThreads: [CodexThread] { links.compactMap { bridge.threadMap[$0.threadID] }.sorted { $0.updated > $1.updated } }
    private var unresolvedLinks: [ThreadLink] { links.filter { bridge.threadMap[$0.threadID] == nil } }
    private func isLinked(_ id: String) -> Bool { store.threadLinks.contains { $0.threadID == id && $0.areaID == destination && $0.projectID == nil } }
    private func changeLink(_ id: String, remove: Bool) {
        guard !destination.isEmpty else { return }
        if remove { store.unlinkThread(id, areaID: destination) }
        else { store.linkThread(id, areaID: destination) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let error = bridge.error {
                Label(error, systemImage: "exclamationmark.circle").font(CockpitTypography.caption)
                    .foregroundStyle(theme.emphasis).textSelection(.enabled)
            }
            if !bridge.connected {
                EmptyPanel(icon: "terminal", title: "连接你已有的 Codex", detail: "连接本机登录后，即可继续原有会话。")
                Button("选择 Codex 可执行文件…") { bridge.chooseExecutable() }.buttonStyle(QuietButton())
            } else if !scoped, let thread = bridge.selected {
                reader(thread)
            } else if scoped {
                if links.isEmpty {
                    EmptyPanel(icon: "bubble.left.and.bubble.right", title: "让这个阵地开始工作", detail: "新建一个会话，或关联之前的讨论。")
                } else {
                    VStack(spacing: 0) {
                        ForEach(linkedThreads) { thread in
                            row(thread)
                            if thread.id != linkedThreads.last?.id || !unresolvedLinks.isEmpty { rowDivider }
                        }
                        ForEach(unresolvedLinks) { link in
                            HStack(spacing: 12) {
                                Image(systemName: "bubble.left").foregroundStyle(theme.muted)
                                Text(bridge.loading ? "正在读取会话…" : "会话暂不可用").font(CockpitTypography.body)
                                    .help(link.threadID)
                                Spacer()
                                CockpitActionMenu(title: "不可用会话的操作", actions: [
                                    .init(title: "重新读取", symbol: "arrow.clockwise") { Task { await bridge.resolveLinks([link.threadID]) } },
                                    .init(title: "解除关联", symbol: "link.badge.minus") { changeLink(link.threadID, remove: true) }
                                ])
                            }.padding(14)
                        }
                    }.background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border.opacity(theme.opacity(0.65)), lineWidth: 0.5))
                }
                if showAll {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("关联已有会话").font(CockpitTypography.section)
                            Spacer()
                            Button { showAll = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                                .buttonStyle(InteractiveButton()).help("收起关联面板").accessibilityLabel("收起关联面板")
                        }
                        browser
                    }.padding(16).background(theme.soft, in: RoundedRectangle(cornerRadius: 12))
                        .transition(.opacity.combined(with: reduceMotion ? .identity : .move(edge: .top)))
                }
            } else {
                HStack(spacing: 10) {
                    CockpitSelect(title: "关联到", selection: $targetArea,
                        options: [SelectOption(id: "", label: "选择关联阵地")] + store.areas.map { .init(id: $0.id, label: $0.name, symbol: $0.symbol) },
                        showsLabel: false).frame(maxWidth: 240)
                    Spacer()
                }
                browser
            }
        }
        .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.presentation, value: showAll)
        .task(id: (areaFilter ?? "all") + String(bridge.connected)) {
            if bridge.connected { await bridge.resolveLinks(scoped ? links.map(\.threadID) : store.threadLinks.map(\.threadID)) }
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Text(scoped ? "会话" : "Codex 会话").font(CockpitTypography.title(scoped ? 15 : 22))
            if scoped {
                Text("\(links.count)").font(CockpitTypography.font(size: 11, weight: .medium)).foregroundStyle(theme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(theme.soft, in: Capsule())
            }
            Spacer(minLength: 12)
            if bridge.connected {
                Button { Task { await refresh() } } label: {
                    if bridge.loading { CockpitSpinner().frame(width: 28, height: 30) }
                    else { Image(systemName: "arrow.clockwise").frame(width: 28, height: 30) }
                }.buttonStyle(InteractiveButton()).disabled(bridge.loading || bridge.reading)
                    .help("刷新会话").accessibilityLabel("刷新会话")
                if scoped {
                    Button { showAll.toggle(); if showAll { Task { await refresh() } } } label: { Label("关联已有", systemImage: "link") }
                        .buttonStyle(QuietButton()).accessibilityValue(showAll ? "已展开" : "已收起")
                        .help("选择已有的 Codex 会话，关联到当前阵地")
                    Button { createThread() } label: { Label(bridge.sending ? "正在创建…" : "新会话", systemImage: "plus") }
                        .buttonStyle(PrimaryButton()).disabled(bridge.sending || bridge.reading || bridge.runningThreadID != nil)
                }
            } else {
                Button(bridge.connecting ? "正在连接…" : "连接 Codex") { Task { await bridge.connect() } }
                    .buttonStyle(PrimaryButton()).disabled(bridge.connecting)
            }
        }
    }
    private var browser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CockpitField(title: "搜索会话", text: $search, symbol: "magnifyingglass", showsLabel: false)
                    .onSubmit { Task { await refresh() } }
                CockpitSelect(title: "会话范围", selection: $listScope, options: [
                    .init(id: "recent", label: "最近会话"), .init(id: "archived", label: "已归档")
                ], showsLabel: false).frame(width: 120).disabled(bridge.loading)
                    .onChange(of: listScope) { _, _ in Task { await refresh() } }
                Button("搜索") { Task { await refresh() } }.buttonStyle(QuietButton()).disabled(bridge.loading)
            }
            if bridge.loading { ProgressView("正在读取本机会话…").progressViewStyle(CockpitProgressStyle()) }
            if bridge.threads.isEmpty && !bridge.loading {
                Caption(text: "没有找到会话。试试其他关键词，或切换归档范围。")
            }
            LazyVStack(spacing: 0) {
                ForEach(bridge.threads) { thread in
                    row(thread, browsing: true)
                    if thread.id != bridge.threads.last?.id { rowDivider }
                }
            }.background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            if bridge.nextCursor != nil {
                Button("加载更多") { Task { await bridge.listThreads(more: true) } }.buttonStyle(QuietButton()).disabled(bridge.loading)
            }
        }
    }
    private var rowDivider: some View { theme.border.opacity(theme.opacity(0.6)).frame(height: 0.5).padding(.leading, 48).padding(.trailing, 14) }
    private func row(_ thread: CodexThread, browsing: Bool = false) -> some View {
        HStack(spacing: 8) {
            Button { openConversation(thread) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left").font(CockpitTypography.font(size: 15)).foregroundStyle(theme.accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(thread.title.components(separatedBy: .newlines).joined(separator: " "))
                            .font(CockpitTypography.font(size: 13, weight: .medium)).lineLimit(1)
                        HStack(spacing: 8) {
                            if !thread.isSaved { Text("尚未发送").foregroundStyle(theme.emphasis) }
                            if !thread.cwd.isEmpty {
                                Label(URL(fileURLWithPath: thread.cwd).lastPathComponent, systemImage: "folder")
                                    .lineLimit(1).help(thread.cwd)
                            }
                            if !scoped {
                                let names = store.threadLinks.filter { $0.threadID == thread.id && $0.projectID == nil }.map { store.areaName($0.areaID) }
                                if !names.isEmpty { Text(names.joined(separator: " · ")).lineLimit(1) }
                            }
                        }.font(CockpitTypography.caption).foregroundStyle(theme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(thread.updated, format: .dateTime.month().day()).font(CockpitTypography.caption)
                        .foregroundStyle(theme.muted).help(thread.updated.formatted(date: .abbreviated, time: .shortened))
                    Image(systemName: "chevron.right").font(CockpitTypography.font(size: 9, weight: .semibold)).foregroundStyle(theme.muted)
                }.padding(.vertical, 14).padding(.leading, 14).padding(.trailing, 8).contentShape(Rectangle())
            }.buttonStyle(InteractiveButton()).disabled(bridge.reading || bridge.sending)
                .help(scoped && !isLinked(thread.id) ? "预览会话，暂不关联" : "在驾驶舱继续此会话").accessibilityLabel("继续会话：" + thread.title)
            if browsing && !destination.isEmpty {
                if isLinked(thread.id) {
                    Label("已关联", systemImage: "checkmark").font(CockpitTypography.caption).foregroundStyle(theme.muted)
                } else {
                    Button("关联") { changeLink(thread.id, remove: false) }.buttonStyle(QuietButton())
                }
            }
            CockpitActionMenu(title: "会话操作：" + thread.title, actions: threadActions(thread))
                .padding(.trailing, 10)
        }.contextMenu {
            Button("重命名会话…") { store.requestThreadRename(thread) }.disabled(!bridge.canRenameThread(thread))
        }
    }
    private func threadActions(_ thread: CodexThread) -> [CockpitMenuAction] {
        var actions: [CockpitMenuAction] = [
            .init(title: "重命名会话…", symbol: "pencil", enabled: bridge.canRenameThread(thread)) { store.requestThreadRename(thread) },
            .init(title: "在 Codex 中打开", symbol: "arrow.up.right.square", enabled: thread.isSaved && bridge.openingThreadID == nil && bridge.deletingThreadID != thread.id) { Task { await bridge.openInCodex(thread) } },
            .init(title: "复制会话 ID", symbol: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(thread.id, forType: .string) }
        ]
        if !destination.isEmpty {
            let linked = isLinked(thread.id)
            actions.append(.init(title: linked ? "解除关联" : "关联到当前阵地", symbol: linked ? "link.badge.minus" : "link") { changeLink(thread.id, remove: linked) })
        }
        actions.append(.init(title: "删除会话…", symbol: "trash", destructive: true,
                             enabled: bridge.runningThreadID != thread.id && bridge.deletingThreadID == nil && !bridge.sending) {
            store.managingThread = thread; store.sheet = .deleteThread
        })
        return actions
    }
    private func openConversation(_ thread: CodexThread) {
        Task {
            if let areaFilter {
                if isLinked(thread.id) { store.lastAreaThread[areaFilter] = thread.id; store.areaTab = "开始工作" }
                else { store.navigate(.codex) }
            }
            await bridge.read(thread)
        }
    }
    private func createThread() {
        guard let areaFilter else { return }
        Task {
            if let thread = await bridge.newThread(cwd: store.workDirectory(for: areaFilter)) {
                store.linkThread(thread.id, areaID: areaFilter)
                store.lastAreaThread[areaFilter] = thread.id
                if store.areaID == areaFilter { store.areaTab = "开始工作" }
            }
        }
    }
    private func reader(_ thread: CodexThread) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { bridge.selected = nil; bridge.messages = [] } label: { Label("全部会话", systemImage: "chevron.left") }.buttonStyle(InteractiveButton())
                Spacer()
                CockpitActionMenu(title: "会话操作", actions: threadActions(thread))
            }.padding(.horizontal, ChatLayout.contentInset)
            Text(thread.title).font(CockpitTypography.section).lineLimit(2).padding(.horizontal, ChatLayout.contentInset)
            ChatTranscript(bridge: bridge, thread: thread, areaID: nil).frame(height: 420)
            WorkComposer(bridge: bridge, thread: thread, areaID: nil).id(thread.id)
        }.modifier(ChatColumn())
    }
    private func refresh() async {
        await bridge.listThreads(search: search, archived: listScope == "archived")
        await bridge.resolveLinks(scoped ? links.map(\.threadID) : store.threadLinks.map(\.threadID))
    }
}
