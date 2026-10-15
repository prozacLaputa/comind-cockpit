import Foundation

@main struct DailyUseSmoke {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cockpit-daily-\(UUID())").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        func put(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
        let state = root.appendingPathComponent("state.json")
        let store = AppStore(storageURL: state)
        store.areas = [.init(id: "a", name: "A", purpose: ""), .init(id: "b", name: "B", purpose: "")]
        store.draftOwners["new:a"] = "a"; store.conversationDrafts["new:a"] = "未发送草稿 🌱\n第二行"
        store.conversationModels["new:a"] = .init(model: "fixture", effort: "high")
        try await Task.sleep(for: .milliseconds(600))
        precondition(store.composerWarning == nil && !store.composerSaving)
        store.persist()
        let reopened = AppStore(storageURL: state)
        precondition(reopened.knowledge.isEmpty && reopened.conversationDrafts == store.conversationDrafts)
        precondition(reopened.draftOwners["new:a"] == "a" && reopened.conversationModels == store.conversationModels)
        reopened.conversationDrafts["new:a"] = ""
        precondition(reopened.saveComposerState())
        precondition(AppStore(storageURL: state).conversationDrafts["new:a"] == "", "Cleared drafts cannot revive from legacy knowledge")
        store.conversationDrafts["new:a"] = "并发写入"
        precondition(!store.saveComposerState() && store.composerWarning != nil, "Never overwrite another writer")
        try put("protocols/agent-contract.md", "fixture"); try put("protocols/write-policy.md", "fixture"); try put("corpus/readme.md", "fixture")
        try put(".local/knowledge-sources.json", "{\"notes_root\":\"\(root.path)/notes\"}")
        try put("notes/.comind/registry.json", "{\"version\":1,\"documents\":[{\"id\":\"original\",\"path\":\"主题.md\",\"aliases\":[\"corpus/old.md\"]}]}")
        try put("notes/主题.md", "独特内容 OLD")
        try put("notes/秘密.md", "独特内容 PRIVATE")
        let original = CoMindSource(path: "note:original", areas: ["a"])
        let alias = CoMindSource(path: "corpus/old.md", areas: ["a"])
        let other = CoMindSource(path: "notes/秘密.md", areas: ["b"])
        reopened.coMind = .init(repository: root, sources: [original, alias, other])
        let url = root.appendingPathComponent("notes/主题.md")
        reopened.documents = [.init(name: "重复挂载", areaID: "a", source: "本地文件", path: url.path, body: "", localURL: url)]
        let index = WorkspaceSearchIndex()
        let found = try await index.search(reopened.searchSnapshot(scope: "a"), query: "独特内容")
        precondition(found.results.count == 1 && found.results[0].target == .original(original.id))
        try put("notes/主题.md", "独特内容 NEW")
        let latest = try await index.search(reopened.searchSnapshot(scope: "a"), query: "NEW")
        precondition(latest.results.count == 1 && !latest.results[0].excerpt.contains("OLD"))
        let library = OriginalLibrary.entries(reopened.coMind, allowed: ["a"])
        precondition(library.count == 1 && library[0].id == original.id)
        reopened.coMind?.sources.removeAll { $0.id == original.id || $0.id == alias.id }; reopened.documents = []
        let revoked = try await index.search(reopened.searchSnapshot(scope: "a"), query: "独特内容")
        precondition(revoked.results.isEmpty)
        reopened.openSearchResult(found.results[0]); precondition(reopened.editingCoMindSource == nil)
        print("PASS: independent draft autosave/reopen/clear/conflict protection; original-note search, alias deduplication, latest bytes, grants, original library")
    }
}
