import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Page: String, CaseIterable, Identifiable {
    case overview = "总览", areas = "我的阵地", files = "文件", codex = "Codex 会话"
    static var allCases: [Page] { [.overview, .areas, .files, .codex] }
    var id: String { rawValue }
    var symbol: String { switch self { case .overview: "house"; case .areas: "folder"; case .files: "doc.text"; case .codex: "bubble.left.and.bubble.right" } }
}
struct Area: Identifiable, Codable {
    var id = UUID().uuidString
    var name: String
    var purpose: String
    var symbol: String = "square.stack.3d.up"
    var createdAt = Date()
}
struct ThreadLink: Identifiable, Codable {
    var id: String { (projectID.map { "project:" + $0.uuidString } ?? "area:" + areaID) + ":" + threadID }
    var areaID: String
    var threadID: String
    var projectID: UUID? = nil
}
struct DocumentRecord: Identifiable, Codable {
    var id = UUID()
    var name, areaID, source, path, body: String
    var linkedAreas: [String] = []
    var localURL: URL? = nil
    var updated = Date()
    var origin: DocumentOrigin? = nil
    var revisions: [DocumentRevision]? = nil
    var isReal: Bool { localURL != nil }
}
struct ProjectRecord: Identifiable, Codable {
    var id = UUID()
    var name, goal, areaID, path: String
    var status = "待开始"
}
struct CaptureRecord: Identifiable, Codable {
    var id = UUID()
    var text, areaID: String
    var date = Date()
}
struct Snapshot: Codable {
    var version = 6
    var areas: [Area]? = nil
    var threadLinks: [ThreadLink]? = nil
    var documents: [DocumentRecord]
    var projects: [ProjectRecord]
    var captures: [CaptureRecord]
    var completed: Set<String>
    var progressReports: [String: AreaProgressReport]? = nil
    var employeeProfiles: [String: EmployeeProfile]? = nil
    var employeeMemories: [EmployeeMemory]? = nil
    var employeeProfileDrafts: [String: EmployeeProfileDraft]? = nil
    var employeeProfileHistory: [String: [EmployeeProfileRevision]]? = nil
    var archivedAreas: [Area]? = nil
    var discardedDocuments: [DocumentRecord]? = nil
    var actions: [TrackedAction]? = nil
    var position: WorkspacePosition? = nil
    var knowledge: [String: KnowledgeReference]? = nil
    var coMind: CoMindConnection? = nil
    var areaSeen: [String: [String: String]]? = nil
    var deferredNoteReviews: Set<String>? = nil
    var noteOrganizations: [NoteOrganization]? = nil
    var noteWritebackPolicies: [String: NoteWritebackPolicy]? = nil
    var progressSchedules: [String: ProgressSchedule]? = nil
}

@MainActor final class AppStore: ObservableObject {
    let codex: CodexBridge
    var makeEmployeeSetupEngine: () -> EmployeeSetupEngine = { EmployeeSetupEngine() }
    var makeProgressEngine: () -> ProgressEngine = { ProgressEngine() }
    @Published var archivedAreas: [Area] = []
    @Published var discardedDocuments: [DocumentRecord] = []
    @Published var actions: [TrackedAction] = []
    @Published var knowledge: [String: KnowledgeReference] = [:]
    @Published var coMind: CoMindConnection?
    @Published var areaSeen: [String: [String: String]] = [:]
    @Published var deferredNoteReviews: Set<String> = []
    var manualConsolidationThreads: Set<String> = []
    var organizationPreparing = false
    @Published var noteOrganizations: [NoteOrganization] = []
    @Published var noteWritebackPolicies: [String: NoteWritebackPolicy] = [:]
    @Published var organizationReceipts: [String: OrganizationReceipt] = [:]
    @Published var organizationErrors: [String: String] = [:]
    @Published var originalStates: [UUID: OriginalFileState] = [:]
    @Published var noteActionArea = ""
    var noteComparisonRunID: String?
    let originalWatcher = OriginalFileWatcher()
    var originalActivityTask: Task<Void, Never>?
    @Published var editingCoMindSource: CoMindSource?
    @Published var focusCoMindSourceReview = false
    var readingLocations: [String: ReadingLocation] = [:]
    var readingPositionDirty = false
    @Published var requestedMessageID: String?
    @Published var settingsTab = "外观"
    var positionTask: Task<Void, Never>?
    var initialized = false
    @Published var page: Page = .overview { didSet { schedulePositionSave() } }
    @Published var areaID: String? = nil { didSet { schedulePositionSave() } }
    @Published var areaTab = "概况" { didSet { schedulePositionSave() } }
    @Published var selectedProject: UUID? = nil
    @Published var areas: [Area] = []
    @Published var threadLinks: [ThreadLink] = []
    @Published var documents: [DocumentRecord] = []
    @Published var projects: [ProjectRecord] = []
    @Published var progressReports: [String: AreaProgressReport] = [:]
    @Published var employeeProfiles: [String: EmployeeProfile] = [:]
    @Published var employeeMemories: [EmployeeMemory] = []
    @Published var employeeProfileDrafts: [String: EmployeeProfileDraft] = [:]
    @Published var employeeProfileHistory: [String: [EmployeeProfileRevision]] = [:]
    @Published var draftingEmployees: Set<String> = []
    @Published var employeeSetupErrors: [String: String] = [:]
    @Published var employeeBatchRunning = false
    var employeeSetupTasks: [String: Task<Void, Never>] = [:]
    var employeeBatchTask: Task<Void, Never>?

    @Published var reviewingAreas: Set<String> = []
    @Published var reviewErrors: [String: String] = [:]
    @Published var editingMemoryID: UUID?
    var reviewTasks: [String: Task<Void, Never>] = [:]
    var reviewRequests: [String: Bool] = [:] // explicit refresh only
    var reviewWorkerIDs: [String: UUID] = [:]
    var progressPolicy = ProgressReviewPolicy()
    @Published var progressSchedules: [String: ProgressSchedule] = [:]
    var canEdit: Bool { persistenceAvailable }
    var composerLoaded = false
    var composerData: Data?
    var composerWritable = true
    var composerSaveTask: Task<Void, Never>?
    @Published var editorBuffers: [String: EditingDraft] = [:]
    @Published var editorReferences: [String: EditingDraftReference] = [:]
    @Published var editorWarnings: [String: String] = [:]
    var editorFiles: [String: URL] = [:]
    var editorVersions: [String: Data] = [:]
    var editorSaveTasks: [String: Task<Void, Never>] = [:]
    @Published var noteDraftArea = ""
    @Published var noteDraftSource: UUID?
    @Published var noteSeed: String? { didSet { scheduleComposerSave() } }
    @Published var recoveryBusy = false
    @Published var composerWarning: String?
    @Published var composerSaving = false
    var draftOwners: [String: String] = [:] { didSet { scheduleComposerSave() } }
    @Published var conversationDrafts: [String: String] = [:] { didSet { scheduleComposerSave() } }
    @Published var conversationModels: [String: CodexModelSelection] = [:] { didSet { scheduleComposerSave() } }
    @Published var conversationSkills: [String: [CodexSkill]] = [:] { didSet { scheduleComposerSave() } }
    @Published var attachmentLifecycle: [String: AttachmentLifecycle] = [:]
    var pendingDispatching = false
    @Published var pendingMessages: [PendingChatMessage] = [] { didSet { scheduleComposerSave() } }
    @Published var conversationAttachments: [String: [ChatAttachment]] = [:] { didSet { scheduleComposerSave() } }
    @Published var lastAreaThread: [String: String] = [:] { didSet { schedulePositionSave() } }
    @Published var composerSeed: String?
    @Published var editingCaptureID: UUID?
    @Published var captures: [CaptureRecord] = []
    @Published var completed: Set<String> = []
    @Published var filePreview: DocumentRecord? = nil
    @Published var deletingDocumentID: UUID?
    @Published var search = ""
    @Published var source = "全部"
    @Published var sheet: Sheet? = nil
    @Published var managingThread: CodexThread?
    @Published var editingAreaID: String? = nil
    @Published var message: String? = nil
    private var notificationID = UUID()
    @Published var storageWarning: String? = nil
    @Published var focusCapture = false
    enum Sheet: String, Identifiable { case noteWriteback, noteChanges, reviewNotes, consolidateNotes, note, theme, link, area, manageArea, deleteArea, deleteThread, renameThread, deleteDocument, editCapture, employee, memory, codexInfo, search, coMindSource; var id: String { rawValue }; var modalWidth: CGFloat { switch self { case .noteWriteback, .noteChanges, .reviewNotes, .consolidateNotes, .coMindSource, .search, .employee, .theme, .codexInfo: 640; default: 520 } } }
    let storageURL: URL
    private(set) var usesICloud = false
    var loadedData: Data?
    private var recoveryAvailable = false
    var storageLabel: String { usesICloud ? "iCloud Drive" : "本机" }
    func requestThreadRename(_ thread: CodexThread) {
        guard codex.canRenameThread(thread) else { return }
        managingThread = codex.threadMap[thread.id] ?? thread
        codex.error = nil; sheet = .renameThread
    }
    func revealStorage() { NSWorkspace.shared.activateFileViewerSelecting([storageURL]) }
    var persistenceAvailable = true
    var contextArea: String { areaID ?? projects.first(where: { $0.id == selectedProject })?.areaID ?? "" }
    init(storageURL: URL? = nil, codexBridge: CodexBridge? = nil) {
        codex = codexBridge ?? CodexBridge()
        if let storageURL { self.storageURL = storageURL }
        else {
            do {
                self.storageURL = try CockpitStorage.prepare(root: CockpitStorage.cloudRoot, legacy: CockpitStorage.legacy)
                usesICloud = true
            } catch {
                self.storageURL = CockpitStorage.legacy
                persistenceAvailable = false
                storageWarning = "iCloud 暂不可用，当前为只读：\(error.localizedDescription)"
            }
        }
        if FileManager.default.fileExists(atPath: self.storageURL.path) {
            do {
                let data = try Data(contentsOf: self.storageURL)
                let s = try JSONDecoder().decode(Snapshot.self, from: data)
                loadedData = data
                guard [1, 2, 3, 4, 5, 6].contains(s.version) else { throw CocoaError(.coderReadCorrupt) }
                documents = s.documents; projects = s.projects; captures = s.captures; completed = s.completed
                areas = s.areas ?? []; threadLinks = s.threadLinks ?? []; progressReports = s.progressReports ?? [:]
                employeeProfiles = s.employeeProfiles ?? [:]; employeeMemories = s.employeeMemories ?? []
                employeeProfileDrafts = s.employeeProfileDrafts ?? [:]; employeeProfileHistory = s.employeeProfileHistory ?? [:]
                archivedAreas = s.archivedAreas ?? []; discardedDocuments = s.discardedDocuments ?? []
                actions = s.actions ?? []; knowledge = s.knowledge ?? [:]; coMind = s.coMind
                areaSeen = s.areaSeen ?? [:]; deferredNoteReviews = s.deferredNoteReviews ?? []
                noteOrganizations = (s.noteOrganizations ?? []).map { value in var run = value; if run.state == "running" { run.state = "interrupted" }; return run }
                noteWritebackPolicies = s.noteWritebackPolicies ?? [:]
                progressSchedules = s.progressSchedules ?? [:]
                recoveryAvailable = !knowledge.isEmpty
                try loadKnowledge()
                if let position = s.position {
                    page = Page(rawValue: position.page) ?? .overview
                    areaID = areas.contains(where: { $0.id == position.areaID }) ? position.areaID : nil
                    areaTab = WorkspacePosition.resolvedAreaTab(position.areaTab)
                    lastAreaThread = position.lastAreaThread; readingLocations = position.reading
                }
                if s.version == 1 {
                    // One-time removal of exact prototype fixtures; preserve all other user records.
                    let backup = self.storageURL.deletingLastPathComponent().appendingPathComponent("state-before-demo-cleanup.json")
                    if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: self.storageURL, to: backup) }
                    let demoPaths = ["context/inbox/hardware/硬件选型笔记.md", "我的笔记/想法/桌面伙伴的想法.md", "profile/README-draft.md"]
                    documents.removeAll { (demoPaths.contains($0.path) && $0.localURL == nil && $0.source != "本机笔记") || ($0.name == "native-file-check.md" && $0.path.hasSuffix("personal-cockpit/macos/qa/native-file-check.md")) }
                    projects.removeAll { ($0.name == "GitHub 主页整理" && $0.goal == "梳理作品展示与主页内容" && $0.path == "项目目录/profile") || ($0.name == "桌面伙伴表情开发" && $0.goal == "验证原生 App 中项目与阵地的衔接" && $0.path == "项目目录/desktop-companion") }
                    completed = []
                    // Unrecognised records remain accessible without inventing replacement areas.
                    for i in documents.indices { documents[i].areaID = ""; documents[i].linkedAreas = [] }
                    for i in projects.indices { projects[i].areaID = "" }
                    for i in captures.indices { captures[i].areaID = "" }
                    persist()
                }
                if s.version < 4 {
                    let backup = self.storageURL.deletingLastPathComponent().appendingPathComponent("state-before-area-work-v4.json")
                    if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
                    migrateLegacyProjects(); persist()
                }
            } catch {
                persistenceAvailable = false
                storageWarning = "已有数据无法读取，已保留原文件。当前修改不会覆盖它。"
            }
        }
        loadComposerState()
        initialized = true
        for (area, report) in progressReports { reconcileActions(report, area: area) }
        codex.onTurnCompleted = { [weak self] thread, status in
            guard let self else { return }
            if self.manualConsolidationThreads.remove(thread) == nil { self.reviewAfterTurn(thread, status: status) }
            self.organizationFinished(thread: thread, status: status)
            self.pendingTurnFinished(status: status)
            self.refreshOriginalActivity()
        }
        codex.onReadyForPending = { [weak self] in
            Task { [weak self] in await Task.yield(); await self?.dispatchPendingMessage() }
        }
        resumeProgressSchedules()
        codex.onSubmissionRecovered = { [weak self] keys, text in
            guard let self else { return }
            for key in keys where self.conversationDrafts[key] == text { self.conversationDrafts[key] = "" }
            let pendingIDs = Set(keys.compactMap { $0.hasPrefix("pending:") ? UUID(uuidString: String($0.dropFirst(8))) : nil })
            if !pendingIDs.isEmpty { self.pendingMessages.removeAll { pendingIDs.contains($0.id) }; self.saveComposerState() }
        }
    }
    private func migrateLegacyProjects() {
        for project in projects {
            var destination = project.areaID
            if !areas.contains(where: { $0.id == destination }) {
                destination = "legacy-work-" + project.id.uuidString
                areas.append(Area(id: destination, name: project.name, purpose: project.goal, symbol: "folder"))
            }
            let body = "# " + project.name + "\n\n" + project.goal + "\n\n状态：" + project.status + "\n目录：" + project.path
            documents.append(DocumentRecord(name: project.name + " · 工作记录.md", areaID: destination, source: "本机笔记", path: project.path, body: body))
            for link in threadLinks.filter({ $0.projectID == project.id }) {
                if !threadLinks.contains(where: { $0.projectID == nil && $0.areaID == destination && $0.threadID == link.threadID }) {
                    threadLinks.append(.init(areaID: destination, threadID: link.threadID))
                }
            }
        }
        threadLinks.removeAll { $0.projectID != nil }
        projects = []
    }
    func recoverKnowledgeReference(area: String, reference: KnowledgeReference) throws {
        guard recoveryAvailable, let loadedData else { throw BridgeError(message: "当前源不可恢复，请先恢复数据位置或索引文件。") }
        var saved = try JSONDecoder().decode(Snapshot.self, from: loadedData)
        saved.knowledge?[area] = reference
        let data = try JSONEncoder().encode(saved)
        try CockpitStorage.save(data, to: storageURL, expected: loadedData)
        self.loadedData = data; knowledge[area] = reference
        try loadKnowledge()
        persistenceAvailable = true; storageWarning = nil
    }
    func schedulePositionSave() {
        guard initialized else { return }
        positionTask?.cancel()
        positionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.persist()
        }
    }
    func snapshot() -> Snapshot {
        Snapshot(areas: areas, threadLinks: threadLinks, documents: documents, projects: projects, captures: captures, completed: completed, progressReports: progressReports, employeeProfiles: employeeProfiles, employeeMemories: employeeMemories, employeeProfileDrafts: employeeProfileDrafts, employeeProfileHistory: employeeProfileHistory, archivedAreas: archivedAreas, discardedDocuments: discardedDocuments, actions: actions, position: .init(page: page.rawValue, areaID: areaID, areaTab: areaTab, lastAreaThread: lastAreaThread, reading: readingLocations), knowledge: knowledge, coMind: coMind, areaSeen: areaSeen, deferredNoteReviews: deferredNoteReviews, noteOrganizations: noteOrganizations, noteWritebackPolicies: noteWritebackPolicies, progressSchedules: progressSchedules)
    }
    @discardableResult func persist() -> Bool {
        // Working drafts and the index have independent failure domains.
        if composerLoaded { _ = saveComposerState() }
        guard persistenceAvailable else {
            storageWarning = storageWarning ?? "数据暂不可写，请在设置 → 恢复中处理。"
            return false
        }
        do {
            var value = snapshot()
            let references = try writeKnowledge(into: &value)
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let loadedData, ((try? JSONDecoder().decode(Snapshot.self, from: loadedData).version) ?? 6) < 5 {
                let backup = storageURL.deletingLastPathComponent().appendingPathComponent("state-before-employee-setup-v5.json")
                if !FileManager.default.fileExists(atPath: backup.path) { try KnowledgeVault.writeNew(loadedData, to: backup) }
            }
            try CockpitStorage.save(data, to: storageURL, expected: loadedData)
            loadedData = data; knowledge = references; storageWarning = nil; readingPositionDirty = false
            return true
        } catch {
            // Unique knowledge stays in its explicitly bound domain; never spill private bodies into a generic recovery directory.
            storageWarning = "保存未完成：\(error.localizedDescription) [\((error as NSError).domain):\((error as NSError).code)] 请在设置 → 恢复中重试，或保留工作副本后读取最新数据。"
            return false
        }
    }
    func areaName(_ id: String) -> String { areas.first { $0.id == id }?.name ?? "未归类" }
    func createArea(name: String, purpose: String, symbol: String, configureEmployee: Bool = false) { guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return };
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let area = Area(name: clean, purpose: purpose, symbol: symbol)
        areas.append(area)
        if coMind != nil {
            var scopes = coMind?.originalsOnlyAreas ?? []
            scopes.insert(area.id); coMind?.originalsOnlyAreas = scopes
        }
        persist()
        guard storageWarning == nil else { return }
        sheet = nil; openArea(area.id)
        if configureEmployee {
            editingAreaID = area.id; sheet = .employee
            requestEmployeeDraft(area.id)
        }
    }
    func manageArea(_ id: String) { editingAreaID = id; sheet = .manageArea }
    func confirmAreaDeletion(_ id: String) {
        guard areas.contains(where: { $0.id == id }) else { return }
        editingAreaID = id; sheet = .deleteArea
    }
    func renameArea(_ id: String, name: String) {
        guard let area = areas.first(where: { $0.id == id }) else { return }
        updateArea(id, name: name, purpose: area.purpose, symbol: area.symbol)
    }
    func updateArea(_ id: String, name: String, purpose: String, symbol: String) {
        guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = areas.firstIndex(where: { $0.id == id }) else { return }
        areas[index].name = clean
        areas[index].purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        areas[index].symbol = symbol
        persist()
        if storageWarning == nil { sheet = nil; notify("阵地已更新") }
    }
    func deleteArea(_ id: String) {
        guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return }
        guard areas.contains(where: { $0.id == id }) else { return }
        let previous = areas
        archivedAreas.append(areas.first { $0.id == id }!)
        areas.removeAll { $0.id == id }
        persist()
        guard storageWarning == nil else { areas = previous; archivedAreas.removeAll { $0.id == id }; return }
        employeeSetupTasks.removeValue(forKey: id)?.cancel(); reviewTasks.removeValue(forKey: id)?.cancel()
        sheet = nil; editingAreaID = nil
        if areaID == id { navigate(.areas) }
        notify("阵地已归档，可在设置的恢复页找回")
    }
    @discardableResult func moveArea(_ id: String, to targetID: String) -> Bool {
        guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return false }
        guard id != targetID, let source = areas.firstIndex(where: { $0.id == id }),
              let target = areas.firstIndex(where: { $0.id == targetID }) else { return false }
        let previous = areas
        let area = areas.remove(at: source)
        areas.insert(area, at: target)
        guard persist() else { areas = previous; return false }
        return true
    }
    func moveArea(_ id: String, offset: Int) {
        guard let index = areas.firstIndex(where: { $0.id == id }), areas.indices.contains(index + offset) else { return }
        moveArea(id, to: areas[index + offset].id)
    }
    func linkThread(_ threadID: String, areaID: String) { guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return };
        guard areas.contains(where: { $0.id == areaID }), !threadLinks.contains(where: { $0.threadID == threadID && $0.areaID == areaID }) else { return }
        let previous = threadLinks
        threadLinks.append(.init(areaID: areaID, threadID: threadID))
        if persist() { notify("会话已关联到阵地") } else { threadLinks = previous }
    }
    func unlinkThread(_ threadID: String, areaID: String) { guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return };
        threadLinks.removeAll { $0.threadID == threadID && $0.areaID == areaID }; persist()
    }
    func linkThread(_ threadID: String, projectID: UUID) {
        guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return }
        guard projects.contains(where: { $0.id == projectID }), !threadID.isEmpty,
              !threadLinks.contains(where: { $0.threadID == threadID && $0.projectID == projectID }) else { return }
        threadLinks.append(.init(areaID: "", threadID: threadID, projectID: projectID))
        persist()
        if storageWarning == nil { notify("会话已关联到项目") }
    }
    func unlinkThread(_ threadID: String, projectID: UUID) {
        guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return }
        threadLinks.removeAll { $0.threadID == threadID && $0.projectID == projectID }
        persist()
    }
    func removeDeletedThreadReferences(_ id: String) {
        threadLinks.removeAll { $0.threadID == id }
        persist()
        if storageWarning == nil { notify("会话已删除，阵地关联已清理") }
        else { notify("Codex 会话已删除，但关联清理尚未保存，请处理存储提示") }
    }
    func navigate(_ p: Page) { composerSeed = nil; codex.selected = nil; codex.messages = []; page = p; areaID = nil; selectedProject = nil; search = "" }
    func openArea(_ id: String) { composerSeed = nil; codex.selected = nil; codex.messages = []; areaID = id; page = .areas; areaTab = "开始工作"; selectedProject = nil }
    var materialsSettingsArea: Area? { page == .areas ? areas.first { $0.id == areaID } : nil }
    func openMaterialsFromSettings() {
        sheet = nil
        if materialsSettingsArea != nil {
            // Switching a tab must not reset the current chat, an active reply or its draft.
            areaTab = "资料"
        } else { navigate(.areas) }
    }
    func openProject(_ id: UUID) { page = .areas; areaID = nil; selectedProject = id }
    func notify(_ text: String) {
        let id = UUID(); notificationID = id; message = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notificationID == id { message = nil }
        }
    }
    func toggle(_ area: String) { guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return }; if completed.contains(area) { completed.remove(area) } else { completed.insert(area) }; persist() }
    func saveProgress(_ report: AreaProgressReport, area: String) {
        guard persistenceAvailable, areas.contains(where: { $0.id == area }) else { return }
        var cached = report
        // Progress remains a dated, rebuildable view. It must not recreate a second memory store.
        if coMind?.prefersOriginals(for: area) == true { cached.content.memories = nil }
        progressReports[area] = cached; reconcileActions(cached, area: area); ingestMemoryCandidates(cached, area: area); persist()
    }
    func editCapture(_ id: UUID, text: String) {
        guard persistenceAvailable, let index = captures.firstIndex(where: { $0.id == id }) else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let previous = captures
        captures[index].text = clean; captures[index].date = Date()
        if persist() { sheet = nil } else { captures = previous }
    }
    func deleteCapture(_ id: UUID) {
        guard persistenceAvailable else { return }
        let previous = captures
        captures.removeAll { $0.id == id }
        if persist() { sheet = nil } else { captures = previous }
    }
    func discussCapture(_ note: CaptureRecord) {
        openArea(note.areaID); composerSeed = "请结合这个阵地继续讨论这条随手记：\n" + note.text
        notify("已准备好讨论内容，选择会话后发送")
    }
    func capture(_ text: String, area: String) { guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return }; let clean = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }; captures.insert(.init(text: clean, areaID: area), at: 0); persist(); if storageWarning == nil { notify("已保存到\(storageLabel)，原话归入对应阵地") } }
    func createProject(name: String, goal: String, area: String, path: String) { guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return };
        let p = ProjectRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines), goal: goal, areaID: area, path: path)
        projects.insert(p, at: 0); persist(); sheet = nil; openProject(p.id); notify("项目已保存；目录仅作规划，尚未创建")
    }
    func saveResult(_ text: String, area: String, isExcerpt: Bool = false, origin: DocumentOrigin? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        requestOriginalCapture(text, area: area, origin: origin, excerpt: isExcerpt)
    }
    func requestDocumentDeletion(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        deletingDocumentID = id
        filePreview = nil
        sheet = .deleteDocument
    }
    /// Deletes an owned record or removes an external reference. Never touches its source file.
    @discardableResult func deleteDocument(_ id: UUID) -> Bool {
        guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return false }
        guard let document = documents.first(where: { $0.id == id }) else { return false }
        let previous = documents
        discardedDocuments.append(document)
        documents.removeAll { $0.id == id }
        persist()
        guard storageWarning == nil else {
            documents = previous; discardedDocuments.removeAll { $0.id == id }
            notify("未能删除，资料已保留；请查看存储提示")
            return false
        }
        if filePreview?.id == id { filePreview = nil }
        if deletingDocumentID == id { deletingDocumentID = nil; sheet = nil }
        notify(document.isReal ? "已移除资料，原文件已保留" : "资料已删除")
        return true
    }
    func workDirectory(for area: String) -> URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("工作文件").appendingPathComponent(area.isEmpty ? "未归类" : area)
    }
    func addNote(name: String, body: String, area: String) {
        requestOriginalCapture((name.isEmpty ? "" : "### " + name + "\n\n") + body, area: area)
    }
    func link(_ id: UUID, area: String) { guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return };
        guard let i = documents.firstIndex(where: { $0.id == id }), documents[i].areaID != area, !documents[i].linkedAreas.contains(area) else { return }
        let previous = documents
        documents[i].linkedAreas.append(area)
        if persist() { sheet = nil; notify("已建立关联，原文件未移动") } else { documents = previous }
    }
    func setStatus(_ id: UUID, _ status: String) { guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return }; if let i = projects.firstIndex(where: { $0.id == id }) { projects[i].status = status; persist() } }
    func documents(for area: String) -> [DocumentRecord] { documents.filter { $0.areaID == area || $0.linkedAreas.contains(area) } }
    var filteredDocuments: [DocumentRecord] { documents.filter { (source == "全部" || $0.source == source) && (search.isEmpty || "\($0.name) \($0.body) \($0.path)".localizedCaseInsensitiveContains(search)) } }
    func chooseLocalFile() { guard persistenceAvailable else { notify("数据暂不可写，请先处理上方存储提示"); return };
        let panel = NSOpenPanel(); panel.title = "选择要关联的本地文本文件"; panel.message = "只读取你选中的文件，不扫描所在目录。"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attrs = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attrs.isRegularFile == true, (attrs.fileSize ?? 0) <= 2_000_000 else { notify("目前支持 2 MB 以内的文本文件"); return }
            _ = try String(contentsOf: url, encoding: .utf8)
            let id = contextArea
            if let existing = documents.first(where: { $0.localURL == url }) { filePreview = existing; return }
            // Persist only the selected path; do not copy private content into the demo store.
            let record = DocumentRecord(name: url.lastPathComponent, areaID: id, source: "本地文件", path: url.path, body: "", localURL: url)
            documents.insert(record, at: 0); persist(); filePreview = record
        } catch { notify("无法读取这个文件：\(error.localizedDescription)") }
    }
    func readBody(_ record: DocumentRecord) -> String {
        do { return try documentText(record) }
        catch { return error.localizedDescription }
    }
    /// 展示可使用提示文案；发送、搜索和导出必须处理读取失败。
    nonisolated static func documentText(_ record: DocumentRecord) throws -> String {
        guard var url = record.localURL else { return record.body }
        do {
            url.removeAllCachedResourceValues()
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true else { throw BridgeError(message: "请选择普通文本文件") }
            guard (attributes.fileSize ?? 0) <= 2_000_000 else { throw BridgeError(message: "文件超过 2 MB") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 2_000_001) ?? Data()
            guard data.count <= 2_000_000 else { throw BridgeError(message: "文件超过 2 MB") }
            guard let text = String(data: data, encoding: .utf8) else { throw BridgeError(message: "文件不是 UTF-8 文本") }
            return text
        } catch {
            let failure = error as NSError
            let reason: String
            if failure.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code) { reason = "文件已移动或不存在" }
            else if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError { reason = "当前没有读取权限" }
            else { reason = error.localizedDescription }
            throw DocumentReadFailure(id: record.id, name: record.name, reason: reason)
        }
    }
    func documentText(_ record: DocumentRecord) throws -> String { try Self.documentText(record) }
    func relocateDocument(_ id: UUID) {
        guard canEdit, let record = documents.first(where: { $0.id == id }), record.isReal else { return }
        let panel = NSOpenPanel(); panel.title = "重新定位：" + record.name
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try relocateDocument(id, to: url); notify("资料位置已更新") }
            catch { notify(error.localizedDescription) }
        }
    }
    func relocateDocument(_ id: UUID, to url: URL) throws {
        guard canEdit, let index = documents.firstIndex(where: { $0.id == id }), documents[index].isReal else { throw BridgeError(message: "资料暂不可编辑") }
        var updated = documents[index]; updated.localURL = url; updated.path = url.path; updated.name = url.lastPathComponent
        _ = try documentText(updated)
        let previous = documents[index]; documents[index] = updated; persist()
        if let storageWarning { documents[index] = previous; throw BridgeError(message: storageWarning) }
        if filePreview?.id == id { filePreview = updated }
    }
    func exportDocument(_ record: DocumentRecord, to url: URL) throws {
        let text = try documentText(record)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func export(_ record: DocumentRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = record.name; panel.title = "导出笔记"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportDocument(record, to: url); notify("已导出笔记") } catch { notify("导出失败：\(error.localizedDescription)") }
    }
}

struct DocumentReadFailure: LocalizedError {
    let id: UUID
    let name: String
    let reason: String
    var errorDescription: String? { "无法读取「\(name)」：\(reason)。请重新定位文件或取消携带。" }
}
