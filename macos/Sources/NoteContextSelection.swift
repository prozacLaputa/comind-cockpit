import Foundation

/// Rebuilt from the current originals for each send. No persisted body, summary or retrieval index.
enum NoteContextSelection {
    struct Passage {
        let heading: String
        let firstLine: Int
        let lastLine: Int
        let text: String
        let protected: Bool
    }
    static func terms(_ text: String) -> Set<String> {
        let stops: Set<String> = ["这个", "那个", "一下", "现在", "我的", "可以", "什么", "怎么", "继续", "之前", "一下吧", "我想", "帮我", "有没有", "一下呢", "关于", "问题"]
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var result = Set<String>()
        for word in words {
            if word.unicodeScalars.allSatisfy({ $0.isASCII }) {
                if word.count > 1 { result.insert(word) }
            } else {
                let chars = Array(word)
                for size in [2, 3] where chars.count >= size {
                    for i in 0...(chars.count - size) { result.insert(String(chars[i..<(i + size)])) }
                }
            }
        }
        return result.subtracting(stops)
    }
    static func passages(_ text: String) -> [Passage] {
        let lines = text.components(separatedBy: "\n")
        var headings: [(Int, String)] = [], start = 0, result: [Passage] = [], fenced = false
        func flush(_ end: Int) {
            guard end > start else { return }
            let body = lines[start..<end].joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let heading = headings.map(\.1).joined(separator: " / ")
            // Keep entire boundary/correction/review passages. They must not disappear merely
            // because their vocabulary differs from the current question.
            let guarded = ["约束", "边界", "禁忌", "过敏", "风险", "注意事项", "待核对", "待确认", "冲突", "更正", "纠正", "已确认", "不确定", "基本信息", "当前状态", "个人偏好"]
            let explicit = ["不考虑", "不要", "不能", "不允许", "不吃", "避免", "尚未确认", "已停用", "不再", "以此为准", "修正为", "改为", "更正为"]
            result.append(.init(heading: heading, firstLine: start + 1, lastLine: end, text: body,
                                protected: guarded.contains(where: { (heading + body).contains($0) }) || explicit.contains(where: body.contains)))
        }
        for i in lines.indices {
            let line = lines[i]
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle() }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if !fenced && (1...6).contains(hashes) && line.dropFirst(hashes).first == " " {
                flush(i); start = i
                headings.removeAll { $0.0 >= hashes }; headings.append((hashes, line))
            } else if !fenced && line.trimmingCharacters(in: .whitespaces).isEmpty && i - start > 1 {
                flush(i); start = i + 1
            }
        }
        flush(lines.count)
        return result
    }
    static func context(_ versions: [CoMindFileVersion], request: String, recentUserText: String = "") -> [String] {
        let query = terms(request), recent = terms(recentUserText)
        return versions.map { version in
            // Rules and small originals are cheap enough to preserve intact.
            if version.data.count <= 3000 || CoMindFiles.kind(version.path) != .document { return CoMindFiles.context([version])[0] }
            let chunks = passages(version.text)
            var chosen = Set(chunks.indices.filter { chunks[$0].protected })
            // Preserve the document introduction, which often identifies speaker, date and scope.
            if !chunks.isEmpty { chosen.insert(0) }
            func score(_ passage: Passage) -> Int {
                let body = passage.text.lowercased(), heading = passage.heading.lowercased()
                return query.filter { body.contains($0) }.count * 4 + query.filter { heading.contains($0) }.count * 6
                    + recent.filter { body.contains($0) || heading.contains($0) }.count
            }
            let ranked = chunks.indices.filter { !chosen.contains($0) && score(chunks[$0]) > 0 }.sorted {
                let a = score(chunks[$0]), b = score(chunks[$1]); return a == b ? $0 < $1 : a > b
            }
            // A soft budget: protected passages are never silently truncated to fit it.
            var bytes = chosen.reduce(0) { $0 + chunks[$1].text.utf8.count }
            for index in ranked where bytes + chunks[index].text.utf8.count <= 6000 {
                chosen.insert(index); bytes += chunks[index].text.utf8.count
            }
            // Carry the opening context of each selected section (often the original date
            // or speaker), including its parent headings, without fabricating a summary.
            let selectedHeadings = chosen.map { chunks[$0].heading }
            for heading in selectedHeadings {
                var ancestors = heading.components(separatedBy: " / ")
                while !ancestors.isEmpty {
                    let prefix = ancestors.joined(separator: " / ")
                    let lead = chunks.indices.filter { chunks[$0].heading == prefix }.prefix(2)
                    chosen.formUnion(lead)
                    ancestors.removeLast()
                }
            }
            if chosen.count == chunks.count { return CoMindFiles.context([version])[0] }
            var seen = Set<String>()
            let outline = chunks.filter { !$0.heading.isEmpty && seen.insert($0.heading).inserted }
                .map { item in
                    let indices = chunks.indices.filter { chunks[$0].heading == item.heading }
                    return "L\(item.firstLine) \(item.heading)（已附 \(indices.filter { chosen.contains($0) }.count)/\(indices.count) 段）"
                }.joined(separator: "\n")
            let excerpts = chosen.sorted().map { index in
                let c = chunks[index]
                return "[L\(c.firstLine)–L\(c.lastLine) · \(c.heading.isEmpty ? "开篇" : c.heading)]\n\(c.text)"
            }.joined(separator: "\n\n")
            return """
            原笔记按需片段 · \(version.file.lastPathComponent)
            来源：\(version.path)
            本次读取版本：SHA256 \(version.sha256)
            原文件共 \(version.text.components(separatedBy: "\n").count) 行；仅附 \(chosen.count)/\(chunks.count) 段原文，不是全文或摘要。未附内容仍存在。
            完整章节目录：
            \(outline.isEmpty ? "没有 Markdown 标题，请按需补读原件。" : outline)
            本次原文片段：
            \(excerpts)
            """
        }
    }
    static func readingInstructions(_ versions: [CoMindFileVersion]) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let commands = versions.map { version in
            let tool = version.repository.appendingPathComponent("tools/scripts/knowledge-bridge/bridge.py")
            return "\(version.path)：python3 -B \(quote(tool.path)) --repo \(quote(version.repository.path)) read \(quote(version.path))"
        }.joined(separator: "\n")
        return """
        按需读取约定：本次只提供最新版的相关原文片段、必要边界与完整章节目录，不保证本地词语匹配找全所有语义相关内容。涉及未附章节、相关章节未附全、同义表达、指代不清、历史变化、冲突或全面判断时，先用下面的只读命令补读对应原件，再作结论；不能以「没附」推断「没记录」。没有命中时也必须先补读，不能只靠开篇回答个人情况。
        本轮版本替代旧会话附带的旧版本；未附片段不能用旧版本补齐。补读返回 text 与 sha256；若版本已变化，改用新原件，重新核对依据。保留日期、说话者、待核对状态；不能凭片段覆盖整篇。写回前必须读完整当前原件去重并走版本保护。
        只允许补读本轮勾选的来源，不搜索其他笔记。无法补读时明确覆盖不足，不能声称已掌握全部背景。以下入口只授予本轮读取范围，不代表修改授权：
        \(commands)
        """
    }
}
