import Foundation

/// Metadata comes from the official service; the cockpit never copies skill bodies.
struct CodexSkill: Identifiable, Equatable, Codable {
    let name, path, description, displayName, scope: String
    let enabled: Bool
    var id: String { path + "\n" + name }
    var title: String { displayName.isEmpty ? name : displayName }
    var sourceLabel: String {
        switch scope {
        case "repo": return "当前目录"
        case "user": return "个人"
        case "system": return "内置"
        case "admin": return "组织"
        default: return "本机"
        }
    }
    var input: [String: Any] { ["type": "skill", "name": name, "path": path] }
    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let path = raw["path"] as? String, path.hasPrefix("/"),
              let enabled = raw["enabled"] as? Bool else { return nil }
        let interface = raw["interface"] as? [String: Any] ?? [:]
        self.name = name; self.path = path; self.enabled = enabled
        displayName = interface["displayName"] as? String ?? ""
        description = interface["shortDescription"] as? String ?? raw["shortDescription"] as? String ?? raw["description"] as? String ?? ""
        scope = raw["scope"] as? String ?? ""
    }
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [name, displayName, description].contains { $0.localizedStandardContains(query) }
    }
}

struct CodexSkillCatalog {
    let skills: [CodexSkill]
    let warnings: [String]
    init(response: [String: Any], cwd: String) throws {
        let expected = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard let entries = response["data"] as? [[String: Any]],
              let entry = entries.first(where: {
                  guard let path = $0["cwd"] as? String, path.hasPrefix("/") else { return false }
                  return URL(fileURLWithPath: path).standardizedFileURL.path == expected
              }), let rawSkills = entry["skills"] as? [[String: Any]] else {
            throw BridgeError(message: "Codex 未返回当前工作目录的 Skill 列表，请重试。")
        }
        var seen = Set<String>()
        skills = rawSkills.compactMap(CodexSkill.init).filter { seen.insert($0.id).inserted }
            .sorted { a, b in
                if a.enabled != b.enabled { return a.enabled }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        var notices = (entry["errors"] as? [[String: Any]] ?? []).map { error in
            let file = URL(fileURLWithPath: error["path"] as? String ?? "SKILL.md").deletingLastPathComponent().lastPathComponent
            return file + "：" + (error["message"] as? String ?? "无法读取")
        }
        if rawSkills.contains(where: { CodexSkill($0) == nil }) { notices.append("部分 Skill 信息不完整，已跳过。") }
        warnings = notices
    }
    func resolve(_ selection: [CodexSkill]) throws -> [CodexSkill] {
        var seen = Set<String>()
        return try selection.filter { seen.insert($0.id).inserted }.map { chosen in
            guard let fresh = skills.first(where: { $0.id == chosen.id }), fresh.enabled else {
                throw BridgeError(message: "Skill「\(chosen.title)」已停用、移除或不适用于当前目录。请移除标签后重新选择。")
            }
            return fresh
        }
    }
}
