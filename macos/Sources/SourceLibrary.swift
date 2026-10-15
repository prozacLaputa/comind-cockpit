import Foundation

/// A view of explicitly linked originals. Nothing here is persisted or sent to a model.
enum SourceLibraryGroup: String, CaseIterable {
    case notes = "我的笔记"
    case rules = "CoMind 协作规则"
    case work = "CoMind 工作资料"
    var symbol: String {
        switch self { case .notes: "book.closed"; case .rules: "slider.horizontal.3"; case .work: "folder" }
    }
    var detail: String {
        switch self {
        case .notes: "个人背景与长期记录，保存在 Obsidian 原笔记中。"
        case .rules: "约定 AI 如何协作；规则草稿仍需核对，不作为个人事实。"
        case .work: "执行过程与参考材料，保存在 CoMind 原目录中。"
        }
    }
}

struct SourceReviewLocation: Identifiable, Equatable {
    let line: Int
    let title: String
    var id: Int { line }
}

struct SourceTextBlock: Identifiable {
    let line: Int
    let text: String
    var id: Int { line }
}

enum SourceReviewLocations {
    private static let pendingWords = ["待你核对", "待本人核对", "待核对", "待确认"]
    private static let closedWords = ["已核对", "已确认", "已忽略", "无需核对", "不再追问", "不再核对", "已解决"]
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    private static func isClosed(_ text: String) -> Bool {
        let text = plain(text).replacingOccurrences(of: #"^[-*+]\s+(?:\[[ xX]\]\s*)?"#, with: "", options: .regularExpression)
        return text.range(of: #"^(?:(?:已核对|已确认|已忽略|无需核对|不再追问|不再核对|已解决)(?:[\s·：:]|$)|~~)"#, options: .regularExpression) != nil
    }
    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, plain(String(line.dropFirst(hashes))))
    }

    static func visibleLines(_ lines: [String]) -> [Bool] {
        var visible = Array(repeating: false, count: lines.count)
        var fence: Character?
        var fenceLength = 0
        var comment = false
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let first = line.first, first == "`" || first == "~" {
                let length = line.prefix(while: { $0 == first }).count
                if length >= 3 {
                    if fence == first && length >= fenceLength { fence = nil }
                    else if fence == nil { fence = first; fenceLength = length }
                    continue
                }
            }
            if line.contains("<!--") { comment = true }
            let hidden = comment || fence != nil || line.hasPrefix(">") || line.hasPrefix("[^") || raw.hasPrefix("    ") || raw.hasPrefix("\t")
            if line.contains("-->") { comment = false }
            visible[index] = !hidden
        }
        return visible
    }

    /// Recognize explicit Markdown markers only, never infer unresolved facts from prose.
    /// One location is a section or an explicitly labelled line, not a guessed issue count.
    static func find(in text: String, candidateFile: Bool = false) -> [SourceReviewLocation] {
        let lines = text.components(separatedBy: .newlines)
        let visible = visibleLines(lines)
        var result: [SourceReviewLocation] = []
        var covered = Set<Int>()
        for index in lines.indices where visible[index] {
            let line = plain(lines[index])
            guard let (level, title) = heading(line),
                  pendingWords.contains(where: title.contains) || (candidateFile && title == "New"),
                  !closedWords.contains(where: title.contains), !covered.contains(index) else { continue }
            let end = ((index + 1)..<lines.count).first { visible[$0] && (heading(plain(lines[$0]))?.0 ?? 7) <= level } ?? lines.count
            let content = ((index + 1)..<end).filter { visible[$0] && !plain(lines[$0]).isEmpty }
            // A retained heading containing only resolved entries must not show as pending.
            let allBullets = content.filter { lines[$0].range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) != nil }
            let indent = allBullets.map { lines[$0].prefix(while: { $0 == " " }).count }.min()
            let bullets = allBullets.filter { lines[$0].prefix(while: { $0 == " " }).count == indent }
            let hasOpen = !bullets.isEmpty ? bullets.contains { !isClosed(lines[$0]) && !lines[$0].contains("- [x]") && !lines[$0].contains("- [X]") } : content.contains { !isClosed(lines[$0]) && !["无", "暂无", "无。", "暂无。", "无待核对内容", "暂无待核对内容"].contains(plain(lines[$0])) }
            if hasOpen { result.append(.init(line: index, title: title == "New" ? "规则待审草稿" : title)) }
            covered.formUnion(index..<end)
        }
        for index in lines.indices where visible[index] && !covered.contains(index) {
            let line = plain(lines[index])
            guard !isClosed(line), heading(line) == nil,
                  line.range(of: #"^(?:[-*+]\s+(?:\[ \]\s*)?)?(?:待你核对|待本人核对|待核对|待确认)[：:]"#, options: .regularExpression) != nil ||
                    (line.hasPrefix("|") && line.split(separator: "|").map { plain(String($0)) }.contains(where: { pendingWords.contains($0) })) else { continue }
            result.append(.init(line: index, title: "待核对标记"))
        }
        return result.sorted { $0.line < $1.line }
    }

    static func blocks(in text: String) -> [SourceTextBlock] {
        let lines = text.components(separatedBy: .newlines)
        var result: [SourceTextBlock] = [], start = 0
        for index in lines.indices where lines[index].isEmpty {
            if start < index { result.append(.init(line: start, text: lines[start..<index].joined(separator: "\n"))) }
            start = index + 1
        }
        if start < lines.count { result.append(.init(line: start, text: lines[start...].joined(separator: "\n"))) }
        return result
    }
}

struct SourceLibraryItem: Identifiable {
    let source: CoMindSource
    let group: SourceLibraryGroup
    let title: String
    let location: String
    let reviews: [SourceReviewLocation]
    let issue: String?
    var fingerprint: String? = nil
    var id: UUID { source.id }

    static func inspect(_ source: CoMindSource, repository: URL) -> Self {
        var group: SourceLibraryGroup = source.path.hasPrefix("note:") || source.path.hasPrefix("notes/") ? .notes : CoMindFiles.kind(source.path) == .document ? .work : .rules
        var title = URL(fileURLWithPath: source.path).deletingPathExtension().lastPathComponent
        var location = source.path
        do {
            let file = try CoMindFiles.url(source.path, in: repository)
            title = file.deletingPathExtension().lastPathComponent
            if source.path == CoMindFiles.memory { title = "协作约定" }
            if source.path == CoMindFiles.candidates { title = "规则待审草稿" }
            if let notes = try KnowledgeSourceLocator.resolve(source.path, repo: repository) {
                group = .notes
                if let root = try KnowledgeSourceLocator.notesRoot(repository) { location = "我的笔记/" + String(notes.path.dropFirst(root.path.count + 1)) }
            } else { location = "CoMind/" + source.path }
            let version = try CoMindFiles.read(source.path, in: repository)
            return .init(source: source, group: group, title: title, location: location,
                         reviews: SourceReviewLocations.find(in: version.text, candidateFile: group == .rules && CoMindFiles.kind(source.path) == .candidates), issue: nil, fingerprint: version.sha256)
        } catch {
            let nsError = error as NSError
            let message: String
            if nsError.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(nsError.code) {
                message = "原文件暂不可用，请等待同步或重新定位。"
            } else if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                message = "暂时没有读取原文件的权限，请检查文件访问权限。"
            } else { message = error.localizedDescription }
            return .init(source: source, group: group, title: title, location: location, reviews: [], issue: message)
        }
    }
}
