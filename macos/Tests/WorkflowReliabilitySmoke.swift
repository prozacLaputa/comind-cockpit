import Foundation

@main struct WorkflowReliabilitySmoke {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cockpit-workflow-\(UUID())").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        func put(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func check(_ value: Bool, _ why: String, line: UInt = #line) { precondition(value, "line \(line): " + why) }
        func reject(_ work: () throws -> Void) { do { try work(); fatalError("Expected rejection") } catch {} }
        let state = root.appendingPathComponent("state.json")
        let store = AppStore(storageURL: state)
        store.areas = [.init(id: "a", name: "原名", purpose: "")]; store.persist()
        store.composerWritable = false; store.composerWarning = "合成草稿不可读"
        store.updateArea("a", name: "改名已落盘", purpose: "", symbol: "book")
        check(AppStore(storageURL: state).areas.first?.name == "改名已落盘", "草稿失败不能吞掉独立索引保存")
        check(store.composerWarning != nil, "草稿错误仍然可见")
        store.composerWritable = true; check(store.saveComposerState(), "初始化草稿")
        let external = AppStore(storageURL: state)
        external.areas[0].name = "另一设备更新"; check(external.persist(), "外部更新")
        store.areas[0].name = "尚未保存的改名"
        check(!store.persist() && store.storageWarning != nil, "索引冲突明确失败")
        store.conversationDrafts["new:a"] = "UNSENT_LOCAL"
        check(store.saveComposerState(), "独立草稿仍能落盘")
        try store.reloadSavedWork()
        check(store.areas[0].name == "另一设备更新" && store.conversationDrafts["new:a"] == "UNSENT_LOCAL", "重新载入不丢输入")
        let copy = store.recoveryCopies().first!
        let oldIndex = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: copy.url.appendingPathComponent("state.json")))
        check(oldIndex.areas?.first?.name == "尚未保存的改名", "未保存状态进入明确恢复副本")
        store.conversationDrafts["new:a"] = "当前新草稿"
        let conflicts = try store.recoverDrafts(from: copy)
        check(conflicts == ["new:a"] && store.conversationDrafts["new:a"] == "当前新草稿", "恢复不覆盖当前输入")
        store.conversationDrafts["new:a"] = ""
        _ = try store.recoverDrafts(from: copy)
        check(store.conversationDrafts["new:a"] == "UNSENT_LOCAL", "空输入可找回")
        try put("composer-state.json", "broken-json")
        let damaged = AppStore(storageURL: state)
        check(!damaged.composerWritable, "损坏草稿进入只读")
        damaged.conversationDrafts["new:a"] = "NEW_AFTER_FAILURE"
        try damaged.repairUnreadableComposer()
        check(damaged.flushAllWork(), "修复后可正常退出")
        check(AppStore(storageURL: state).conversationDrafts["new:a"] == "NEW_AFTER_FAILURE", "修复并重开保留输入")
        let badCopy = damaged.recoveryCopies().first!
        check(try String(contentsOf: badCopy.url.appendingPathComponent("unreadable-composer.json"), encoding: .utf8) == "broken-json", "损坏原件保留")
        try put("state.json", "broken-index")
        try damaged.restoreAppIndex(from: badCopy)
        check(damaged.flushAllWork() && damaged.areas.count == 1, "索引损坏可从工作副本恢复")
        print("PASS: independent saves, index/composer conflicts, preserving/reloading/restoring drafts and corrupt-index recovery")

        // Every original lives under this disposable fixture. No real notes/model are accessed.
        try put("protocols/agent-contract.md", "fixture"); try put("protocols/write-policy.md", "fixture"); try put("corpus/README.md", "fixture")
        let repo = (0..<3).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let tool = "tools/scripts/knowledge-bridge/bridge.py"
        try put(tool, try String(contentsOf: repo.appendingPathComponent(tool), encoding: .utf8))
        let notes = root.appendingPathComponent("notes")
        try put(".local/knowledge-sources.json", "{\"notes_root\":\"\(notes.path)\"}")
        try put("notes/.comind/registry.json", "{\"version\":1,\"documents\":[{\"id\":\"a\",\"path\":\"主题/原件.md\",\"aliases\":[\"notes/旧名.md\"]},{\"id\":\"b\",\"path\":\"主题/另一个.md\"}]}")
        try put("notes/主题/原件.md", "# 合成原件\nSYNTHETIC_ORIGINAL")
        try put("notes/主题/另一个.md", "# 不同原件")
        let working = AppStore(storageURL: root.appendingPathComponent("work/state.json"))
        working.areas = [.init(id: "a", name: "验收阵地", purpose: "")]
        let source = CoMindSource(path: "note:a", areas: ["a"])
        working.coMind = .init(repository: root, sources: [source], chatSources: ["a": [source.id]])
        working.persist()
        let version = try CoMindFiles.read(source.path, in: root)
        let key = working.editingKey(source)
        try working.loadEditingDraft(key: key, source: source, version: version, area: "a")
        working.retainEditingDraft(key: key, value: .init(text: "UNSAVED_ORIGINAL_EDIT", baseHash: version.sha256), source: source, version: version, area: "a")
        check(working.flushEditingDraft(key), "原文件编辑草稿可保存")
        check(try Data(contentsOf: version.file) == version.data, "保存草稿不改原文")
        for path in [working.storageURL, working.composerURL] {
            check(try !String(contentsOf: path, encoding: .utf8).contains("UNSAVED_ORIGINAL_EDIT"), "原文编辑不复制到通用索引/草稿")
        }
        let resumed = AppStore(storageURL: working.storageURL)
        try resumed.loadEditingDraft(key: key, source: source, version: version, area: "a")
        check(resumed.editorBuffers[key]?.text == "UNSAVED_ORIGINAL_EDIT", "重开找回同目录草稿")
        resumed.retainEditingDraft(key: key, value: .init(text: "", baseHash: version.sha256), source: source, version: version, area: "a")
        check(resumed.flushEditingDraft(key), "清空正文也是可恢复修改")
        let emptyEdit = AppStore(storageURL: working.storageURL)
        try emptyEdit.loadEditingDraft(key: key, source: source, version: version, area: "a")
        check(emptyEdit.editorBuffers[key]?.text == "", "空编辑没有误当成删除草稿")
        check(emptyEdit.clearEditingDraft(key), "明确放弃草稿")
        let discarded = AppStore(storageURL: working.storageURL)
        try discarded.loadEditingDraft(key: key, source: source, version: version, area: "a")
        check(discarded.editorBuffers[key] == nil, "明确放弃后不复活")
        try put("notes/主题/原件.md", "# 外部新版\nMANUAL_LATEST")
        reject { _ = try CoMindFiles.commit(.init(before: version, after: "stale")) }
        let latest = try CoMindFiles.read(source.path, in: root)
        check(latest.text.contains("MANUAL_LATEST"), "外部修改不能被旧编辑覆盖")
        print("PASS: original editor survives relaunch, empty edits and discard; original-scoped drafts; stale edits blocked")

        let app = AppStore(storageURL: working.storageURL)
        app.saveResult("ASSISTANT_EXCERPT", area: "a", isExcerpt: true, origin: .init(threadID: "fixture-thread", messageID: "fixture-message", excerpt: true))
        check(app.documents.isEmpty && app.noteSeed?.contains("不自动视为已确认事实") == true, "摘录先明确来源，不新增知识库")
        check(app.saveComposerState(), "尚未选原件的摘录仍可保存为工作草稿")
        check(AppStore(storageURL: app.storageURL).noteSeed == app.noteSeed, "关闭前未选原件仍可找回")
        let draft = EditingDraft(title: "合成摘录", text: app.noteSeed!, baseHash: latest.sha256)
        let appendKey = "append:a:" + source.id.uuidString
        try await app.commitOriginalCapture(key: appendKey, source: source, version: latest, draft: draft, area: "a")
        let after = try CoMindFiles.read(source.path, in: root)
        check(after.text.contains("MANUAL_LATEST") && after.text.contains("codex://threads/fixture-thread") && after.text.contains("ASSISTANT_EXCERPT"), "只追加且保留来源原文")
        check(try CoMindFiles.history(for: after).count == 1, "追加有原文历史")
        check(app.documents.isEmpty && app.noteSeed == nil, "落点仍是已有原件")
        var repeated = draft; repeated.baseHash = after.sha256
        try await app.commitOriginalCapture(key: appendKey, source: source, version: after, draft: repeated, area: "a")
        check(try CoMindFiles.read(source.path, in: root).text == after.text, "相同摘录重试不重复追加")
        check(try CoMindFiles.context(connection: app.coMind, area: "a", selected: [source.id]).joined().contains("ASSISTANT_EXCERPT"), "后续聊天从同一原件读取最新内容")
        reject { _ = try OriginalNoteCapture.appended(draft, to: after, key: appendKey) }
        print("PASS: excerpts/manual capture use existing originals, provenance/history/deduplication, latest chat reads")

        try app.loadEditingDraft(key: key, source: source, version: after, area: "a")
        app.retainEditingDraft(key: key, value: .init(text: "DRAFT_BEFORE_MOVE", baseHash: after.sha256), source: source, version: after, area: "a")
        check(app.flushEditingDraft(key), "移动前保留编辑草稿")
        let target = notes.appendingPathComponent("主题/移动后.md")
        try fm.moveItem(at: after.file, to: target)
        let plan = try OriginalRelocation.prepare(source: source, repository: root, target: target)
        reject { _ = try OriginalRelocation.prepare(source: source, repository: root, target: notes.appendingPathComponent("主题/另一个.md")) }
        try Data((after.text + "\n外部新增").utf8).write(to: target)
        reject { try OriginalRelocation.apply(plan) }
        let freshPlan = try OriginalRelocation.prepare(source: source, repository: root, target: target)
        let grants = app.coMind
        try OriginalRelocation.apply(freshPlan)
        check(try CoMindFiles.read(source.path, in: root).file == target, "稳定引用修复位置")
        check(app.coMind == grants && app.coMind?.selectedSources(for: "a") == [source.id], "授权身份不变")
        check(try fm.contentsOfDirectory(atPath: notes.appendingPathComponent(".comind/history").path).contains { $0.hasPrefix("registry-") }, "登记历史可回退")
        check(try CoMindFiles.read("notes/旧名.md", in: root).file == target, "旧别名继续可读")
        let afterMove = AppStore(storageURL: app.storageURL)
        let movedVersion = try CoMindFiles.read(source.path, in: root)
        try afterMove.loadEditingDraft(key: key, source: source, version: movedVersion, area: "a")
        check(afterMove.editorBuffers[key]?.text == "DRAFT_BEFORE_MOVE", "移动并重启后草稿仍可恢复")
        afterMove.retainEditingDraft(key: key, value: .init(text: "EDIT_AFTER_MOVE", baseHash: movedVersion.sha256), source: source, version: movedVersion, area: "a")
        check(afterMove.flushEditingDraft(key), "移动后仍在同一历史草稿安全续写")
        print("PASS: explicit relocation preserves identities/grants/aliases; rejects wrong identity and changed versions; registry history retained")

        let imageStore = AppStore(storageURL: root.appendingPathComponent("images/state.json"))
        imageStore.persist()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        func image(_ name: String) throws -> ChatAttachment {
            try imageStore.addImages([(png, name)], key: name, area: "a")
            return imageStore.conversationAttachments[name]![0]
        }
        let unused = try image("unused"), sent = try image("sent"), draftImage = try image("draft"), backed = try image("backed")
        try imageStore.protectSubmittedImages([sent])
        imageStore.removeImage(unused.id, key: "unused"); imageStore.removeImage(sent.id, key: "sent")
        let recovery = try imageStore.preserveWorkCopy()
        imageStore.removeImage(backed.id, key: "backed")
        let untracked = try ChatAttachments.importImage(png, name: "legacy", root: imageStore.attachmentRoot)
        check(try imageStore.cleanUnusedImages() == 0, "7 天恢复期内保留")
        try imageStore.restoreRemovedImage(imageStore.attachmentLifecycle[unused.id.uuidString]!, to: "actual-thread-id")
        check(imageStore.conversationAttachments["actual-thread-id"]?.first?.id == unused.id, "图片返回正确会话键")
        imageStore.removeImage(unused.id, key: "actual-thread-id")
        // The earlier recovery protects its original attachments, but not the already-removed unused image.
        let future = Date().addingTimeInterval(8 * 86400)
        check(try imageStore.cleanUnusedImages(now: future) == png.count, "只清理确知未发送、无引用、到期副本")
        check(!fm.fileExists(atPath: unused.url(in: imageStore.attachmentRoot).path), "到期无引用副本已删")
        for item in [sent, draftImage, backed, untracked] { check(fm.fileExists(atPath: item.url(in: imageStore.attachmentRoot).path), "历史/当前/恢复副本/未知图片不动") }
        check(fm.fileExists(atPath: recovery.path), "恢复副本保留")
        let imagesReopened = AppStore(storageURL: imageStore.storageURL)
        check(imagesReopened.attachmentLifecycle[sent.id.uuidString]?.submitted == true && imagesReopened.conversationAttachments["draft"]?.first?.id == draftImage.id, "重开不丢历史与草稿引用")
        print("PASS: attachment grace period, restore, sent/live/recovery/unknown protections and relaunch")
    }
}
