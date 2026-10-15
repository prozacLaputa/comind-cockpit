import Foundation

@main struct WorkspaceSearchSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fake_workspace_codex.py")
        let bridge = CodexBridge(executableOverride: fixture)
        await bridge.connect(); defer { bridge.disconnect() }
        let store = AppStore(storageURL: root.appendingPathComponent("state.json"), codexBridge: bridge)
        store.areas = [.init(id: "a", name: "A", purpose: ""), .init(id: "b", name: "B", purpose: "")]
        let file = root.appendingPathComponent("fixture.md")
        try "needle 外部正文 👋".write(to: file, atomically: true, encoding: .utf8)
        let doc = DocumentRecord(name: "fixture.md", areaID: "a", source: "本地文件", path: file.path, body: "", localURL: file)
        store.documents = [doc, .init(name: "不在范围", areaID: "b", source: "本地文件", path: "/does-not-exist", body: "", localURL: URL(fileURLWithPath: "/does-not-exist"))]
        store.captures = [.init(text: "needle 随手记", areaID: "a"), .init(text: "needle 另一个范围", areaID: "b")]
        store.employeeMemories = [.init(areaID: "a", topic: "needle 记忆", text: "已核对", category: .fact, state: .active, sources: [], proposalKey: "fixture")]
        store.threadLinks = [.init(areaID: "a", threadID: "activity-0")]
        let snapshot = store.searchSnapshot(scope: "a")
        let index = WorkspaceSearchIndex()
        let result = try await index.search(snapshot, query: "needle")
        precondition(result.results.count == 3 && result.unreadable.isEmpty, "匹配：\(result.results.map(\.kind))，不可读：\(result.unreadable)")
        precondition(result.results.allSatisfy { $0.areaID == "a" })
        try "新版本 new-content".write(to: file, atomically: true, encoding: .utf8)
        let newer = try await index.search(snapshot, query: "new-content")
        precondition(newer.results.count == 1 && newer.results[0].target == .document(doc.id))
        try FileManager.default.removeItem(at: file)
        let missing = try await index.search(snapshot, query: "needle")
        precondition(missing.unreadable == [doc.name] && !missing.results.contains { $0.target == .document(doc.id) })
        let original = try await bridge.searchHistoryPage(thread: "activity-9", cursor: nil).0
        await bridge.read(original)
        let visible = bridge.messages.map(\.id)
        let model = WorkspaceSearchModel()
        await model.search(snapshot, query: "needle")
        model.searchChats(snapshot, query: "needle", bridge: bridge)
        for _ in 0..<100 where model.searchingChats { try await Task.sleep(for: .milliseconds(10)) }
        precondition(model.chats.count == 1 && !model.hasEarlier)
        precondition(bridge.selected?.id == original.id && bridge.messages.map(\.id) == visible, "查找不能切换工作会话")
        await model.search(store.searchSnapshot(scope: "b"), query: "needle")
        precondition(model.chats.isEmpty && model.local.allSatisfy { $0.areaID == "b" })
        model.cancel()
        print("PASS: 授权范围隔离、外部正文、变更/删除失效、记忆与随手记、会话正文只读定位、切换范围清理结果")
    }
}
