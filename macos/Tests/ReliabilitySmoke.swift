import Foundation
import Combine

@main struct ReliabilitySmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-reliability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("CoMind")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("protocols"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("corpus"), withIntermediateDirectories: true)
        try Data("test contract".utf8).write(to: repo.appendingPathComponent("protocols/agent-contract.md"))
        let state = root.appendingPathComponent("state.json")
        let store = AppStore(storageURL: state)
        store.createArea(name: "Synthetic scope", purpose: "fixture unique purpose", symbol: "folder")
        if let warning = store.storageWarning { print(warning); exit(1) }
        let area = store.areas[0]
        store.linkThread("fixture-thread", areaID: area.id)
        let origin = DocumentOrigin(threadID: "fixture-thread", messageID: "turn/message", excerpt: true)
        // Existing owned records remain editable/recoverable; new captures use originals.
        store.documents = [.init(name: "Legacy fixture.md", areaID: area.id, source: "本机笔记", path: "fixture.md", body: "fixture unique body\nwith Unicode 👋", origin: origin)]
        store.persist()
        let document = store.documents[0]
        store.editDocument(document.id, name: "A named excerpt.md", body: "fixture edited body")
        precondition(store.documents[0].revisions?.first?.body == document.body)
        store.draftOwners["fixture-thread"] = area.id; store.conversationDrafts["fixture-thread"] = "fixture draft"
        store.lastAreaThread[area.id] = "fixture-thread"
        var readingPublications = 0
        let readingObserver = store.objectWillChange.sink { readingPublications += 1 }
        let legacy = try JSONDecoder().decode(ReadingLocation.self, from: Data(#"{"messageID":"old","atLatest":false}"#.utf8))
        precondition(legacy.offset == nil && legacy.messageID == "old")
        store.rememberReading(thread: "fixture-thread", message: "turn/message", latest: false, offset: 317.5, rowHeight: 900, contentWidth: 960, toolDetails: true, deferSave: true)
        precondition(readingPublications == 0, "reading position must not invalidate the full app")
        precondition(store.readingPositionDirty)
        readingObserver.cancel()
        let other = Area(id: "other-scope", name: "Other fixture", purpose: "")
        store.areas.append(other); store.threadLinks.append(.init(areaID: other.id, threadID: "fixture-thread"))
        let emptyOther = store.knowledgeData(other)
        precondition(emptyOther.drafts.isEmpty, "a shared thread must not copy a draft into another domain")
        store.applyKnowledge(emptyOther)
        precondition(store.conversationDrafts["fixture-thread"] == "fixture draft", "loading another domain must not erase the original draft")
        store.areas.removeAll { $0.id == other.id }; store.threadLinks.removeAll { $0.areaID == other.id }
        let reference = KnowledgeReference(repository: repo, directory: "context/inbox/fixture-domain", category: .general)
        store.migrateKnowledge(area: area, reference: reference)
        precondition(store.storageWarning == nil, store.storageWarning ?? "")
        let head = store.knowledge[area.id]!
        let bytes = try Data(contentsOf: state)
        let index = String(decoding: bytes, as: UTF8.self)
        precondition(!index.contains("fixture edited body") && !index.contains("fixture unique purpose") && !index.contains("fixture draft"))
        let restored = AppStore(storageURL: state)
        precondition(restored.canEdit && restored.documents[0].body == "fixture edited body")
        precondition(restored.documents[0].origin?.messageID == origin.messageID)
        precondition(restored.conversationDrafts["fixture-thread"] == "fixture draft")
        precondition(restored.lastAreaThread[area.id] == "fixture-thread" && restored.readingLocations["fixture-thread"]?.messageID == "turn/message")
        precondition(restored.readingLocations["fixture-thread"]?.offset == 317.5 && restored.readingLocations["fixture-thread"]?.toolDetails == true)
        precondition(restored.areaID == area.id)
        let historyBefore = try KnowledgeVault.history(head).count
        restored.persist()
        precondition(tryCount(head) == historyBefore, "unchanged saves must not create versions")
        restored.editDocument(document.id, name: "New name.md", body: "fixture newest body")
        precondition(tryCount(head) == historyBefore + 1)
        restored.restoreKnowledge(area: area.id, revision: head.revision!)
        precondition(restored.documents[0].body == "fixture edited body")
        precondition(tryCount(head) == historyBefore + 2, "restore creates a new version instead of erasing history")
        restored.deleteDocument(document.id)
        precondition(restored.documents.isEmpty && restored.discardedDocuments.count == 1)
        restored.restoreDocument(document.id)
        precondition(restored.documents[0].origin?.threadID == origin.threadID)
        restored.deleteArea(area.id)
        precondition(restored.areas.isEmpty && restored.archivedAreas.count == 1 && restored.threadLinks.count == 1 && restored.documents.count == 1)
        restored.restoreArea(area.id)
        precondition(restored.areas[0].id == area.id)
        let report = AreaProgressReport(content: .init(current: [], completed: [], next: [.init(text: "fixture next step", sources: ["S1"])], uncertain: []), sources: [.init(id: "S1", title: "fixture", threadID: "fixture-thread")], generatedAt: Date(), fingerprint: "fixture", coverage: "fixture")
        restored.saveProgress(report, area: area.id)
        let action = restored.actions[0]
        restored.feedback(action, state: .done)
        restored.saveProgress(report, area: area.id)
        precondition(restored.actions.count == 1 && restored.actions[0].id == action.id && restored.actions[0].state == .done)
        let reloaded = AppStore(storageURL: state)
        precondition(reloaded.actions[0].state == .done && reloaded.actions[0].feedback.count == 1)
        // A second writer cannot replace another window's cockpit index.
        reloaded.updateArea(area.id, name: "Other writer", purpose: "new purpose", symbol: "folder")
        let winning = try Data(contentsOf: state)
        restored.persist()
        precondition(restored.storageWarning != nil && (try? Data(contentsOf: state)) == winning)
        var invalid = reference; invalid.category = .health
        do { try KnowledgeVault.validate(invalid); fatalError("health scope escaped private root") } catch {}
        invalid.directory = "corpus/health/private/fixture"
        try KnowledgeVault.validate(invalid)
        invalid.directory = "corpus/health/private/../../elsewhere"
        do { try KnowledgeVault.validate(invalid); fatalError("traversal accepted") } catch {}
        let manifest = try KnowledgeVault.revision(reloaded.knowledge[area.id]!)!
        let source = head.root.appendingPathComponent(manifest.records["area"]!)
        try Data("corrupt fixture".utf8).write(to: source)
        let corrupted = AppStore(storageURL: state)
        precondition(!corrupted.canEdit && corrupted.storageWarning != nil)
        precondition((try? Data(contentsOf: state)) == winning)
        corrupted.restoreKnowledge(area: area.id, revision: head.revision!)
        precondition(corrupted.canEdit && corrupted.storageWarning == nil, corrupted.storageWarning ?? "recovery failed")
        precondition(corrupted.documents[0].body == "fixture edited body")
        print("PASS: per-record migration/read-back, no bodies in index, draft/navigation recovery, unchanged-write reuse, source provenance, revisions/restore, archive+trash recovery, stable actions, writer conflict, scope boundaries, corrupt-source protection")
    }
    static func tryCount(_ reference: KnowledgeReference) -> Int { (try? KnowledgeVault.history(reference).count) ?? -1 }
}
