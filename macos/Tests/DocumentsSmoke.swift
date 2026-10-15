import Foundation

@main struct DocumentsSmoke {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("documents-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let store = AppStore(storageURL: url)
        store.areas = [Area(id: "a", name: "主阵地", purpose: "测试"), Area(id: "b", name: "关联阵地", purpose: "测试")]
        store.threadLinks = [.init(areaID: "a", threadID: "unchanged-thread")]
        // Compatibility fixture: new captures no longer create owned documents.
        let saved = DocumentRecord(name: "旧摘录.md", areaID: "a", source: "本机笔记", path: "旧摘录.md", body: "Legacy reply")
        store.documents = [saved]; store.persist()
        store.link(saved.id, area: "b")
        let external = root.appendingPathComponent("source.md")
        let original = Data("This file must never be deleted or changed.".utf8)
        try original.write(to: external)
        let reference = DocumentRecord(name: "source.md", areaID: "a", source: "本地文件", path: external.path, body: "", linkedAreas: ["b"], localURL: external)
        let retained = DocumentRecord(name: "keep.md", areaID: "a", source: "本机笔记", path: "keep.md", body: "Keep this")
        store.documents += [reference, retained]; store.persist()
        precondition(store.storageWarning == nil)

        let excerpt = "只保存这句话 👩🏽‍💻。\n保留原换行。"
        store.saveResult(excerpt, area: "a", isExcerpt: true)
        precondition(store.documents.count == 3 && store.noteSeed?.contains(excerpt) == true && store.sheet == .note)
        precondition(store.saveComposerState())
        precondition(AppStore(storageURL: url).noteSeed == store.noteSeed)
        let pending = store.noteSeed
        store.saveResult(" \n ", area: "a", isExcerpt: true)
        precondition(store.noteSeed == pending && store.documents.count == 3)
        store.noteSeed = nil; store.sheet = nil; store.persist()
        print("PASS: new excerpts are recoverable work drafts awaiting an original, never owned knowledge records")

        let before = try Data(contentsOf: url)
        store.filePreview = saved
        store.requestDocumentDeletion(saved.id)
        precondition(store.sheet == .deleteDocument && store.filePreview == nil)
        precondition(tryEqual(url, before) && store.documents.count == 3)
        store.sheet = nil // Cancelling/dismissing confirmation cannot mutate documents.
        precondition(tryEqual(url, before))
        store.requestDocumentDeletion(saved.id)
        precondition(store.deleteDocument(saved.id))
        let deleted = AppStore(storageURL: url)
        precondition(!deleted.documents(for: "a").contains { $0.id == saved.id })
        precondition(!deleted.documents(for: "b").contains { $0.id == saved.id })
        precondition(deleted.documents.contains { $0.id == retained.id && $0.body == "Keep this" })
        precondition(deleted.threadLinks.count == 1 && deleted.threadLinks[0].threadID == "unchanged-thread")
        precondition(store.sheet == nil && store.deletingDocumentID == nil)
        precondition(!store.deleteDocument(saved.id))
        print("PASS: confirmation/cancel do not write; confirmed deletion survives reload, clears all references, preserves other material and chat links")

        precondition(store.deleteDocument(reference.id))
        precondition(tryEqual(external, original))
        precondition(!AppStore(storageURL: url).documents.contains { $0.id == reference.id })
        print("PASS: removing an external document never modifies its source file")

        let competing = AppStore(storageURL: url)
        competing.areas[0].name = "external-change"; competing.persist()
        let remote = try Data(contentsOf: url)
        store.requestDocumentDeletion(retained.id)
        precondition(!store.deleteDocument(retained.id))
        precondition(store.documents.contains { $0.id == retained.id && $0.body == "Keep this" })
        precondition(store.sheet == .deleteDocument && store.storageWarning != nil)
        precondition(tryEqual(url, remote))
        let count = store.documents.count
        store.saveResult("Must not appear saved", area: "a")
        precondition(store.documents.count == count && tryEqual(url, remote))
        print("PASS: external changes reject deletion and saving; in-memory records roll back and the newer file remains intact")

        let brokenURL = root.appendingPathComponent("broken.json")
        let broken = Data("invalid".utf8); try broken.write(to: brokenURL)
        let readOnly = AppStore(storageURL: brokenURL)
        readOnly.documents = [retained]
        precondition(!readOnly.deleteDocument(retained.id))
        precondition(readOnly.documents.count == 1 && tryEqual(brokenURL, broken))
        print("PASS: unavailable storage cannot delete records")
    }
    static func tryEqual(_ url: URL, _ expected: Data) -> Bool { (try? Data(contentsOf: url)) == expected }
}
