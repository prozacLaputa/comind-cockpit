import Foundation
import CryptoKit

/// The cockpit stores only these references after a reviewed migration.
/// All bodies, drafts, discarded records and earlier revisions stay within this domain.
struct KnowledgeReference: Codable {
    var repository: URL
    var directory: String
    var revision: String? = nil
    var category: KnowledgeCategory
    var root: URL { repository.appendingPathComponent(directory) }
}
enum KnowledgeCategory: String, Codable, CaseIterable {
    case general = "普通主题", health = "健康私密", people = "人物私密"
}
struct KnowledgeData: Codable {
    var area: Area
    var documents: [DocumentRecord]
    var discardedDocuments: [DocumentRecord]
    var captures: [CaptureRecord]
    var memories: [EmployeeMemory]
    var profile: EmployeeProfile?
    var profileDraft: EmployeeProfileDraft?
    var profileHistory: [EmployeeProfileRevision]
    var progress: AreaProgressReport?
    var actions: [TrackedAction]
    var drafts: [String: String]
}
struct KnowledgeRevision: Codable {
    var date: Date
    var previous: String?
    var records: [String: String]
}
enum KnowledgeVault {
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }()
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validate(_ ref: KnowledgeReference) throws {
        let repo = ref.repository.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent("protocols/agent-contract.md").path),
              FileManager.default.fileExists(atPath: repo.appendingPathComponent("corpus").path) else { throw BridgeError(message: "请选择包含 protocols 与 corpus 的 CoMind 根目录。") }
        let relative = ref.directory
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.isEmpty else { throw BridgeError(message: "知识目录必须是 CoMind 内的相对路径。") }
        let path = ref.root.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(repo.path + "/") else { throw BridgeError(message: "知识目录不能通过链接指向 CoMind 外部。") }
        switch ref.category {
        case .health:
            guard relative.hasPrefix("corpus/health/private/") else { throw BridgeError(message: "健康内容只能进入 corpus/health/private/。") }
        case .people:
            guard relative.hasPrefix("corpus/people/private/") else { throw BridgeError(message: "人物内容只能进入 corpus/people/private/。") }
        case .general:
            guard relative.hasPrefix("corpus/") || relative.hasPrefix("context/inbox/"), !relative.hasPrefix("corpus/health/"), !relative.hasPrefix("corpus/people/") else { throw BridgeError(message: "普通主题请选择 corpus 的对应主题，或 context/inbox 下的工作目录。私密内容需单独选择分类。") }
        }
    }
    static func safeFile(_ root: URL, _ path: String) throws -> URL {
        let result = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard result.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), !path.hasPrefix("/") else { throw BridgeError(message: "知识索引含无效路径。") }
        return result
    }
    static func revision(_ reference: KnowledgeReference) throws -> KnowledgeRevision? {
        try validate(reference)
        guard let revision = reference.revision else { return nil }
        let url = try safeFile(reference.root, "revisions/" + revision + ".json")
        let data = try Data(contentsOf: url)
        guard hash(data) == revision else { throw BridgeError(message: "知识版本已被外部修改，停止覆盖；请在设置中检查来源。") }
        return try JSONDecoder().decode(KnowledgeRevision.self, from: data)
    }
    static func writeNew(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".writing-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        do { try FileManager.default.moveItem(at: temporary, to: url) }
        catch {
            guard (try? Data(contentsOf: url)) == data else { throw error }
        }
    }
    static func recordData(_ value: Any, markdown: Bool) throws -> Data {
        if markdown, var object = value as? [String: Any], let body = object.removeValue(forKey: "body") as? String {
            let metadata = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            return Data(("<!-- comind-record\n" + String(decoding: metadata, as: UTF8.self) + "\n-->\n\n" + body).utf8)
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes])
    }
    static func decodeRecord(_ data: Data) throws -> Any {
        let text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("<!-- comind-record\n"), let end = text.range(of: "\n-->\n\n") {
            let start = text.index(text.startIndex, offsetBy: "<!-- comind-record\n".count)
            var object = try JSONSerialization.jsonObject(with: Data(text[start..<end.lowerBound].utf8)) as! [String: Any]
            object["body"] = String(text[end.upperBound...]); return object
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    static func load(_ reference: KnowledgeReference) throws -> KnowledgeData {
        guard let manifest = try revision(reference) else { throw BridgeError(message: "尚未完成知识迁移。") }
        var values: [String: Any] = [:]
        let arrays: Set<String> = ["documents", "discardedDocuments", "captures", "memories", "profileHistory", "actions"]
        for key in arrays { values[key] = [Any]() }
        for (key, filename) in manifest.records.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: safeFile(reference.root, filename))
            guard URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent == hash(data) else { throw BridgeError(message: "知识文件校验不符，已保留源文件，停止加载。") }
            let value = try decodeRecord(data)
            let group = String(key.split(separator: "/")[0])
            if arrays.contains(group) { var list = values[group] as? [Any] ?? []; list.append(value); values[group] = list }
            else { values[group] = value }
        }
        return try JSONDecoder().decode(KnowledgeData.self, from: JSONSerialization.data(withJSONObject: values))
    }
    static func save(_ value: KnowledgeData, reference: KnowledgeReference, forceRevision: Bool = false) throws -> KnowledgeReference {
        try validate(reference)
        // Validate every referenced body before creating a new version. Missing source is never an empty store.
        if reference.revision != nil { _ = try load(reference) }
        let previous = try revision(reference)
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
        var records: [String: String] = [:]
        for (group, value) in object {
            let entries: [(String, Any)]
            if let array = value as? [Any] {
                entries = array.enumerated().map { index, item in (group + "/" + String(format: "%06d", index) + "-" + ((item as? [String: Any])?["id"] as? String ?? "record"), item) }
            } else { entries = [(group, value)] }
            for (key, item) in entries {
                let markdown = group == "documents" || group == "discardedDocuments"
                let data = try recordData(item, markdown: markdown)
                let filename = "records/" + group + "/" + hash(data) + (markdown ? ".md" : ".json")
                let url = try safeFile(reference.root, filename)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    guard try Data(contentsOf: url) == data else { throw BridgeError(message: "已有知识文件冲突，未覆盖。") }
                } else { try writeNew(data, to: url) }
                records[key] = filename
            }
        }
        if previous?.records == records && !forceRevision { return reference }
        let data = try encoder.encode(KnowledgeRevision(date: Date(), previous: reference.revision, records: records))
        let name = hash(data)
        let target = try safeFile(reference.root, "revisions/" + name + ".json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeNew(data, to: target)
        var next = reference; next.revision = name
        // Read-back makes the final cockpit pointer update the only commit point.
        _ = try load(next)
        return next
    }
    static func history(_ reference: KnowledgeReference) throws -> [(String, Date)] {
        let dir = try safeFile(reference.root, "revisions")
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.compactMap { url in
            let data = try Data(contentsOf: url)
            guard hash(data) == url.deletingPathExtension().lastPathComponent else { return nil }
            let item = try JSONDecoder().decode(KnowledgeRevision.self, from: data)
            return (url.deletingPathExtension().lastPathComponent, item.date)
        }.sorted { $0.1 > $1.1 }
    }
}

extension AppStore {
    func knowledgeData(_ area: Area) -> KnowledgeData {

        return .init(area: area, documents: documents.filter { $0.areaID == area.id }, discardedDocuments: discardedDocuments.filter { $0.areaID == area.id }, captures: captures.filter { $0.areaID == area.id }, memories: employeeMemories.filter { $0.areaID == area.id }, profile: employeeProfiles[area.id], profileDraft: employeeProfileDrafts[area.id], profileHistory: employeeProfileHistory[area.id] ?? [], progress: progressReports[area.id], actions: actions.filter { $0.areaID == area.id }, drafts: [:])
    }
    func applyKnowledge(_ value: KnowledgeData) {
        let id = value.area.id
        if let index = areas.firstIndex(where: { $0.id == id }) { areas[index] = value.area }
        if let index = archivedAreas.firstIndex(where: { $0.id == id }) { archivedAreas[index] = value.area }
        documents.removeAll { $0.areaID == id }; documents += value.documents
        discardedDocuments.removeAll { $0.areaID == id }; discardedDocuments += value.discardedDocuments
        captures.removeAll { $0.areaID == id }; captures += value.captures
        employeeMemories.removeAll { $0.areaID == id }; employeeMemories += value.memories
        employeeProfiles[id] = value.profile; employeeProfileDrafts[id] = value.profileDraft
        employeeProfileHistory[id] = value.profileHistory; progressReports[id] = value.progress
        actions.removeAll { $0.areaID == id }; actions += value.actions
        // Import legacy working drafts once; restoring a knowledge version must not replace current input.
        if !composerLoaded {
            for key in value.drafts.keys { draftOwners[key] = id }
            conversationDrafts.merge(value.drafts) { current, _ in current }
        }
    }
    func loadKnowledge() throws {
        // Decode all scopes before publishing any, avoiding partially restored state.
        let values = try knowledge.map { id, reference -> KnowledgeData in
            let value = try KnowledgeVault.load(reference)
            guard value.area.id == id else { throw BridgeError(message: "知识版本与阵地不匹配。") }
            return value
        }
        for value in values { applyKnowledge(value) }
    }
    func writeKnowledge(into snapshot: inout Snapshot) throws -> [String: KnowledgeReference] {
        var references = knowledge
        let scopes = areas + archivedAreas + (knowledge[""] == nil ? [] : [Area(id: "", name: "未归类", purpose: "")])
        for area in scopes {
            guard let reference = references[area.id] else { continue }
            references[area.id] = try KnowledgeVault.save(knowledgeData(area), reference: reference)
            // After read-back, strip all authoritative domain bodies from the cockpit index.
            snapshot.documents.removeAll { $0.areaID == area.id }; snapshot.discardedDocuments?.removeAll { $0.areaID == area.id }
            snapshot.captures.removeAll { $0.areaID == area.id }; snapshot.employeeMemories?.removeAll { $0.areaID == area.id }
            snapshot.employeeProfiles?[area.id] = nil; snapshot.employeeProfileDrafts?[area.id] = nil
            snapshot.employeeProfileHistory?[area.id] = nil; snapshot.progressReports?[area.id] = nil
            snapshot.actions?.removeAll { $0.areaID == area.id }
            if let index = snapshot.areas?.firstIndex(where: { $0.id == area.id }) { snapshot.areas?[index].purpose = "" }
            if let index = snapshot.archivedAreas?.firstIndex(where: { $0.id == area.id }) { snapshot.archivedAreas?[index].purpose = "" }
        }
        snapshot.knowledge = references
        return references
    }
    func migrateKnowledge(area: Area, reference: KnowledgeReference) {
        guard canEdit, knowledge[area.id] == nil else { return }
        do {
            // First migration keeps the exact original in place. No generic backup of sensitive content.
            let legacy = storageURL.deletingLastPathComponent().appendingPathComponent("state-before-knowledge-v6.json")
            if !FileManager.default.fileExists(atPath: legacy.path), FileManager.default.fileExists(atPath: storageURL.path) { try FileManager.default.copyItem(at: storageURL, to: legacy) }
            let next = try KnowledgeVault.save(knowledgeData(area), reference: reference)
            knowledge[area.id] = next; persist()
            if storageWarning != nil { knowledge[area.id] = nil; return }
            notify("知识已迁入 CoMind，原快照保留，草稿自动保存已启用")
        } catch { storageWarning = "迁移未完成，原数据未移动：" + error.localizedDescription }
    }
    func restoreKnowledge(area: String, revision: String) {
        guard var reference = knowledge[area] else { return }
        do {
            let before = knowledgeData((areas + archivedAreas).first { $0.id == area } ?? Area(id: "", name: "未归类", purpose: ""))
            let oldReference = reference
            reference.revision = revision
            let value = try KnowledgeVault.load(reference)
            guard value.area.id == area else { throw BridgeError(message: "无法恢复其他阵地的版本。") }
            if !canEdit {
                let recovered = try KnowledgeVault.save(value, reference: reference, forceRevision: true)
                try recoverKnowledgeReference(area: area, reference: recovered)
                notify("已从完整旧版本恢复，损坏的版本仍保留供核对"); return
            }
            applyKnowledge(value)
            // Save restored values as a new head so undo never destroys newer versions.
            knowledge[area] = oldReference; persist()
            if storageWarning != nil { applyKnowledge(before) }
            else { notify("已恢复为所选版本，较新的版本仍保留") }
        } catch { storageWarning = error.localizedDescription }
    }
}
