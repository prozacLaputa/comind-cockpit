import Foundation

/// A read-only ownership manifest: identifiers/statuses only, never personal knowledge bodies.
struct KnowledgeInventoryItem: Identifiable {
    let id: String
    let areaID: String
    let kind: String
    let state: String
    let versions: Int
    let destination: String
}
enum KnowledgeInventory {
    static func rows(_ snapshot: Snapshot) -> [KnowledgeInventoryItem] {
        var result: [KnowledgeInventoryItem] = []
        func add(_ id: String, _ area: String, _ kind: String, _ state: String, _ versions: Int = 0, _ destination: String) {
            result.append(.init(id: id, areaID: area, kind: kind, state: state, versions: versions, destination: destination))
        }
        for m in snapshot.employeeMemories ?? [] {
            add("memory/" + m.id.uuidString, m.areaID, "记忆", m.state.rawValue, m.history.count, "逐条核对：通用协作记忆 → 既有候选/正式机制；个人事实 → 已有 Obsidian 原件；健康/人物 → 各自笔记目录")
        }
        for (id, _) in snapshot.employeeProfiles ?? [:] {
            add("profile/" + id, id, "员工配置", "已启用", (snapshot.employeeProfileHistory?[id] ?? []).count, "仅职责与沟通配置 → 驾驶舱设置；个人事实不得夹带其中")
        }
        for (id, _) in snapshot.employeeProfileDrafts ?? [:] {
            add("profile-draft/" + id, id, "配置草稿", "待审核", 0, "与对应配置同域，待审核状态不变")
        }
        for (id, _) in snapshot.progressReports ?? [:] {
            add("progress/" + id, id, "AI 进展", "生成快照", 0, "有日期的可重建会话摘要，不是长期记忆；聊天读原笔记")
        }
        for a in snapshot.actions ?? [] {
            add("action/" + a.id.uuidString, a.areaID, "后续事项", a.state.rawValue, a.feedback.count, "用户确认、反馈与历史 → 对应领域文件；未确认建议保持候选")
        }
        for d in snapshot.documents + (snapshot.discardedDocuments ?? []) {
            add("document/" + d.id.uuidString, d.areaID, d.isReal ? "外部文件引用" : "内嵌资料", d.isReal ? "保持原位" : "待归属", d.revisions?.count ?? 0, d.isReal ? "保留原路径，仅引用" : "对应 Obsidian 原文件；来源和历史一并保留")
        }
        for c in snapshot.captures { add("capture/" + c.id.uuidString, c.areaID, "随手记", "待归属", 0, "按内容归入已有原笔记；健康/人物仍限各自目录") }
        return result.sorted { $0.id < $1.id }
    }
    static func markdown(_ snapshot: Snapshot) -> String {
        let rows = rows(snapshot)
        let areas = (snapshot.areas ?? []) + (snapshot.archivedAreas ?? [])
        func clean(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "／").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["# 当前知识与应用数据清单", "", "以下仅包含当前应用内的标识与状态，不包含知识正文。已归入原笔记的条目不再列作旧记忆；本表不证明尚存条目已迁移。", "", "| 标识 | 阵地 | 类型 | 状态 | 历史数 | 归属规则 |", "| --- | --- | --- | --- | ---: | --- |"]
        for row in rows {
            let area = areas.first { $0.id == row.areaID }?.name ?? "未归类"
            lines.append("| \(row.id) | \(clean(area)) | \(row.kind) | \(row.state) | \(row.versions) | \(row.destination) |")
        }
        lines += ["", "共 \(rows.count) 条主记录。阵地名称、目标、草稿等自由文本也须逐条核对；不会按阵地名称自动分类。", "", "主题、排序、员工配置、会话 ID、文件引用以及可重建阶段摘要留在驾驶舱索引。个人长期信息保存在 Obsidian 原笔记，驾驶舱按来源授权读取。", "", "后续归拢继续逐条核对来源、已有笔记和待核对内容，保留版本与回退记录；不自动从旧备份恢复出第二套知识库。"]
        return lines.joined(separator: "\n") + "\n"
    }
}
