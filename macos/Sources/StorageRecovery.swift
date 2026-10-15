import Foundation
import AppKit

struct WorkRecoveryCopy: Identifiable {
    let url: URL
    let date: Date
    var id: String { url.path }
}
extension AppStore {
    var workRecoveryRoot: URL { storageURL.deletingLastPathComponent().appendingPathComponent("工作恢复副本") }
    var hasSaveProblems: Bool { storageWarning != nil || composerWarning != nil || !editorWarnings.isEmpty }
    @discardableResult func flushAllWork() -> Bool {
        let indexOK = persist()
        let editsOK = editorBuffers.keys.map { flushEditingDraft($0) }.allSatisfy { $0 }
        let draftsOK = saveComposerState()
        return indexOK && editsOK && draftsOK && editorWarnings.isEmpty
    }
    func recoveryCopies() -> [WorkRecoveryCopy] {
        let files = (try? FileManager.default.contentsOfDirectory(at: workRecoveryRoot, includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey])) ?? []
        return files.filter { let v = try? $0.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]); return v?.isSymbolicLink == false && v?.isDirectory == true }
            .map { .init(url: $0, date: (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.date > $1.date }
    }
    /// Backup is an explicitly labelled recovery artifact, never an active source or chat context.
    @discardableResult func preserveWorkCopy() throws -> URL {
        let root = workRecoveryRoot.appendingPathComponent(UUID().uuidString)
        guard workRecoveryRoot.resolvingSymlinksInPath() == workRecoveryRoot.standardizedFileURL else { throw CoMindFiles.failure("恢复目录包含符号链接") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["state.json": try JSONEncoder().encode(snapshot()), "composer-state.json": try JSONEncoder().encode(currentComposerState())]
        for (name, data) in files {
            let file = root.appendingPathComponent(name)
            try data.write(to: file, options: .withoutOverwriting)
            guard try Data(contentsOf: file) == data else { throw CoMindFiles.failure("工作副本回读不一致，未确认保留") }
        }
        // Original-file editor bodies remain in their own history directory.
        guard editorBuffers.keys.filter({ editorFiles[$0] != nil }).map({ flushEditingDraft($0) }).allSatisfy({ $0 || editorWarnings.isEmpty }) else {
            throw CoMindFiles.failure("部分原文件编辑草稿仍未保存，请先在编辑框复制保留，当前窗口不会关闭。")
        }
        return root
    }
    func reloadSavedWork() throws {
        guard codex.runningThreadID == nil, !pendingDispatching, !organizationPreparing, reviewTasks.isEmpty, employeeSetupTasks.isEmpty else { throw CoMindFiles.failure("请等当前任务结束后恢复数据。") }
        let data = try Data(contentsOf: storageURL)
        try CockpitStorage.validate(data)
        let s = try JSONDecoder().decode(Snapshot.self, from: data)
        // Validate all legacy domains before changing visible state.
        for reference in (s.knowledge ?? [:]).values { _ = try KnowledgeVault.load(reference) }
        let composerExists = FileManager.default.fileExists(atPath: composerURL.path)
        if composerExists {
            let current = try JSONDecoder().decode(ComposerState.self, from: Data(contentsOf: composerURL))
            guard current.version == 1 else { throw CoMindFiles.failure("草稿格式暂不支持，未重新加载") }
        } else if FileManager.default.fileExists(atPath: composerURL.deletingLastPathComponent().appendingPathComponent(".composer-state.json.icloud").path) {
            throw CoMindFiles.failure("请等 iCloud 草稿下载后再重试，当前输入保留")
        }
        _ = try preserveWorkCopy()
        positionTask?.cancel(); composerSaveTask?.cancel()
        initialized = false; composerLoaded = false
        defer { initialized = true; composerLoaded = true }
        areas = s.areas ?? []; threadLinks = s.threadLinks ?? []; documents = s.documents
        projects = s.projects; captures = s.captures; completed = s.completed
        progressReports = s.progressReports ?? [:]; employeeProfiles = s.employeeProfiles ?? [:]
        employeeMemories = s.employeeMemories ?? []; employeeProfileDrafts = s.employeeProfileDrafts ?? [:]
        employeeProfileHistory = s.employeeProfileHistory ?? [:]; archivedAreas = s.archivedAreas ?? []
        discardedDocuments = s.discardedDocuments ?? []; actions = s.actions ?? []; knowledge = s.knowledge ?? [:]
        coMind = s.coMind; areaSeen = s.areaSeen ?? [:]; deferredNoteReviews = s.deferredNoteReviews ?? []
        noteOrganizations = (s.noteOrganizations ?? []).map { var value = $0; if value.state == "running" { value.state = "interrupted" }; return value }
        noteWritebackPolicies = s.noteWritebackPolicies ?? [:]; progressSchedules = s.progressSchedules ?? [:]
        try loadKnowledge()
        if let p = s.position {
            page = Page(rawValue: p.page) ?? .overview; areaID = areas.contains { $0.id == p.areaID } ? p.areaID : nil
            areaTab = WorkspacePosition.resolvedAreaTab(p.areaTab); lastAreaThread = p.lastAreaThread; readingLocations = p.reading
        }
        conversationDrafts = [:]; conversationModels = [:]; conversationSkills = [:]; conversationAttachments = [:]
        pendingMessages = []; draftOwners = [:]; composerData = nil; composerWritable = true; composerWarning = nil
        loadedData = data; persistenceAvailable = true; storageWarning = nil
        loadComposerState()
        notify("已读取最新数据，之前的工作副本可在恢复页找回")
    }
    func recoverDrafts(from copy: WorkRecoveryCopy) throws -> [String] {
        guard recoveryCopies().contains(where: { $0.id == copy.id }) else { throw CoMindFiles.failure("恢复副本不可用") }
        let saved = try JSONDecoder().decode(ComposerState.self, from: Data(contentsOf: copy.url.appendingPathComponent("composer-state.json")))
        var conflicts: [String] = []
        let old = currentComposerState()
        for (key, text) in saved.drafts where !text.isEmpty || !(saved.attachments?[key] ?? []).isEmpty {
            if !(conversationDrafts[key] ?? "").isEmpty || !(conversationAttachments[key] ?? []).isEmpty {
                if conversationDrafts[key] != text || (conversationAttachments[key] ?? []) != (saved.attachments?[key] ?? []) { conflicts.append(key) }; continue
            }
            conversationDrafts[key] = text; draftOwners[key] = saved.owners[key]
            conversationModels[key] = saved.models[key]; conversationSkills[key] = saved.skills[key]
            conversationAttachments[key] = saved.attachments?[key]
        }
        for item in saved.pending ?? [] where !pendingMessages.contains(where: { $0.id == item.id }) {
            var value = item
            value.state = ["sending", "uncertain"].contains(item.state) ? "uncertain" : "paused"
            value.detail = "从工作副本找回，请核对后手动发送"; pendingMessages.append(value)
        }
        for (key, draft) in saved.ownedEdits ?? [:] where key.hasPrefix("legacy:") {
            if editorBuffers[key] == nil { editorBuffers[key] = draft }
            else if editorBuffers[key] != draft { conflicts.append(key) }
        }
        for (key, reference) in saved.editReferences ?? [:] where editorReferences[key] == nil { editorReferences[key] = reference }
        if noteSeed == nil, let pending = saved.pendingCapture { noteSeed = pending.text; noteDraftArea = pending.area; noteDraftSource = pending.source }
        else if let pending = saved.pendingCapture, noteSeed != pending.text { conflicts.append("待保存摘录") }
        for (key, value) in saved.attachmentLedger ?? [:] where attachmentLifecycle[key] == nil { attachmentLifecycle[key] = value }
        guard saveComposerState() else {
            editorBuffers = editorBuffers.filter { !$0.key.hasPrefix("legacy:") }.merging(old.ownedEdits ?? [:]) { _, restored in restored }
            editorReferences = old.editReferences ?? [:]; attachmentLifecycle = old.attachmentLedger ?? [:]
            noteSeed = old.pendingCapture?.text; noteDraftArea = old.pendingCapture?.area ?? ""; noteDraftSource = old.pendingCapture?.source
            conversationDrafts = old.drafts; draftOwners = old.owners; conversationModels = old.models; conversationSkills = old.skills
            conversationAttachments = old.attachments ?? [:]; pendingMessages = old.pending ?? []
            throw CoMindFiles.failure(composerWarning ?? "恢复未保存")
        }
        return conflicts
    }
    func restoreAppIndex(from copy: WorkRecoveryCopy) throws {
        guard recoveryCopies().contains(where: { $0.id == copy.id }), codex.runningThreadID == nil, !pendingDispatching,
              !organizationPreparing, reviewTasks.isEmpty, employeeSetupTasks.isEmpty else { throw CoMindFiles.failure("请等待当前任务结束并选择可用副本") }
        let data = try Data(contentsOf: copy.url.appendingPathComponent("state.json"))
        try CockpitStorage.validate(data)
        let restored = try JSONDecoder().decode(Snapshot.self, from: data)
        for reference in (restored.knowledge ?? [:]).values { _ = try KnowledgeVault.load(reference) }
        if FileManager.default.fileExists(atPath: composerURL.path) {
            guard let state = try? JSONDecoder().decode(ComposerState.self, from: Data(contentsOf: composerURL)), state.version == 1 else { throw CoMindFiles.failure("请先修复不可读的草稿文件") }
        }
        let previous = try Data(contentsOf: storageURL)
        let backup = try preserveWorkCopy()
        try previous.write(to: backup.appendingPathComponent("index-before-restore.json"), options: .withoutOverwriting)
        try CockpitStorage.save(data, to: storageURL, expected: previous)
        // Disk has now been verified. Reload does not rewrite original notes or replay messages.
        try reloadSavedWork()
        notify("已恢复应用索引，原笔记保持；之前的状态也已留存")
    }
    /// Explicitly reset only unreadable working-state bytes after preserving them; never reset notes/index.
    func repairUnreadableComposer() throws {
        guard FileManager.default.fileExists(atPath: composerURL.path) else { throw CoMindFiles.failure("请先等待草稿下载，不会创建替代文件") }
        let existing = try Data(contentsOf: composerURL)
        if let decoded = try? JSONDecoder().decode(ComposerState.self, from: existing), decoded.version == 1 {
            throw CoMindFiles.failure("草稿可读，请使用保留工作副本并读取最新数据")
        }
        let root = try preserveWorkCopy()
        try existing.write(to: root.appendingPathComponent("unreadable-composer.json"), options: .withoutOverwriting)
        let data = try JSONEncoder().encode(currentComposerState())
        try CockpitStorage.save(data, to: composerURL, expected: existing)
        composerData = data; composerWritable = true; composerWarning = nil
        notify("不可读原文件已保留，当前工作草稿已恢复保存")
    }
}
