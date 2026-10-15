import Foundation

@main struct NoteActivitySmoke {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("note-activity-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        func put(_ path: String, _ body: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url, options: .atomic)
        }
        func check(_ pass: Bool, _ message: String, line: UInt = #line) { precondition(pass, "line \(line): " + message) }
        func reject(_ operation: () throws -> Void) { do { try operation(); fatalError("expected refusal") } catch {} }
        let text = """
        # 合成主题

        既有手动原文必须保留。

        ## 待你核对
        - 哪种读书节奏？[^来源]
          - AI 的旧推断，不作为事实。
        ```md
        - 这不是核对项
        # 不是新章节
        ```
        <!--
        - 隐藏示例
        -->
        - 已确认的旧说法是否准确？
        - 已核对 · 昨天：确认过了。
          - 原核对记录：旧问题。

        ## 正文
        - 待确认：是否再建清单？

        [^来源]: [合成会话](codex://threads/fixture) · 2026-01-01 · AI 推断
        """
        check(NoteReview.entries(text).count == 3, "ignore fenced/commented/history content without skipping open questions")
        try put("corpus/README.md", "synthetic")
        try put("protocols/agent-contract.md", "synthetic")
        try put("protocols/write-policy.md", "synthetic")
        try put(".local/knowledge-sources.json", "{\"notes_root\":\"\(root.appendingPathComponent("notes").path)\"}")
        try put("notes/.comind/registry.json", "{\"version\":1,\"documents\":[{\"id\":\"fixture\",\"path\":\"主题.md\",\"aliases\":[]}]}")
        try put("notes/主题.md", text)
        try put("notes/每日日记/2026-01-01.md", "DIARY_UNTOUCHED")
        try put(CoMindFiles.memory, "# 协作规则")
        let repo = (0..<3).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let tool = "tools/scripts/knowledge-bridge/bridge.py"
        try put(tool, String(contentsOf: repo.appendingPathComponent(tool), encoding: .utf8))
        let service = CodexBridge(executableOverride: URL(fileURLWithPath: CommandLine.arguments[1]))
        let store = AppStore(storageURL: root.appendingPathComponent("state.json"), codexBridge: service)
        store.areas = [.init(id: "a", name: "合成 A", purpose: ""), .init(id: "b", name: "合成 B", purpose: "")]
        try store.connectCoMind(root)
        try store.attachCoMindSource(path: "note:fixture", area: "a")
        try store.attachCoMindSource(path: "note:fixture", area: "b")
        try store.attachCoMindSource(path: CoMindFiles.memory, area: "a")
        try store.attachCoMindSource(path: "notes/每日日记/2026-01-01.md", area: "a")
        let source = store.coMindSources(for: "a").first { $0.path == "note:fixture" }!
        let version = try CoMindFiles.read(source.path, in: root), entry = NoteReview.entries(text)[0]
        reject { _ = try NoteReview.resolve(entry, version: version, conclusion: "", ignore: false) }
        let confirmed = try NoteReview.resolve(entry, version: version, conclusion: "每周读两次。", ignore: false)
        check(confirmed.contains("每周读两次。[^来源]") && confirmed.contains("    - 哪种读书节奏？[^来源]"), "preserve source and old question")
        check(confirmed.contains("既有手动原文必须保留。"), "do not overwrite unrelated prose")
        let history = try CoMindFiles.commit(.init(before: version, after: confirmed))!
        check(try String(contentsOf: history, encoding: .utf8) == text, "original history stays with note")
        let update = try NoteUpdate.load(source, repository: root)!
        check(update.difference.added.contains("每周读两次。") && update.difference.removed.contains("哪种读书节奏"), "actual file difference")
        reject { _ = try CoMindFiles.commit(.init(before: version, after: "stale overwrite")) }
        var current = try CoMindFiles.read(source.path, in: root)
        for pending in NoteReview.entries(current.text).reversed() {
            let after = try NoteReview.resolve(pending, version: current, conclusion: nil, ignore: true)
            try CoMindFiles.commit(.init(before: current, after: after)); current = try CoMindFiles.read(source.path, in: root)
        }
        check(SourceReviewLocations.find(in: current.text).isEmpty, "closed originals no longer signal pending")
        store.refreshOriginalActivity(); await store.originalActivityTask?.value
        check(store.areaNotice("a") == .none, "baseline does not mark old files unread")
        try CoMindFiles.commit(.init(before: current, after: current.text + "\n本人新增合成事实。"))
        // Atomic external saves must trigger the parent-directory watcher without a model or manual refresh.
        for _ in 0..<30 where store.areaNotice("b") != .unread { try await Task.sleep(for: .milliseconds(100)) }
        check(store.areaNotice("a") == .unread && store.areaNotice("b") == .unread, "same original marks each linked area unread")
        let latest = try CoMindFiles.read(source.path, in: root)
        store.markSourcesViewed([source], versions: [source.id: latest.sha256], area: "a")
        check(store.areaNotice("a") == .none && store.areaNotice("b") == .unread, "reading one area does not clear another")
        let reopened = AppStore(storageURL: store.storageURL)
        check(reopened.areaSeen == store.areaSeen, "read markers survive restart")
        let persisted = try String(contentsOf: store.storageURL, encoding: .utf8)
        check(!persisted.contains("本人新增合成事实") && !persisted.contains("哪种读书节奏"), "only metadata persisted, no extra knowledge store")
        let thread = CodexThread(["id": "fixture", "name": "合成会话", "updatedAt": 1.0])!
        store.threadLinks = [.init(areaID: "a", threadID: thread.id)]
        store.codex.threadMap[thread.id] = thread; store.observeThreadActivity()
        store.codex.threadMap[thread.id] = CodexThread(["id": "fixture", "name": "合成会话", "updatedAt": 2.0])!
        check(store.areaNotice("a") == .unread, "new thread update produces unread")
        store.openAreaNotice("a")
        check(store.areaTab == "开始工作" && store.lastAreaThread["a"] == thread.id, "status opens the changed conversation")
        store.markThreadViewed(thread.id, area: "a")
        check(store.areaNotice("a") == .unread, "metadata alone must not clear unread")
        store.codex.selected = store.codex.threadMap[thread.id]
        store.codex.loadedHistoryUpdated[thread.id] = store.codex.threadMap[thread.id]!.updated
        store.markThreadViewed(thread.id, area: "a")
        check(store.areaNotice("a") == .none, "viewed reply clears unread")
        store.codex.runningThreadID = thread.id
        check(store.areaNotice("a") == .working && store.areaNotice("b") == .unread, "running status scoped to its own area")
        store.codex.runningThreadID = nil
        let draft = "DO_NOT_SEND_OR_CLEAR_DRAFT"
        store.conversationDrafts[thread.id] = draft
        let message = try await store.consolidationMessage(thread: thread, area: "a", sources: [source.id])
        check(message.contains("本人新增合成事实") && message.contains("不修改后台来源登记") && message.contains("--expected-sha256"), "one-shot request contains fresh originals and guarded writeback")
        check(!message.contains("DIARY_UNTOUCHED"), "unselected source not included")
        check(store.conversationDrafts[thread.id] == draft && store.coMind!.selectedSources(for: "a").isEmpty, "manual request preserves draft and background grants")
        for target in store.coMindSources(for: "a").filter({ $0.id != source.id }) {
            do { _ = try await store.consolidationMessage(thread: thread, area: "a", sources: [target.id]); fatalError("rules/diary must be rejected") } catch {}
        }
        do { _ = try await store.consolidationMessage(thread: thread, area: "b", sources: [source.id]); fatalError("unlinked thread must be rejected") } catch {}
        try CoMindFiles.commit(.init(before: latest, after: version.text))
        check(try CoMindFiles.read(source.path, in: root).text == text, "guarded restore recovers original bytes")
        await service.connect()
        let defaults = try await service.inspectModels(cwd: root.path, threadID: nil).inherited
        guard let freshThread = await service.newThread(cwd: root) else { fatalError("fake thread creation") }
        store.threadLinks = [.init(areaID: "a", threadID: freshThread.id)]
        let request = try await store.consolidationMessage(thread: freshThread, area: "a", sources: [source.id])
        store.manualConsolidationThreads.insert(freshThread.id)
        let sent = await service.send(request, to: freshThread, modelSelection: .init(model: "fixture-fast", effort: "low"), refreshText: {
            try await store.consolidationMessage(thread: freshThread, area: "a", sources: [source.id])
        })
        check(sent, "manual consolidation uses existing send flow")
        for _ in 0..<100 where service.approvals.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        check(service.approvals.count == 1 && store.areaNotice("a") == .attention, "existing approval remains explicit")
        service.answerApproval(service.approvals[0], accept: false)
        for _ in 0..<100 where service.runningThreadID != nil { try await Task.sleep(for: .milliseconds(20)) }
        check(store.manualConsolidationThreads.isEmpty && store.reviewingAreas.isEmpty, "manual request does not launch another summarizer")
        check(try await service.inspectModels(cwd: root.path, threadID: nil).inherited == defaults && store.conversationDrafts[thread.id] == draft, "default model and draft preserved")
        check(try CoMindFiles.read(source.path, in: root).text == text, "denied write never claims or changes original")
        service.disconnect()
        store.originalWatcher.replace([]) {}; store.originalActivityTask?.cancel()
        print("NoteActivitySmoke PASS: parsing, explicit review, provenance/history/conflict/restore, atomic file watcher, scoped unread persistence, guarded manual request, drafts and grants preserved; synthetic files cleaned")
    }
}
