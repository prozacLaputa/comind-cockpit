import Foundation

/// Disposable working state, alongside the app index; never a personal-knowledge store.
struct ComposerState: Codable {
    var version = 1
    var drafts: [String: String]
    var owners: [String: String]
    var models: [String: CodexModelSelection]
    var skills: [String: [CodexSkill]]
    var attachments: [String: [ChatAttachment]]? = nil
    var pending: [PendingChatMessage]? = nil
    var editReferences: [String: EditingDraftReference]? = nil
    var attachmentLedger: [String: AttachmentLifecycle]? = nil
    var pendingCapture: PendingOriginalCapture? = nil
    var ownedEdits: [String: EditingDraft]? = nil
}

extension AppStore {
    func currentComposerState() -> ComposerState {
        ComposerState(drafts: conversationDrafts, owners: draftOwners, models: conversationModels, skills: conversationSkills,
            attachments: conversationAttachments, pending: pendingMessages, editReferences: editorReferences,
            attachmentLedger: attachmentLifecycle, pendingCapture: noteSeed.map { .init(text: $0, area: noteDraftArea, source: noteDraftSource) }, ownedEdits: editorBuffers.filter { $0.key.hasPrefix("legacy:") })
    }

    var composerURL: URL { storageURL.deletingLastPathComponent().appendingPathComponent("composer-state.json") }
    func loadComposerState() {
        composerLoaded = false
        defer { composerLoaded = true }
        let placeholder = composerURL.deletingLastPathComponent().appendingPathComponent(".composer-state.json.icloud")
        if !FileManager.default.fileExists(atPath: composerURL.path), FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: composerURL)
            composerWritable = false; composerWarning = "草稿正在等待 iCloud 下载，请在 Finder 中保留下载后重新打开。"; return
        }
        guard FileManager.default.fileExists(atPath: composerURL.path) else { return }
        do {
            let data = try Data(contentsOf: composerURL)
            let state = try JSONDecoder().decode(ComposerState.self, from: data)
            guard state.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            conversationDrafts = state.drafts; draftOwners = state.owners
            conversationModels = state.models; conversationSkills = state.skills
            conversationAttachments = state.attachments ?? [:]
            pendingMessages = (state.pending ?? []).map { item in
                var restored = item
                if item.state == "sending" || item.state == "uncertain" {
                    restored.state = "uncertain"; restored.detail = "上次发送结果待核对，请先查看原会话；不会自动重发"
                } else { restored.state = "paused"; restored.detail = "重开后已暂停，确认后发送" }
                return restored
            }
            noteSeed = state.pendingCapture?.text; noteDraftArea = state.pendingCapture?.area ?? ""; noteDraftSource = state.pendingCapture?.source
            attachmentLifecycle = state.attachmentLedger ?? [:]
            editorReferences = state.editReferences ?? [:]
            for (key, value) in state.ownedEdits ?? [:] where key.hasPrefix("legacy:") { editorBuffers[key] = value }
            composerData = data; composerWritable = true; composerWarning = nil
        } catch {
            composerWritable = false
            composerWarning = "草稿文件暂不可读，已保留原文件；当前输入请先复制保留。"
        }
    }
    func scheduleComposerSave() {
        guard composerLoaded else { return }
        composerSaveTask?.cancel(); composerSaving = true
        composerSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveComposerState()
        }
    }
    @discardableResult func saveComposerState() -> Bool {
        guard composerLoaded, composerWritable else { return false }
        do {
            let state = currentComposerState()
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(state)
            if data != composerData {
                try FileManager.default.createDirectory(at: composerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try CockpitStorage.save(data, to: composerURL, expected: composerData)
                composerData = data; composerWarning = nil
            }
            composerWarning = nil; composerSaving = false
            return true
        } catch {
            composerSaving = false
            composerWarning = "草稿保存未完成：" + error.localizedDescription + " 请保留当前窗口。"
            return false
        }
    }
}
