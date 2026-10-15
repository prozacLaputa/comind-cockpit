import SwiftUI
import Foundation

enum WorkspaceSearchTarget: Hashable {
    case original(UUID), document(UUID), capture(UUID), memory(UUID), thread(String, String?)
}
struct WorkspaceSearchResult: Identifiable {
    var target: WorkspaceSearchTarget
    var title: String
    var excerpt: String
    var areaID: String
    var kind: String
    var id: WorkspaceSearchTarget { target }
    var symbol: String { switch kind { case "资料": "doc.text"; case "随手记": "note.text"; case "记忆": "brain"; default: "bubble.left.and.bubble.right" } }
}
struct WorkspaceSearchSnapshot {
    var documents: [DocumentRecord]
    var captures: [CaptureRecord]
    var memories: [EmployeeMemory]
    var links: [ThreadLink]
    var threads: [String: CodexThread]
    var connection: CoMindConnection? = nil
    var scope: String? = nil
}
struct WorkspaceSearchPage {
    var results: [WorkspaceSearchResult]
    var unreadable: [String]
    var checked: Int
}

/// 仅索引明确关联的文件；缓存随搜索窗口释放，不写另一份知识库。
actor WorkspaceSearchIndex {
    private struct CachedFile { var url: URL; var date: Date?; var size: Int?; var text: String }
    private var files: [UUID: CachedFile] = [:]
    static func excerpt(_ text: String, query: String) -> String {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(text.prefix(160)) }
        let start = text.index(range.lowerBound, offsetBy: -35, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 110, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + String(text[start..<end]) + (end == text.endIndex ? "" : "…")
    }
    func search(_ snapshot: WorkspaceSearchSnapshot, query: String) throws -> WorkspaceSearchPage {
        files = files.filter { id, _ in snapshot.documents.contains { $0.id == id } }
        var results: [WorkspaceSearchResult] = [], unreadable: [String] = []
        func add(_ target: WorkspaceSearchTarget, _ title: String, _ body: String, _ area: String, _ kind: String) {
            guard title.localizedStandardContains(query) || body.localizedStandardContains(query) else { return }
            results.append(.init(target: target, title: title, excerpt: Self.excerpt(body, query: query), areaID: area, kind: kind))
        }
        var originalURLs = Set<URL>()
        if let connection = snapshot.connection {
            for source in connection.sources {
                try Task.checkCancellation()
                let title = CoMindFiles.title(source, connection: connection)
                let area = snapshot.scope ?? source.areas.sorted().first ?? ""
                var body = source.path
                do {
                    let file = try CoMindFiles.url(source.path, in: connection.repository).standardizedFileURL.resolvingSymlinksInPath()
                    guard originalURLs.insert(file).inserted else { continue }
                    // Read fresh bytes on each explicit query; metadata timestamps alone can miss equal-size edits.
                    body += "\n" + (try CoMindFiles.read(source.path, in: connection.repository)).text
                } catch { unreadable.append(title); body += "\n正文暂不可读，请检查原文件位置。" }
                add(.original(source.id), title, body, area, "资料")
            }
        }
        for doc in snapshot.documents {
            if let url = doc.localURL, originalURLs.contains(url.standardizedFileURL.resolvingSymlinksInPath()) { continue }
            try Task.checkCancellation()
            var body = doc.body
            if var url = doc.localURL {
                do {
                    url.removeAllCachedResourceValues()
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    if let cached = files[doc.id], cached.url == url, cached.date == values.contentModificationDate, cached.size == values.fileSize {
                        body = cached.text
                    } else {
                        body = try AppStore.documentText(doc)
                        if files.values.reduce(0, { $0 + $1.text.utf8.count }) + body.utf8.count > 16_000_000 { files.removeAll() }
                        files[doc.id] = .init(url: url, date: values.contentModificationDate, size: values.fileSize, text: body)
                    }
                } catch { files.removeValue(forKey: doc.id); unreadable.append(doc.name); body = "正文暂不可读，可打开资料重新定位文件。" }
            }
            add(.document(doc.id), doc.name, body, doc.areaID, "资料")
        }
        for note in snapshot.captures { try Task.checkCancellation(); add(.capture(note.id), String(note.text.prefix(36)), note.text, note.areaID, "随手记") }
        for memory in snapshot.memories {
            try Task.checkCancellation()
            let status = memory.state == .active ? "已确认" : "待核对"
            add(.memory(memory.id), memory.topic + " · " + status, memory.text, memory.areaID, "资料")
        }
        var seen: Set<String> = []
        for link in snapshot.links where seen.insert(link.threadID).inserted {
            if let thread = snapshot.threads[link.threadID] { add(.thread(thread.id, nil), thread.title, "打开关联会话", link.areaID, "会话") }
        }
        return .init(results: results, unreadable: unreadable, checked: (snapshot.connection?.sources.count ?? 0) + snapshot.documents.count + snapshot.captures.count + snapshot.memories.count)
    }
}

extension AppStore {
    func searchSnapshot(scope: String?) -> WorkspaceSearchSnapshot {
        let allowed = Set(areas.map(\.id) + [""])
        func inScope(_ id: String) -> Bool { scope.map { $0 == id } ?? allowed.contains(id) }
        var connection = coMind
        let sources = connection?.sources.filter { $0.areas.contains(where: inScope) } ?? []
        connection?.sources = sources
        return .init(documents: documents.filter { inScope($0.areaID) || $0.linkedAreas.contains(where: inScope) },
                     captures: captures.filter { inScope($0.areaID) },
                     memories: employeeMemories.filter { inScope($0.areaID) && [.active, .pending].contains($0.state) },
                     links: threadLinks.filter { inScope($0.areaID) }, threads: codex.threadMap, connection: connection, scope: scope)
    }
    func openSearchResult(_ result: WorkspaceSearchResult) {
        sheet = nil
        switch result.target {
        case .original(let id):
            guard let source = coMind?.sources.first(where: { $0.id == id }), source.areas.contains(result.areaID), areas.contains(where: { $0.id == result.areaID }) || result.areaID.isEmpty else { notify("此资料的关联已变化，请重新搜索"); return }
            openCoMindSource(source)
        case .document(let id): filePreview = documents.first { $0.id == id }
        case .capture(let id): editingCaptureID = id; sheet = .editCapture
        case .memory(let id): editingMemoryID = id; editingAreaID = result.areaID; sheet = .memory
        case .thread(let id, let messageID):
            if areas.contains(where: { $0.id == result.areaID }) { lastAreaThread[result.areaID] = id; openArea(result.areaID) }
            else { navigate(.codex) }
            Task {
                await codex.resolveLinks([id])
                guard let thread = codex.threadMap[id] else { notify("原会话暂不可用"); return }
                // 等待区域导航正在恢复的读取；用户转向别处时不抢回焦点。
                while codex.reading { try? await Task.sleep(for: .milliseconds(40)) }
                guard areaID == result.areaID || (areaID == nil && page == .codex) else { return }
                await codex.read(thread)
                if let messageID {
                    if let found = await codex.locateMessage(messageID) { requestedMessageID = found }
                    else { notify("已打开原会话；该消息暂未定位，可继续加载历史") }
                }
            }
        }
    }
}

extension CodexBridge {
    /// 独立读取检索页，不切换当前会话、不启动或恢复执行。
    func searchHistoryPage(thread id: String, cursor: String?) async throws -> (CodexThread, [CodexMessage], String?) {
        let metadata = try await call("thread/read", ["threadId": id, "includeTurns": false])
        guard let raw = metadata["thread"] as? [String: Any], let thread = CodexThread(raw), thread.id == id else { throw BridgeError(message: "会话不可读") }
        guard thread.isSaved else { return (thread, [], nil) }
        if raw["historyMode"] as? String == "paginated" {
            var params: [String: Any] = ["threadId": id, "limit": 20, "sortDirection": "desc", "itemsView": "full"]
            if let cursor { params["cursor"] = cursor }
            let response = try await call("thread/turns/list", params)
            guard let turns = response["data"] as? [[String: Any]] else { throw BridgeError(message: "Codex 未返回有效的消息列表") }
            return (thread, Self.historyMessages(from: Array(turns.reversed())), response["nextCursor"] as? String)
        }
        let response = try await call("thread/read", ["threadId": id, "includeTurns": true])
        return (thread, Self.historyMessages(from: (response["thread"] as? [String: Any])?["turns"] as? [[String: Any]] ?? []), nil)
    }
}

@MainActor final class WorkspaceSearchModel: ObservableObject {
    @Published var local: [WorkspaceSearchResult] = []
    @Published var chats: [WorkspaceSearchResult] = []
    @Published var searching = false
    @Published var searchingChats = false
    @Published var notice = ""
    @Published var chatNotice = ""
    @Published var hasEarlier = false
    private let index = WorkspaceSearchIndex()
    private var generation = UUID()
    private var chatTask: Task<Void, Never>?
    private var cursors: [String: String] = [:]
    private var finished: Set<String> = []
    private var visitedCursors: [String: Set<String>] = [:]
    private var pages = 0
    func cancel() { generation = UUID(); chatTask?.cancel(); chatTask = nil; searchingChats = false }
    func search(_ snapshot: WorkspaceSearchSnapshot, query: String) async {
        cancel(); let token = generation
        local = []; chats = []; cursors = [:]; finished = []; visitedCursors = [:]; pages = 0; hasEarlier = false; chatNotice = ""; notice = ""
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searching = false; return }
        searching = true
        defer { if generation == token { searching = false } }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let page = try await index.search(snapshot, query: query)
            guard generation == token, !Task.isCancelled else { return }
            local = page.results
            notice = "已查找 \(page.checked) 条原笔记 / 资料 / 随手记，以及已读取的关联会话名称。"
            if !page.unreadable.isEmpty { notice += " \(page.unreadable.count) 份文件正文不可读：" + page.unreadable.joined(separator: "、") }
        } catch is CancellationError {} catch { if generation == token { notice = error.localizedDescription } }
    }
    func searchChats(_ snapshot: WorkspaceSearchSnapshot, query: String, bridge: CodexBridge) {
        guard !searchingChats, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = generation
        searchingChats = true; hasEarlier = true
        chatTask = Task {
            defer { if generation == token { searchingChats = false } }
            let ids = Array(Set(snapshot.links.map(\.threadID))).sorted()
            var failures: [String] = []
            for id in ids where !finished.contains(id) {
                do {
                    try Task.checkCancellation()
                    let oldCursor = cursors[id]
                    let (thread, messages, cursor) = try await bridge.searchHistoryPage(thread: id, cursor: oldCursor)
                    guard generation == token, !Task.isCancelled else { return }
                    for message in messages where !message.isTool {
                        let text = ConversationContext.visibleUserText(message.text)
                        guard text.localizedStandardContains(query) else { continue }
                        let target = WorkspaceSearchTarget.thread(id, message.id)
                        if !chats.contains(where: { $0.target == target }) {
                            chats.append(.init(target: target, title: thread.title + " · " + message.role, excerpt: WorkspaceSearchIndex.excerpt(text, query: query), areaID: snapshot.links.first { $0.threadID == id }?.areaID ?? "", kind: "会话"))
                        }
                    }
                    pages += 1
                    if let cursor, cursor != oldCursor, !(visitedCursors[id] ?? []).contains(cursor) {
                        cursors[id] = cursor; visitedCursors[id, default: []].insert(cursor)
                    } else { finished.insert(id); cursors.removeValue(forKey: id) }
                } catch is CancellationError { return }
                catch { guard generation == token else { return }; failures.append(snapshot.threads[id]?.title ?? "关联会话") }
                guard generation == token else { return }
                chatNotice = "已读取 \(pages) 页会话文字；不包含工具输出或图片。"
            }
            guard generation == token else { return }
            hasEarlier = ids.contains { !finished.contains($0) }
            chatNotice += hasEarlier ? " 尚有更早记录或失败页可继续查找。" : " 已到所选关联会话的最早记录。"
            if !failures.isEmpty { chatNotice += " 暂未读取：" + failures.joined(separator: "、") }
        }
    }
}

struct WorkspaceSearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @StateObject private var model = WorkspaceSearchModel()
    @State private var query = ""
    @State private var scope = "all"
    @State private var kind = "全部"
    @State private var refresh = 0
    private var snapshot: WorkspaceSearchSnapshot { store.searchSnapshot(scope: scope == "all" ? nil : scope) }
    private var results: [WorkspaceSearchResult] { (model.local + model.chats).filter { kind == "全部" || $0.kind == kind } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CockpitField(title: "统一搜索", text: $query, placeholder: "找原笔记、资料或聊过的内容…", symbol: "magnifyingglass", showsLabel: false, focusRequest: 1)
            HStack {
                CockpitSelect(title: "搜索范围", selection: $scope, options: [.init(id: "all", label: "全部阵地与未归类资料")] + store.areas.map { .init(id: $0.id, label: $0.name, symbol: $0.symbol) }, showsLabel: false)
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(QuietButton()).help("重新读取已关联资料")
            }
            CockpitSegments(title: "内容类型", selection: $kind, options: ["全部", "资料", "随手记", "会话"].map { .init(id: $0, label: $0) })
            if model.searching { Label("正在查找…", systemImage: "magnifyingglass").font(CockpitTypography.caption) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(results.prefix(200))) { result in
                        Button { store.openSearchResult(result) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: result.symbol).foregroundStyle(theme.accent).frame(width: 18)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.title).font(CockpitTypography.body).lineLimit(1)
                                    Text(result.excerpt).font(CockpitTypography.caption).foregroundStyle(theme.muted).lineLimit(3)
                                    Text(result.kind + " · " + store.areaName(result.areaID)).font(CockpitTypography.caption).foregroundStyle(theme.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").foregroundStyle(theme.muted)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(InteractiveButton())
                    }
                    if results.isEmpty && !model.searching { Caption(text: query.isEmpty ? "默认查找当前阵地；切换范围可跨阵地查找。只读已关联内容，不扫描文件夹，也不调用 AI。" : "当前已读取范围内暂无匹配内容。") }
                }
            }.frame(height: 320)
            if results.count > 200 { Caption(text: "共 \(results.count) 条匹配，显示前 200 条；可缩小范围或补充关键词。") }
            if !model.notice.isEmpty { Caption(text: model.notice) }
            HStack {
                Button(model.searchingChats ? "正在读取会话…" : model.hasEarlier ? "继续向前查找 / 重试" : "查找关联会话正文") { model.searchChats(snapshot, query: query.trimmingCharacters(in: .whitespacesAndNewlines), bridge: store.codex) }
                    .buttonStyle(OutlinedButton()).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.searching || model.searchingChats || !store.codex.connected || snapshot.links.isEmpty)
                if model.searchingChats { Button("停止查找") { model.cancel() }.buttonStyle(QuietButton()) }
            }
            if !model.chatNotice.isEmpty { Caption(text: model.chatNotice) }
            Caption(text: "会话正文按每个会话 20 轮逐页查找；不会切换正在工作的会话，不消耗模型额度。")
        }.onAppear { scope = store.areaID ?? "all" }
            .task(id: query + "|" + scope + "|" + String(refresh) + "|" + String(describing: store.coMind)) { await model.search(snapshot, query: query) }
            .onDisappear { model.cancel() }
    }
}
