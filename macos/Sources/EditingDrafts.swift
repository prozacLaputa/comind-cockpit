import Foundation

struct PendingOriginalCapture: Codable { var text: String; var area: String; var source: UUID? }

/// Unfinished edits are working state, never chat context or confirmed knowledge.
struct EditingDraft: Codable, Equatable {
    var title = ""
    var text = ""
    var baseHash = ""
    var updated = Date()
    var active: Bool? = true
}
struct EditingDraftReference: Codable, Identifiable {
    var id: String
    var source: CoMindSource
    var repository: URL
    var area: String
    var draftFile: URL? = nil
}
enum EditingDraftFiles {
    static func checked(_ file: URL, key: String, version: CoMindFileVersion) throws -> URL {
        let notes = try KnowledgeSourceLocator.notesRoot(version.repository)
        let root = notes.flatMap { file.path.hasPrefix($0.path + "/") ? $0 : nil } ?? version.repository
        guard file.path.hasPrefix(root.path + "/"),
              file.lastPathComponent == "draft-" + ChatAttachments.hash(Data(key.utf8)) + ".json",
              file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".history" else {
            throw CoMindFiles.failure("编辑草稿位置不匹配，已保留原引用。")
        }
        return try KnowledgeSourceLocator.safe(String(file.path.dropFirst(root.path.count + 1)), root: root, metadata: true)
    }
    static func file(key: String, version: CoMindFileVersion) throws -> URL {
        let directory = try CoMindFiles.historyDirectory(for: version)
        return directory.appendingPathComponent("draft-" + ChatAttachments.hash(Data(key.utf8)) + ".json")
    }
    static func read(_ file: URL) throws -> (EditingDraft?, Data?) {
        guard FileManager.default.fileExists(atPath: file.path) else { return (nil, nil) }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 2_000_000 else { throw CoMindFiles.failure("编辑草稿不可读，原文件保留。") }
        let data = try Data(contentsOf: file)
        return (try JSONDecoder().decode(EditingDraft.self, from: data), data)
    }
}
extension AppStore {
    func editingKey(_ source: CoMindSource) -> String { "original:" + source.id.uuidString }
    func loadEditingDraft(key: String, source: CoMindSource, version: CoMindFileVersion, area: String) throws {
        guard editorBuffers[key] == nil else { return }
        let file: URL
        if let saved = editorReferences[key]?.draftFile {
            file = try EditingDraftFiles.checked(saved, key: key, version: version)
            guard FileManager.default.fileExists(atPath: file.path) else { throw CoMindFiles.failure("原文件的编辑草稿暂不可用，已保留恢复入口，请检查下载或移动位置。") }
        } else { file = try EditingDraftFiles.file(key: key, version: version) }
        let (draft, data) = try EditingDraftFiles.read(file)
        editorFiles[key] = file; editorVersions[key] = data
        if let draft, draft.active != false {
            editorBuffers[key] = draft
            editorReferences[key] = .init(id: key, source: source, repository: version.repository, area: area, draftFile: file)
        }
    }
    func retainEditingDraft(key: String, value: EditingDraft, source: CoMindSource?, version: CoMindFileVersion?, area: String) {
        editorBuffers[key] = value
        if let source, let version {
            do {
                let file = try EditingDraftFiles.checked(editorFiles[key] ?? EditingDraftFiles.file(key: key, version: version), key: key, version: version)
                editorFiles[key] = file
                editorReferences[key] = .init(id: key, source: source, repository: version.repository, area: area, draftFile: file)
            } catch { editorWarnings[key] = error.localizedDescription; return }
        }
        editorSaveTasks[key]?.cancel()
        editorSaveTasks[key] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            _ = self.flushEditingDraft(key)
        }
    }
    @discardableResult func flushEditingDraft(_ key: String) -> Bool {
        guard let value = editorBuffers[key] else { return true }
        // Legacy owned-record drafts stay in the same app working file; original bodies never do.
        guard let file = editorFiles[key] else { return saveComposerState() }
        do {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CockpitStorage.save(data, to: file, expected: editorVersions[key])
            guard try Data(contentsOf: file) == data else { throw CoMindFiles.failure("编辑草稿回读不一致") }
            editorVersions[key] = data; editorWarnings[key] = nil
            return saveComposerState()
        } catch { editorWarnings[key] = "修改仍在当前窗口：" + error.localizedDescription; return false }
    }
    @discardableResult func clearEditingDraft(_ key: String) -> Bool {
        editorSaveTasks.removeValue(forKey: key)?.cancel()
        if let file = editorFiles[key] {
            do {
                // An empty tombstone also has version protection, including across devices.
                let data = try JSONEncoder().encode(EditingDraft(active: false))
                try CockpitStorage.save(data, to: file, expected: editorVersions[key])
                editorVersions[key] = data
            } catch { editorWarnings[key] = error.localizedDescription; return false }
        }
        editorBuffers[key] = nil; editorWarnings[key] = nil; editorReferences[key] = nil
        return saveComposerState()
    }
    func resumeEditingDraft(_ reference: EditingDraftReference) {
        guard coMind?.repository == reference.repository,
              let source = coMind?.sources.first(where: { $0.id == reference.source.id && !$0.areas.isEmpty }) else {
            notify("来源已解除关联，请先重新关联原文件；同目录草稿仍保留"); return
        }
        if reference.id.hasPrefix("append:") {
            noteDraftArea = reference.area; noteDraftSource = source.id; sheet = .note
        } else { openCoMindSource(source) }
    }
}
