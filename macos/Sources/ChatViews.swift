import SwiftUI
import AppKit

/// Share one reading width across transcript, conversation tools and composer.
/// The flexible outer frame centers this column and yields on narrow windows.
enum ChatLayout {
    static let maximumWidth: CGFloat = 1120
    static let contentInset: CGFloat = 12
    static let navigationGutter: CGFloat = 24
}

/// Keep the rail outside the shared reading column, including on narrow windows.
struct ChatColumn: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: ChatLayout.maximumWidth)
            .padding(.horizontal, ChatLayout.navigationGutter)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct TranscriptRowLayout: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: ChatLayout.contentInset,
                                     bottom: 8, trailing: ChatLayout.contentInset))
    }
}

struct AreaChatView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var bridge: CodexBridge
    let area: Area
    @State private var newConversation = false
    @State private var seedReadyAreaID: String?
    @State private var managing = false
    @State private var search = ""
    private var ids: [String] { store.threadLinks.filter { $0.areaID == area.id }.map(\.threadID) }
    private var linked: [CodexThread] { ids.compactMap { bridge.threadMap[$0] }.sorted { $0.updated > $1.updated } }
    private var current: CodexThread? { !newConversation ? bridge.selected.flatMap { ids.contains($0.id) ? $0 : nil } : nil }
    private var readObservation: String {
        [current?.id ?? "", String(bridge.reading), String(current?.updated.timeIntervalSince1970 ?? 0), String(bridge.runningThreadID == nil), String(bridge.refreshingHistory), String(describing: bridge.loadedHistoryUpdated[current?.id ?? ""])].joined(separator: "|")
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                CockpitSelect(title: "切换会话", selection: Binding(get: { current?.id ?? "" }, set: { id in
                    if id.isEmpty { beginNew() }
                    else if let thread = bridge.threadMap[id] { newConversation = false; store.lastAreaThread[area.id] = id; Task { await bridge.read(thread) } }
                }), options: [SelectOption(id: "", label: "新会话", symbol: "plus.bubble")] + linked.map { .init(id: $0.id, label: $0.title, symbol: "bubble.left") }, showsLabel: false).frame(maxWidth: 300).disabled(bridge.reading || bridge.sending)
                if let thread = current {
                    Button { store.requestThreadRename(thread) } label: {
                        Image(systemName: "pencil").frame(width: 28, height: 30)
                    }.buttonStyle(InteractiveButton()).disabled(!bridge.canRenameThread(thread))
                        .help("重命名会话").accessibilityLabel("重命名会话")
                }
                Button { beginNew() } label: { Label("新会话", systemImage: "square.and.pencil") }.buttonStyle(QuietButton()).disabled(bridge.sending || bridge.reading)
                Spacer(minLength: 0)
                if let thread = current {
                    CockpitActionMenu(title: "更多会话操作", actions: [
                        .init(title: "立即整理到默认笔记", symbol: "arrow.triangle.2.circlepath", enabled: !store.defaultWritebackSources(area: area.id).isEmpty && bridge.connected && !bridge.reading && !bridge.sending && bridge.runningThreadID == nil && !bridge.needsRecovery) { store.organizeUsingDefaults(thread, area: area.id) },
                        .init(title: "整理到已有笔记…", symbol: "doc.text.below.ecg", enabled: bridge.connected && !bridge.reading && !bridge.sending && bridge.runningThreadID == nil && !bridge.needsRecovery) { store.requestConsolidation(thread, area: area.id) }
                    ])
                }
                Button { managing.toggle() } label: { Label("会话管理 · \(ids.count)", systemImage: managing ? "chevron.up" : "chevron.down").font(CockpitTypography.caption) }.buttonStyle(InteractiveButton()).foregroundStyle(theme.muted)
            }.padding(.horizontal, ChatLayout.contentInset)
            if managing { management.transition(.opacity) }
            if let error = bridge.error { Text(error).font(CockpitTypography.caption).foregroundStyle(theme.emphasis).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, ChatLayout.contentInset) }
            if !bridge.connected {
                HStack { Caption(text: "连接本机 Codex 后即可开始"); Button("连接") { Task { await bridge.connect() } }.buttonStyle(QuietButton()).disabled(bridge.connecting) }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, ChatLayout.contentInset)
            }
            ChatTranscript(bridge: bridge, thread: current, areaID: area.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            WorkComposer(bridge: bridge, thread: current, areaID: area.id, seedReady: seedReadyAreaID == area.id).id(current?.id ?? "new:" + area.id)
        }.frame(maxHeight: .infinity)
        .modifier(ChatColumn())
        .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.presentation, value: managing)
        .task(id: area.id + String(bridge.connected)) {
            guard bridge.connected else { return }
            // Consume a continuation only after the destination conversation is restored.
            // Otherwise the transient new-conversation composer takes the seed and disappears.
            defer { if !Task.isCancelled { seedReadyAreaID = area.id } }
            await bridge.resolveLinks(ids, refresh: true)
            guard !Task.isCancelled else { return }
            if let selected = bridge.selected, ids.contains(selected.id) { newConversation = false; await bridge.refreshVisibleHistory(); return }
            guard !newConversation else { return }
            if let thread = linked.first(where: { $0.id == store.lastAreaThread[area.id] }) ?? linked.first {
                store.lastAreaThread[area.id] = thread.id; await bridge.read(thread)
            }
        }
        .onChange(of: readObservation, initial: true) { _, _ in
            if !bridge.reading, let thread = current { store.markThreadViewed(thread.id, area: area.id) }
        }
        .onChange(of: bridge.selected?.id) { _, id in
            if let id, ids.contains(id) { newConversation = false; store.lastAreaThread[area.id] = id }
        }
    }
    private func beginNew() { seedReadyAreaID = area.id; newConversation = true; bridge.selected = nil; bridge.messages = [] }
    private var management: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let thread = current {
                    HStack {
                        Button("在 Codex 中打开") { Task { await bridge.openInCodex(thread) } }.buttonStyle(QuietButton()).disabled(!thread.isSaved)
                        Button("解除关联") { store.unlinkThread(thread.id, areaID: area.id); beginNew() }.buttonStyle(QuietButton())
                        Button("删除会话…") { store.managingThread = thread; store.sheet = .deleteThread }.buttonStyle(QuietButton()).disabled(bridge.runningThreadID == thread.id || bridge.sending)
                    }
                }
                HStack {
                    CockpitField(title: "搜索已有会话", text: $search, showsLabel: false).onSubmit { Task { await bridge.listThreads(search: search) } }
                    Button("搜索") { Task { await bridge.listThreads(search: search) } }.buttonStyle(QuietButton()).disabled(bridge.loading)
                }
                ForEach(bridge.threads.filter { !ids.contains($0.id) }) { thread in
                    HStack {
                        Text(thread.title).font(CockpitTypography.caption).lineLimit(1)
                        Spacer()
                        Button("关联") { store.linkThread(thread.id, areaID: area.id) }.buttonStyle(QuietButton())
                    }
                }
                if bridge.nextCursor != nil { Button("加载更多") { Task { await bridge.listThreads(more: true) } }.buttonStyle(QuietButton()).disabled(bridge.loading) }
            }.padding(ChatLayout.contentInset)
        }.frame(maxHeight: 180).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ChatTranscript: View {
    @Environment(\.chatTypography) private var typography
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    @ObservedObject var bridge: CodexBridge
    var thread: CodexThread?
    var areaID: String?
    // A stable reference: only the small navigation overlays observe scroll changes.
    @State private var viewport = TranscriptViewportState()
    @State private var expanded: Set<String> = []
    @State private var turns: [ConversationTurn] = []
    @State private var query = ""
    @State private var searching = false
    @State private var searchFocus = 0
    @State private var expandedProcesses: Set<String> = []
    @State private var scrollController = TranscriptScrollController()
    @State private var matchIndex = 0
    @State private var restoredThread: String?
    @State private var locating = false
    @State private var locationOperation = UUID()
    private var matches: [CodexMessage] { query.isEmpty ? [] : messages.filter { ConversationContext.visibleUserText($0.text).localizedCaseInsensitiveContains(query) } }
    private var messages: [CodexMessage] { guard let thread else { return [] }; return bridge.messages + (bridge.runningThreadID == thread.id ? bridge.liveMessages : []) }
    var body: some View {
        let visibleMessages = messages
        let entries = TranscriptEntry.index(visibleMessages, expanded: expandedProcesses)
        let replyingIDs: Set<String> = thread != nil && bridge.runningThreadID == thread?.id
            ? Set(bridge.liveMessages.filter { $0.role == "Codex" }.map(\.id)) : []
        let tail = visibleMessages.last.map { [$0.id, $0.text] }
        ScrollViewReader { proxy in
            VStack(spacing: 6) {
                if thread != nil {
                    HStack(spacing: 8) {
                        if searching {
                            CockpitField(title: "查找会话正文", text: $query, placeholder: "查找已加载的消息", showsLabel: false, focusRequest: searchFocus).frame(maxWidth: 260)
                                .onSubmit { jumpMatch(1, proxy: proxy) }
                            if !query.isEmpty {
                                Text("\(matches.count) 处").font(CockpitTypography.caption).foregroundStyle(theme.muted)
                                Button("上一处") { jumpMatch(-1, proxy: proxy) }.buttonStyle(InteractiveButton()).disabled(matches.isEmpty)
                                Button("下一处") { jumpMatch(1, proxy: proxy) }.buttonStyle(InteractiveButton()).disabled(matches.isEmpty)
                            }
                            Button { searching = false; query = "" } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                                .buttonStyle(InteractiveButton()).help("关闭查找（Esc）").accessibilityLabel("关闭查找")
                        }
                        Spacer(minLength: 4)
                        Button { Task { await bridge.refreshVisibleHistory(force: true) } } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                        }.buttonStyle(InteractiveButton()).help("读取 Codex 最新消息").accessibilityLabel("刷新会话")
                            .disabled(bridge.reading || bridge.refreshingHistory || bridge.loadingHistory || bridge.runningThreadID == thread?.id)
                        Text(bridge.refreshingHistory ? "正在刷新…" : bridge.readNotice).font(CockpitTypography.caption).foregroundStyle(theme.muted).lineLimit(1)
                        if bridge.historyCursor != nil {
                            Button(bridge.loadingHistory ? "正在读取…" : query.isEmpty ? "更早记录" : "向前查找") {
                                loadEarlier(proxy: proxy, search: !query.isEmpty)
                            }.buttonStyle(InteractiveButton()).font(CockpitTypography.caption)
                                .disabled(bridge.loadingHistory || bridge.reading || locating)
                        }
                        Button { searching = true; searchFocus += 1 } label: {
                            Image(systemName: "magnifyingglass").frame(width: 24, height: 24)
                        }.buttonStyle(InteractiveButton()).keyboardShortcut("f", modifiers: .command)
                            .help("查找会话（⌘F）").accessibilityLabel("查找会话")
                    }.padding(.horizontal, ChatLayout.contentInset)
                        .onExitCommand { searching = false; query = "" }
                }
            List {
                Group {
                    if thread == nil {
                        EmptyPanel(icon: "bubble.left.and.bubble.right", title: "从这里继续推进", detail: "从下方发送消息开始。点「给 AI 的背景」可查看随消息携带的目标、记忆和资料。")
                    } else if bridge.reading {
                        HStack { ProgressView().progressViewStyle(CockpitProgressStyle()); Caption(text: "正在读取会话…") }
                    } else if visibleMessages.isEmpty { Caption(text: "还没有消息，从下方开始。") }
                }.modifier(TranscriptRowLayout())
                // ForEach already provides the stable message identity used by scrollTo.
                // A second .id wrapper adds work to every List row/update.
                ForEach(entries) { entry in
                    TranscriptEntryCell(entry: entry, areaID: areaID, threadID: thread?.id, isReplying: replyingIDs.contains(entry.message.id),
                        expanded: Binding(get: { expanded.contains(entry.id) }, set: { value in
                            if value { expanded.insert(entry.id) } else { expanded.remove(entry.id) }
                        }), processExpanded: expandedProcesses.contains(entry.id), toggleProcess: {
                            viewport.followLatest = false; scrollController.cancelRestore()
                            if expandedProcesses.contains(entry.id) { expandedProcesses.remove(entry.id) }
                            else { expandedProcesses.insert(entry.id) }
                        }, copyText: copyText)
                }
                if let thread, bridge.runningThreadID == thread.id {
                    Group {
                        if let started = bridge.runningStartedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { clock in
                                Caption(text: bridge.runStatus + " · 已用 " + CodexTurnTiming.durationText(max(0, clock.date.timeIntervalSince(started))))
                            }
                        } else { Caption(text: bridge.runStatus) }
                    }.modifier(TranscriptRowLayout())
                }
                Color.clear.frame(height: 1).id("chat-bottom")
                    .listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollIndicators(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .background(TranscriptScrollTracking(turns: turns, entries: entries, rowOffset: thread == nil || bridge.reading || visibleMessages.isEmpty ? 1 : 0, controller: scrollController, report: { value in
                if restoredThread == thread?.id && !locating {
                    viewport.followLatest = value
                }
            }, reportTurn: { value in
                viewport.activeTurnID = value
            }, reportIdle: {
                rememberPosition(); store.flushReadingPosition()
            }, reportPosition: { anchor in
                if restoredThread == thread?.id && !locating && !bridge.loadingHistory { viewport.anchor = anchor }
            }, nearTop: {
                guard restoredThread == thread?.id, !locating, !bridge.reading, !bridge.loadingHistory,
                      let cursor = bridge.historyCursor, viewport.autoRequestedCursor != cursor else { return }
                viewport.autoRequestedCursor = cursor
                loadEarlier(proxy: proxy)
            }).frame(width: 0, height: 0))
            .task(id: (thread?.id ?? "") + String(bridge.reading) + String(visibleMessages.isEmpty)) {
                guard let thread, !bridge.reading, !visibleMessages.isEmpty else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                let operation = UUID(); locationOperation = operation; locating = true
                defer { if locationOperation == operation { locating = false } }
                if restoredThread != thread.id, let location = store.readingLocations[thread.id], !location.atLatest, let target = location.messageID {
                    viewport.followLatest = false
                    if let found = await bridge.locateMessage(target), !Task.isCancelled, self.thread?.id == thread.id {
                        let group = TranscriptEntry.groupID(containing: found, in: messages)
                        if location.toolDetails == true, let group { expandedProcesses.insert(group) }
                        let row = location.toolDetails == true ? found : group ?? found
                        await Task.yield()
                        proxy.scrollTo(row, anchor: .top)
                        if let offset = location.offset {
                            await scrollController.restore(.init(rowID: row, messageID: found, offset: offset,
                                rowHeight: location.rowHeight ?? 0, contentWidth: location.contentWidth ?? 0, toolDetails: location.toolDetails == true))
                        }
                    }
                } else if viewport.followLatest { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                guard !Task.isCancelled, self.thread?.id == thread.id else { return }
                restoredThread = thread.id
                viewport.anchor = scrollController.capture()
            }
            .onChange(of: store.requestedMessageID) { _, target in
                guard let target, visibleMessages.contains(where: { $0.id == target }) else { return }
                restoredThread = thread?.id; jump(to: target, proxy: proxy); store.requestedMessageID = nil
            }
            .task(id: query) {
                guard !query.isEmpty else { return }
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                matchIndex = 0
                if let first = matches.first { jump(to: first.id, proxy: proxy) }
            }
            .onChange(of: tail) { _, _ in
                if viewport.followLatest, !locating, restoredThread == thread?.id, !visibleMessages.isEmpty { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: bridge.reading) { _, reading in
                if reading { rememberPosition(threadID: restoredThread); store.flushReadingPosition(); restoredThread = nil }
            }
            .onChange(of: thread?.id) { old, _ in
                if let old { rememberPosition(threadID: old); store.flushReadingPosition() }
                scrollController.cancelRestore()
                locationOperation = UUID(); locating = false
                viewport.followLatest = true; viewport.activeTurnID = nil; viewport.anchor = nil; viewport.autoRequestedCursor = nil
                restoredThread = nil; query = ""; expandedProcesses = []; searching = false
            }
            .onDisappear { rememberPosition(); store.flushReadingPosition(); scrollController.cancelRestore() }
            .onChange(of: entries.map(\.id), initial: true) { _, _ in
                // Do not rebuild previews for every assistant token or scroll position.
                turns = ConversationTurn.index(entries.map(\.message))
            }
            .overlay(alignment: .bottomTrailing) {
                TranscriptLatestButton(viewport: viewport, hasMessages: !visibleMessages.isEmpty) {
                    scrollController.cancelRestore()
                    viewport.followLatest = true
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .overlay(alignment: .trailing) {
                if turns.count > 1 && !bridge.reading {
                    TranscriptTurnNavigation(viewport: viewport, turns: turns) { id in
                        viewport.followLatest = false
                        viewport.activeTurnID = id
                        scrollController.cancelRestore(); proxy.scrollTo(id, anchor: .top)
                    }.offset(x: ChatLayout.navigationGutter)
                }
            }
            }
        }
    }
    private func rememberPosition(threadID: String? = nil) {
        guard let id = threadID ?? thread?.id, restoredThread == id, !locating, !bridge.loadingHistory else { return }
        let anchor = viewport.anchor
        store.rememberReading(thread: id, message: anchor?.messageID ?? viewport.activeTurnID, latest: viewport.followLatest,
            offset: anchor?.offset, rowHeight: anchor?.rowHeight, contentWidth: anchor?.contentWidth, toolDetails: anchor?.toolDetails, deferSave: true)
    }
    private func loadEarlier(proxy: ScrollViewProxy, search: Bool = false) {
        guard !locating, !bridge.loadingHistory, let id = thread?.id, bridge.historyCursor != nil else { return }
        viewport.followLatest = false
        var anchor = scrollController.capture() ?? viewport.anchor
        let previousMatches = matches.count
        let operation = UUID(); locationOperation = operation; locating = true
        Task {
            defer { if locationOperation == operation { locating = false } }
            for _ in 0..<(search ? 100 : 1) {
                let cursor = bridge.historyCursor
                await bridge.loadEarlier {
                    // A slow page request must preserve where the user has scrolled
                    // meanwhile, rather than pulling them back to the request origin.
                    if !search { anchor = scrollController.capture() ?? anchor }
                }
                guard !Task.isCancelled, locationOperation == operation, bridge.selected?.id == id else { return }
                if cursor == bridge.historyCursor || bridge.historyCursor == nil || matches.count > previousMatches { break }
            }
            if let anchor {
                await Task.yield()
                proxy.scrollTo(anchor.rowID, anchor: .top)
                await scrollController.restore(anchor)
                viewport.anchor = scrollController.capture() ?? anchor
            }
        }
    }
    private func jump(to id: String, proxy: ScrollViewProxy) {
        viewport.followLatest = false; scrollController.cancelRestore()
        if let group = TranscriptEntry.groupID(containing: id, in: messages) { expandedProcesses.insert(group) }
        let threadID = thread?.id
        Task { @MainActor in
            // The expanded tool must enter List before ScrollViewReader can find it.
            try? await Task.sleep(for: .milliseconds(20))
            guard thread?.id == threadID else { return }
            proxy.scrollTo(id, anchor: .top)
        }
    }
    private func jumpMatch(_ offset: Int, proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + offset + matches.count) % matches.count
        jump(to: matches[matchIndex].id, proxy: proxy)
    }
    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(text, forType: .string)
        store.notify(copied ? "已复制" : "复制失败，请重试")
    }
}
private struct TranscriptEntryCell: View {
    @Environment(\.cockpitTheme) private var theme
    let entry: TranscriptEntry
    let areaID: String?
    let threadID: String?
    let isReplying: Bool
    @Binding var expanded: Bool
    var processExpanded: Bool
    var toggleProcess: () -> Void
    let copyText: (String) -> Void
    var body: some View {
        // A concrete single-row container lets List count rows without expanding
        // every conditional message/process body during its initial pass.
        VStack(alignment: .leading, spacing: 0) {
            if entry.isProcess {
                Button(action: toggleProcess) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").font(.system(size: 12))
                        Text("执行过程 · \(entry.tools.count) 项")
                        Image(systemName: processExpanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    }.font(CockpitTypography.caption).foregroundStyle(theme.muted).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(InteractiveButton()).accessibilityLabel("\(processExpanded ? "收起" : "展开")执行过程，共 \(entry.tools.count) 项")
                    .accessibilityAction(named: Text("切换执行过程"), toggleProcess)
            } else if entry.message.isTool {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("工具详情").font(CockpitTypography.caption).foregroundStyle(theme.muted)
                        Spacer()
                        Button { copyText(entry.message.text) } label: { Image(systemName: "square.on.square").frame(width: 24, height: 24) }
                            .buttonStyle(InteractiveButton()).help("复制工具详情").accessibilityLabel("复制工具详情")
                    }
                    SelectableMessageText(text: entry.message.text, code: true, copySelection: copyText, saveSelection: nil)
                    ForEach(entry.message.attachments, id: \.self) { AttachmentPreview(path: $0) }
                }.padding(12).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
            } else {
                ChatMessageRow(message: entry.message, text: entry.message.role == "你" ? ConversationContext.visibleUserText(entry.message.text) : entry.message.text,
                               areaID: areaID, threadID: threadID, isReplying: isReplying, expanded: $expanded, copyText: copyText)
            }
        }.selectionDisabled().accessibilityElement(children: .contain).modifier(TranscriptRowLayout())
    }
}

/// Scroll telemetry must never invalidate the virtualized transcript or the app store.
@MainActor final class TranscriptViewportState: ObservableObject {
    @Published var followLatest = true
    @Published var activeTurnID: String?
    var anchor: TranscriptAnchor?
    var autoRequestedCursor: String?
}
private struct TranscriptTurnNavigation: View {
    @ObservedObject var viewport: TranscriptViewportState
    let turns: [ConversationTurn]
    var select: (String) -> Void
    var body: some View { ConversationTurnRail(turns: turns, activeID: viewport.activeTurnID, select: select) }
}
private struct TranscriptLatestButton: View {
    @ObservedObject var viewport: TranscriptViewportState
    var hasMessages: Bool
    var action: () -> Void
    var body: some View {
        if !viewport.followLatest && hasMessages {
            Button("回到最新", action: action).buttonStyle(QuietButton()).padding(ChatLayout.contentInset)
        }
    }
}

struct MessageContent: View {
    @Environment(\.chatTypography) private var typography
    @Environment(\.cockpitTheme) var theme
    var text: String
    var copySelection: (String) -> Void
    var saveSelection: ((String) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MessageMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    ScrollView([.horizontal, .vertical]) {
                        SelectableMessageText(text: code, code: true, copySelection: copySelection, saveSelection: saveSelection).fixedSize().padding(10)
                    }.defaultScrollAnchor(.topLeading).frame(height: min(320, max(42, CGFloat(code.components(separatedBy: "\n").count) * typography.codeLineHeight + 20))).background(theme.soft, in: RoundedRectangle(cornerRadius: 8))
                case .text(let prose):
                    SelectableMessageText(text: prose, copySelection: copySelection, saveSelection: saveSelection).frame(maxWidth: .infinity, alignment: .leading)
                case .table(let table):
                    MessageTableView(table: table, copySelection: copySelection, saveSelection: saveSelection)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

