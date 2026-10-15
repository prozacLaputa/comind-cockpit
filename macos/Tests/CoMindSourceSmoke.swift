import Foundation

@main struct CoMindSourceSmoke {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cockpit-source-smoke-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func put(_ path: String, _ text: String) throws {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func check(_ condition: Bool, _ message: String = "", line: UInt = #line) { precondition(condition, "line \(line): " + message) }
        func reject(_ action: () throws -> Void) { do { try action(); fatalError("Expected rejection") } catch {} }
        try put("protocols/agent-contract.md", "fixture"); try put("protocols/write-policy.md", "fixture")
        let repo = (0..<3).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let bridgeTool = "tools/scripts/knowledge-bridge/bridge.py"
        try put(bridgeTool, try String(contentsOf: repo.appendingPathComponent(bridgeTool), encoding: .utf8))
        try put(CoMindFiles.memory, "# Memory\n\n## Stable Facts\n- SYNTHETIC_ORIGINAL\n")
        try put(CoMindFiles.candidates, "# Memory Candidates\n\n## New\n\n## Reviewed\n- candidate: old\n  action: deferred\n\n## Rejected\n")
        try put("corpus/projects/sample.md", "# Synthetic topic\nInitial")
        try put("corpus/health/private/sample.md", "# Synthetic private fixture")
        let store = AppStore(storageURL: root.appendingPathComponent("state.json"))
        store.areas = [.init(id: "a", name: "Fixture A", purpose: ""), .init(id: "b", name: "Fixture B", purpose: "")]
        store.employeeMemories = [.init(areaID: "a", topic: "Fixture", text: "SYNTHETIC_OLD_MEMORY", category: .fact, state: .pending, sources: [], proposalKey: "k")]
        try store.connectCoMind(root)
        precondition(store.knowledge.isEmpty)
        try store.attachCoMindSource(path: CoMindFiles.memory, area: "a")
        try store.attachCoMindSource(path: CoMindFiles.memory, area: "b")
        precondition(store.coMind?.sources.count == 1, "Same file must remain one source with separate grants")
        let source = store.coMind!.sources[0]
        let persisted = try String(contentsOf: store.storageURL, encoding: .utf8)
        precondition(!persisted.contains("SYNTHETIC_ORIGINAL"), "No mirrored source body in index")
        precondition(persisted.contains("SYNTHETIC_OLD_MEMORY"), "No migration or deletion as side effect of linking")
        let reopened = AppStore(storageURL: store.storageURL)
        precondition(reopened.coMind == store.coMind)
        check(try CoMindFiles.context(connection: store.coMind, area: "a", selected: []).isEmpty)
        var context = try CoMindFiles.context(connection: store.coMind, area: "a", selected: [source.id])
        precondition(context[0].contains("SYNTHETIC_ORIGINAL"))
        reject { _ = try CoMindFiles.context(connection: store.coMind, area: "c", selected: [source.id]) }
        try put(CoMindFiles.memory, "# Memory\nExternal change")
        context = try CoMindFiles.context(connection: store.coMind, area: "b", selected: [source.id])
        precondition(context[0].contains("External change"), "Always read the authoritative original")
        let version = try CoMindFiles.read(CoMindFiles.memory, in: root)
        let backup = try CoMindFiles.commit(.init(before: version, after: "# Memory\nExplicitly confirmed edit"))!
        check(try Data(contentsOf: backup) == version.data)
        check(try CoMindFiles.history(for: version).contains { $0.standardizedFileURL.path == backup.standardizedFileURL.path })
        check(try CoMindFiles.historyText(backup, for: version) == version.text)
        check(try CoMindFiles.read(CoMindFiles.memory, in: root).text.contains("Explicitly confirmed edit"))
        reject { try CoMindFiles.commit(.init(before: version, after: "Stale edit")) }
        check(try CoMindFiles.read(CoMindFiles.memory, in: root).text.contains("Explicitly confirmed edit"))
        let current = try CoMindFiles.read(CoMindFiles.memory, in: root)
        try CoMindFiles.commit(.init(before: current, after: String(data: Data(contentsOf: backup), encoding: .utf8)!))
        check(try CoMindFiles.read(CoMindFiles.memory, in: root).data == version.data, "Restore uses original and keeps history")
        let candidate = try CoMindFiles.read(CoMindFiles.candidates, in: root)
        let appended = try CoMindFiles.candidateDraft(in: candidate, text: "Synthetic preference", source: "fixture-thread", scope: "collaboration-workflow")
        precondition(appended.contains("confirmation-status: pending"))
        precondition(appended.range(of: "Synthetic preference")!.lowerBound < appended.range(of: "## Reviewed")!.lowerBound)
        precondition(appended.contains("  action: deferred\n\n## Rejected"), "Preserve existing review history")
        check(try CoMindFiles.read(CoMindFiles.candidates, in: root).data == candidate.data, "Preview never writes")
        reject { _ = try CoMindFiles.candidateDraft(in: candidate, text: "injection\n## Reviewed", source: "x", scope: "y") }
        reject { _ = try CoMindFiles.candidateDraft(in: current, text: "x", source: "x", scope: "x") }
        let privateVersion = try CoMindFiles.read("corpus/health/private/sample.md", in: root)
        let privateBackup = try CoMindFiles.commit(.init(before: privateVersion, after: "Updated synthetic private fixture"))!
        reject { _ = try CoMindFiles.historyText(privateBackup, for: version) }
        precondition(privateBackup.path.hasPrefix(root.appendingPathComponent("corpus/health/private/").path))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("corpus/projects/alias.md").path, withDestinationPath: root.appendingPathComponent("corpus/health/private/sample.md").path)
        reject { _ = try CoMindFiles.read("corpus/projects/alias.md", in: root) }
        for path in ["../memory.md", "corpus/../memory.md", "/etc/hosts.md", "context/memory/other.md", "protocols/agent-contract.md", "corpus/health/sample.md", "corpus/people/sample.md", "corpus/.history/a.md"] {
            reject { _ = try CoMindFiles.url(path, in: root) }
        }
        try put("corpus/projects/large.md", String(repeating: "x", count: 1_000_001))
        reject { _ = try CoMindFiles.read("corpus/projects/large.md", in: root) }
        let notes = root.appendingPathComponent("notes-fixture")
        try put("notes-fixture/topic/test.md", "external notes original")
        try put(".local/knowledge-sources.json", "{\"notes_root\":\"\(notes.path)\",\"routes\":{\"corpus/people/private/\":\"people/\"}}")
        try put("notes-fixture/.comind/registry.json", "{\"version\":1,\"documents\":[{\"id\":\"fixture-note\",\"path\":\"topic/test.md\",\"aliases\":[\"corpus/old-note.md\"]}]}")
        check(try CoMindFiles.read("corpus/old-note.md", in: root).text == "external notes original")
        check(try CoMindFiles.relativePath(notes.appendingPathComponent("topic/test.md"), in: root) == "note:fixture-note")
        try store.attachCoMindSource(path: "corpus/old-note.md", area: "a")
        try store.attachCoMindSource(path: "note:fixture-note", area: "a")
        check(store.coMindSources(for: "a").count == 2, "Old and new addresses must not duplicate grants")
        let noteVersion = try CoMindFiles.read("note:fixture-note", in: root)
        let noteBackup = try CoMindFiles.commit(.init(before: noteVersion, after: "updated in original notes"))!
        check(noteBackup.path.hasPrefix(notes.path + "/"))
        check(try CoMindFiles.read("notes/topic/test.md", in: root).text == "updated in original notes")
        let registry = try JSONSerialization.jsonObject(with: Data(contentsOf: notes.appendingPathComponent(".comind/registry.json"))) as! [String: Any]
        let registered = (registry["documents"] as! [[String: Any]])[0]
        let updatedNote = try CoMindFiles.read("note:fixture-note", in: root)
        check(registered["sha256"] as? String == updatedNote.sha256, "Native edit updates the same registry used by CLI")
        let count = try CoMindFiles.history(for: updatedNote).count
        check(try CoMindFiles.commit(.init(before: updatedNote, after: updatedNote.text)) == nil)
        check(try CoMindFiles.history(for: updatedNote).count == count, "No-op edits do not accumulate history")
        let bridgeURL = root.appendingPathComponent(bridgeTool)
        try fm.moveItem(at: bridgeURL, to: bridgeURL.appendingPathExtension("disabled"))
        reject { try CoMindFiles.commit(.init(before: updatedNote, after: "must not bypass bridge")) }
        check(try CoMindFiles.read("note:fixture-note", in: root).text == updatedNote.text)
        try fm.moveItem(at: bridgeURL.appendingPathExtension("disabled"), to: bridgeURL)
        reject { try CoMindFiles.commit(.init(before: noteVersion, after: "stale")) }
        reject { _ = try CoMindFiles.read("notes/../outside.md", in: root) }
        reject { _ = try CoMindFiles.read("notes/.obsidian/test.md", in: root) }
        try put("notes-fixture/people/test.md", "private fixture")
        check(try CoMindFiles.read("corpus/people/private/test.md", in: root).text == "private fixture")
        try fm.removeItem(at: notes.appendingPathComponent("topic/test.md"))
        reject { _ = try CoMindFiles.read("corpus/old-note.md", in: root) }
        let inventory = KnowledgeInventory.markdown(store.snapshot())
        precondition(inventory.contains("memory/"))
        precondition(!inventory.contains("SYNTHETIC_OLD_MEMORY"), "Inventory must not export private record bodies")
        try store.detachCoMindSource(source.id, area: "a")
        precondition(!store.coMindSources(for: "a").contains { $0.id == source.id } && store.coMindSources(for: "b").count == 1)
        precondition(fm.fileExists(atPath: root.appendingPathComponent(CoMindFiles.memory).path))
        let saved = DocumentRecord(name: "合成会话摘录.md", areaID: "b", source: "本机笔记", path: "合成会话摘录.md", body: "SYNTHETIC_SAVED_EXCERPT", origin: .init(threadID: "fixture-thread", messageID: "fixture-message", excerpt: true))
        let file = DocumentRecord(name: "合成参考文件.md", areaID: "b", source: "本地文件", path: "corpus/projects/sample.md", body: "", localURL: root.appendingPathComponent("corpus/projects/sample.md"))
        store.documents = [saved, file]
        try store.setCoMindChatSource(source.id, area: "b", enabled: true)
        let originalBytes = try Data(contentsOf: root.appendingPathComponent(CoMindFiles.memory))
        for oldTab in ["记忆", "长期资料", "资料"] {
            store.page = .areas; store.areaID = "b"; store.areaTab = oldTab; store.persist()
            let resumed = AppStore(storageURL: store.storageURL)
            check(resumed.areaTab == "资料", "old positions reopen in the single materials tab")
            check(resumed.documents(for: "b").map(\.id) == [saved.id, file.id], "saved excerpts and external references survive navigation merge")
            check(resumed.documents(for: "b")[0].origin?.messageID == "fixture-message", "source attribution survives")
            check(resumed.coMind?.selectedSources(for: "b") == [source.id], "chat selection remains unchanged")
            check(try Data(contentsOf: root.appendingPathComponent(CoMindFiles.memory)) == originalBytes, "navigation never rewrites originals")
        }
        check(WorkspacePosition.resolvedAreaTab("开始工作") == "开始工作" && WorkspacePosition.resolvedAreaTab("会话") == "开始工作", "other navigation remains compatible")
        store.page = .areas; store.areaID = "b"; store.areaTab = "开始工作"; store.sheet = .theme
        store.codex.selected = CodexThread(["id": "fixture-active", "name": "Synthetic active chat"])
        store.codex.messages = [.init(id: "fixture-message", role: "assistant", text: "SYNTHETIC_RUNNING_REPLY")]
        store.conversationDrafts["fixture-active"] = "SYNTHETIC_UNSENT_DRAFT"
        store.draftOwners["fixture-active"] = "b"
        let connectionBeforeNavigation = store.coMind
        check(store.materialsSettingsArea?.id == "b")
        store.openMaterialsFromSettings()
        check(store.sheet == nil && store.areaID == "b" && store.areaTab == "资料")
        check(store.codex.selected?.id == "fixture-active" && store.codex.messages.first?.text == "SYNTHETIC_RUNNING_REPLY", "opening materials must retain the active chat")
        check(store.conversationDrafts["fixture-active"] == "SYNTHETIC_UNSENT_DRAFT", "settings navigation must preserve unsent text")
        check(store.coMind == connectionBeforeNavigation, "navigation must not alter source grants or chat selection")
        store.page = .overview; store.sheet = .theme
        check(store.materialsSettingsArea == nil, "global settings must not imply a stale area is selected")
        store.openMaterialsFromSettings()
        check(store.page == .areas && store.areaID == nil && store.sheet == nil, "global entry lets user choose an area")
        check(store.conversationDrafts["fixture-active"] == "SYNTHETIC_UNSENT_DRAFT" && store.coMind == connectionBeforeNavigation)
        print("PASS: settings-to-materials navigation preserves active chat, unsent draft and grants; global entry chooses an area")
        print("PASS: unified materials navigation, all legacy positions, saved excerpts, original file bytes and chat selections preserved")
        print("PASS: same-source references, grants, original reload/write/restore, conflict rejection, candidate schema, private histories, path/size protection, metadata-only inventory, no implicit migration")
    }
}
