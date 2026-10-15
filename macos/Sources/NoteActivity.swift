import Foundation
import CryptoKit
import AppKit

func activityHash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

struct NoteReviewEntry: Identifiable {
    let start: Int
    let end: Int
    let original: String
    var id: String { activityHash(original) }
    var display: String {
        original.replacingOccurrences(of: #"\[\^[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[-*+]\s+(?:\[ \]\s*)?"#, with: "", options: .regularExpression)
    }
}

struct NoteBodyCorrection: Identifiable {
    let line: Int
    let original: String
    var replacement: String
    var id: Int { line }
}

enum NoteReview {
    static func closed(_ line: String) -> Bool {
        let text = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        return text.range(of: #"^(?:(?:已核对|已确认|已忽略|已解决|无需核对|不再追问)(?:[\s·：:]|$)|\[[xX]\]|~~)"#, options: .regularExpression) != nil
    }
    /// Only explicit pending bullets are actionable. Tables, prose and rule schemas stay in the original editor.
    static func entries(_ text: String) -> [NoteReviewEntry] {
        let lines = text.components(separatedBy: "\n")
        let visible = SourceReviewLocations.visibleLines(lines)
        var result: [NoteReviewEntry] = []
        for location in SourceReviewLocations.find(in: text) {
            let start = location.line
            let isHeading = lines[start].hasPrefix("#")
            let level = lines[start].prefix { $0 == "#" }.count
            let end = isHeading ? ((start + 1)..<lines.count).first { index in
                let count = lines[index].prefix { $0 == "#" }.count
                return visible[index] && count > 0 && count <= level && lines[index].dropFirst(count).first == " "
            } ?? lines.count : start + 1
            let candidates = (start..<end).filter { visible[$0] && lines[$0].range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil }
            for index in candidates where !closed(lines[index]) {
                var stop = index + 1
                while stop < end && (lines[stop].hasPrefix("  ") || lines[stop].hasPrefix("\t")) { stop += 1 }
                let raw = lines[index..<stop].joined(separator: "\n")
                if !result.contains(where: { $0.start == index }) { result.append(.init(start: index, end: stop, original: raw)) }
            }
        }
        return result
    }
    static func resolve(_ entry: NoteReviewEntry, version: CoMindFileVersion, conclusion: String?, ignore: Bool, date: Date = Date(), corrections: [NoteBodyCorrection] = []) throws -> String {
        guard entries(version.text).contains(where: { $0.start == entry.start && $0.original == entry.original }) else { throw CoMindFiles.failure("待核对条目已变化，请重新读取。") }
        let clean = conclusion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard ignore || (!clean.isEmpty && !clean.contains("\n") && !clean.contains("\r")) else { throw CoMindFiles.failure("请用一段话填写你的确认结论；系统不会替你猜测答案。") }
        let expression = try NSRegularExpression(pattern: #"\[\^[^\]]+\]"#)
        let first = entry.original.components(separatedBy: "\n")[0]
        let citations = expression.matches(in: first, range: NSRange(first.startIndex..., in: first)).compactMap { Range($0.range, in: first).map { String(first[$0]) } }.joined()
        let stamp = date.ISO8601Format()
        let decision = ignore ? "已忽略 · \(stamp)（本人在驾驶舱操作）：保留原记录，不作为已确认事实。" : "已核对 · \(stamp)（本人在驾驶舱确认）：\(clean)"
        let history = entry.original.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
        let replacement = "- " + decision + citations + "\n  - 原核对记录：\n" + history
        var lines = version.text.components(separatedBy: "\n")
        let allowed = bodyCandidates(version.text)
        guard !ignore || corrections.isEmpty, Set(corrections.map(\.line)).count == corrections.count else { throw CoMindFiles.failure("忽略操作不修改正文，修正位置不能重复。") }
        for correction in corrections {
            guard allowed.contains(where: { $0.line == correction.line && $0.original == correction.original }),
                  !correction.replacement.trimmingCharacters(in: .whitespaces).isEmpty,
                  !correction.replacement.contains("\n"), !correction.replacement.contains("\r") else { throw CoMindFiles.failure("正文位置或修正内容无效，请重新核对原句。") }
            lines[correction.line] = correction.replacement
        }
        lines.replaceSubrange(entry.start..<entry.end, with: [replacement])
        return lines.joined(separator: "\n")
    }
    /// User-selected exact lines outside review/history/code. Never guess which repeated value to replace.
    static func bodyCandidates(_ text: String) -> [NoteBodyCorrection] {
        let lines = text.components(separatedBy: "\n"), visible = SourceReviewLocations.visibleLines(lines)
        var excluded = Set<Int>()
        for marker in SourceReviewLocations.find(in: text) {
            let level = lines[marker.line].prefix { $0 == "#" }.count
            let end = level > 0 ? ((marker.line + 1)..<lines.count).first { index in
                let count = lines[index].prefix { $0 == "#" }.count
                return visible[index] && count > 0 && count <= level && lines[index].dropFirst(count).first == " "
            } ?? lines.count : marker.line + 1
            excluded.formUnion(marker.line..<end)
        }
        return lines.indices.compactMap { index in
            let line = lines[index]
            guard visible[index], !excluded.contains(index), !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  !line.hasPrefix("#"), !line.hasPrefix("  "), !closed(line),
                  line.range(of: #"^\|?[\s:|\-]+\|$"#, options: .regularExpression) == nil else { return nil }
            return .init(line: index, original: line, replacement: line)
        }
    }
    static func suggestedBodyLines(_ entry: NoteReviewEntry, text: String) -> [NoteBodyCorrection] {
        let referencePattern = try! NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#)
        var evidence = entry.original
        for match in referencePattern.matches(in: entry.original, range: NSRange(entry.original.startIndex..., in: entry.original)) {
            guard let range = Range(match.range(at: 1), in: entry.original) else { continue }
            let prefix = "[^" + String(entry.original[range]) + "]:"
            evidence += "\n" + text.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }.joined(separator: "\n")
        }
        let pattern = try! NSRegularExpression(pattern: #"“([^”\n]{4,})”"#)
        let candidates = bodyCandidates(text)
        var found: [NoteBodyCorrection] = []
        for match in pattern.matches(in: evidence, range: NSRange(evidence.startIndex..., in: evidence)) {
            guard let range = Range(match.range(at: 1), in: evidence) else { continue }
            let quote = String(evidence[range]), matches = candidates.filter { $0.original.contains(quote) }
            if matches.count == 1, !found.contains(where: { $0.line == matches[0].line }) { found.append(matches[0]) }
        }
        return found
    }
    static func hasUnstructuredPending(_ text: String) -> Bool {
        var lines = text.components(separatedBy: "\n")
        for entry in entries(text).reversed() { lines.replaceSubrange(entry.start..<entry.end, with: ["- 已核对：用于识别未结构化标记"]) }
        return !SourceReviewLocations.find(in: lines.joined(separator: "\n")).isEmpty
    }

}

struct OriginalFileState {
    let sourceID: UUID
    let fingerprint: String
    let pending: Int
    var reviewIDs: Set<String> = []
    var genericPending = false
    let issue: String?
}
struct NoteUpdate: Identifiable {
    let source: CoMindSource
    let version: CoMindFileVersion
    let previous: String
    let date: Date
    var id: UUID { source.id }
    var title: String { version.file.deletingPathExtension().lastPathComponent }
    var changed: Bool { previous != version.text }
    /// Bound presentation work even for long notes; this is a changed span, not a semantic summary.
    var difference: (removed: String, added: String, truncated: Bool) {
        let old = previous.components(separatedBy: "\n"), new = version.text.components(separatedBy: "\n")
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count) && old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let before = old[prefix..<(old.count - suffix)], after = new[prefix..<(new.count - suffix)]
        return (before.prefix(80).joined(separator: "\n"), after.prefix(80).joined(separator: "\n"), before.count > 80 || after.count > 80)
    }
    static func load(_ source: CoMindSource, repository: URL) throws -> Self? {
        let version = try CoMindFiles.read(source.path, in: repository)
        // Only read history belonging to this explicitly linked original, never a global knowledge log.
        for file in try CoMindFiles.history(for: version).prefix(12) {
            let previous = try CoMindFiles.historyText(file, for: version)
            if previous != version.text {
                let date = (try? version.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return .init(source: source, version: version, previous: previous, date: date)
            }
        }
        return nil
    }
}

/// Watch only parents of explicitly linked originals, so atomic editor saves are also detected.
final class OriginalFileWatcher {
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var paths: Set<String> = []
    func replace(_ urls: [URL], changed: @escaping () -> Void) {
        let wanted = Set(urls.map { $0.deletingLastPathComponent().path })
        guard wanted != paths else { return }
        watchers.forEach { $0.cancel() }; watchers = []; paths = wanted
        for path in wanted {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            watcher.setEventHandler(handler: changed)
            watcher.setCancelHandler { close(descriptor) }
            watcher.resume(); watchers.append(watcher)
        }
    }
    deinit { watchers.forEach { $0.cancel() } }
}

enum AreaNotice: String { case working, attention, unread, none }

extension AppStore {
    func refreshOriginalActivity() {
        originalActivityTask?.cancel()
        let connection = coMind
        originalActivityTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            guard let connection else { self.originalStates = [:]; self.originalWatcher.replace([]) {}; return }
            let sources = connection.sources.filter { !$0.areas.isDisjoint(with: Set(self.areas.map(\.id))) }
            let inspected = await Task.detached(priority: .utility) { sources.map { source -> (OriginalFileState, URL?) in
                do {
                    let version = try CoMindFiles.read(source.path, in: connection.repository)
                    let markers = SourceReviewLocations.find(in: version.text, candidateFile: CoMindFiles.kind(source.path) == .candidates)
                    let isNote = try KnowledgeSourceLocator.resolve(source.path, repo: connection.repository) != nil
                    let entries = isNote ? NoteReview.entries(version.text) : []
                    return (.init(sourceID: source.id, fingerprint: version.sha256, pending: markers.count,
                                  reviewIDs: Set(entries.map(\.id)), genericPending: isNote ? NoteReview.hasUnstructuredPending(version.text) : !markers.isEmpty, issue: nil), version.file)
                } catch { return (.init(sourceID: source.id, fingerprint: "unavailable", pending: 0, issue: error.localizedDescription), try? CoMindFiles.url(source.path, in: connection.repository)) }
            } }.value
            guard !Task.isCancelled, self.coMind == connection else { return }
            self.originalStates = Dictionary(uniqueKeysWithValues: inspected.map { ($0.0.sourceID, $0.0) })
            self.originalWatcher.replace(inspected.compactMap(\.1)) { [weak self] in self?.refreshOriginalActivity() }
            var initialized = false
            for source in sources {
                guard let state = self.originalStates[source.id] else { continue }
                for area in source.areas {
                    let key = "source:" + source.id.uuidString
                    if self.areaSeen[area]?[key] == nil { self.areaSeen[area, default: [:]][key] = state.fingerprint; initialized = true }
                }
            }
            if initialized { self.persist() }
        }
    }
    func unreadThread(in area: String) -> CodexThread? {
        let seen = areaSeen[area] ?? [:]
        return threadLinks.filter { $0.areaID == area }.compactMap { codex.threadMap[$0.threadID] }
            .filter { thread in seen["thread:" + thread.id].map { $0 != String(thread.updated.timeIntervalSince1970) } ?? false }
            .sorted { $0.updated > $1.updated }.first
    }
    func observeThreadActivity() {
        var changed = false
        for link in threadLinks {
            guard let thread = codex.threadMap[link.threadID] else { continue }
            let key = "thread:" + thread.id
            if areaSeen[link.areaID]?[key] == nil {
                areaSeen[link.areaID, default: [:]][key] = String(thread.updated.timeIntervalSince1970); changed = true
            }
        }
        for (area, report) in progressReports where areaSeen[area]?["progress"] == nil {
            areaSeen[area, default: [:]]["progress"] = String(report.generatedAt.timeIntervalSince1970); changed = true
        }
        if changed { persist() }
    }
    func markProgressViewed(_ area: String) {
        guard NSApp?.isActive != false, let report = progressReports[area] else { return }
        let value = String(report.generatedAt.timeIntervalSince1970)
        if areaSeen[area]?["progress"] != value { areaSeen[area, default: [:]]["progress"] = value; persist() }
    }
    func markThreadViewed(_ threadID: String, area: String) {
        guard NSApp?.isActive != false, let thread = codex.threadMap[threadID], codex.runningThreadID != threadID,
              codex.selected?.id == threadID, !codex.reading, !codex.refreshingHistory,
              let loaded = codex.loadedHistoryUpdated[threadID], loaded >= thread.updated else { return }
        let key = "thread:" + threadID, value = String(thread.updated.timeIntervalSince1970)
        guard areaSeen[area]?[key] != value else { return }
        areaSeen[area, default: [:]][key] = value; persist()
    }
    func markSourcesViewed(_ sources: [CoMindSource], versions: [UUID: String], area: String) {
        guard NSApp?.isActive != false else { return }
        var changed = false
        for source in sources where source.areas.contains(area) {
            guard let value = versions[source.id] else { continue }
            let key = "source:" + source.id.uuidString
            if areaSeen[area]?[key] != value { areaSeen[area, default: [:]][key] = value; changed = true }
        }
        if changed { persist() }
    }
    func pendingNoteCount(_ source: CoMindSource) -> Int {
        guard let state = originalStates[source.id] else { return 0 }
        return state.reviewIDs.filter { !deferredNoteReviews.contains(source.id.uuidString + ":" + $0) }.count + (state.genericPending ? 1 : 0)
    }
    func needsNoteAttention(_ source: CoMindSource) -> Bool { pendingNoteCount(source) > 0 || originalStates[source.id]?.issue != nil }
    func areaNotice(_ area: String) -> AreaNotice {
        let threads = Set(threadLinks.filter { $0.areaID == area }.map(\.threadID))
        if let running = codex.runningThreadID, threads.contains(running) {
            if !codex.approvals.isEmpty || !codex.questions.isEmpty { return .attention }
            return .working
        }
        if draftingEmployees.contains(area) || reviewingAreas.contains(area) { return .working }
        if let recovery = codex.recovery, recovery.blocksSending, threads.contains(recovery.thread.id) { return .attention }
        let sources = coMindSources(for: area)
        if sources.contains(where: needsNoteAttention) || employeeProfileDrafts[area] != nil || employeeSetupErrors[area] != nil { return .attention }
        let seen = areaSeen[area] ?? [:]
        if let report = progressReports[area], let value = seen["progress"], value != String(report.generatedAt.timeIntervalSince1970) { return .unread }
        if sources.contains(where: { source in originalStates[source.id].map { seen["source:" + source.id.uuidString] != nil && seen["source:" + source.id.uuidString] != $0.fingerprint } ?? false }) { return .unread }
        if threads.contains(where: { id in codex.threadMap[id].map { seen["thread:" + id] != nil && seen["thread:" + id] != String($0.updated.timeIntervalSince1970) } ?? false }) { return .unread }
        return .none
    }
    func openAreaNotice(_ area: String) {
        let ids = Set(threadLinks.filter { $0.areaID == area }.map(\.threadID))
        if let running = codex.runningThreadID, ids.contains(running) {
            openArea(area); lastAreaThread[area] = running; return
        }
        if let recovery = codex.recovery, recovery.blocksSending, ids.contains(recovery.thread.id) {
            openArea(area); lastAreaThread[area] = recovery.thread.id; return
        }
        if employeeProfileDrafts[area] != nil || employeeSetupErrors[area] != nil || draftingEmployees.contains(area) { showEmployeeSetup(area); return }
        if coMindSources(for: area).contains(where: needsNoteAttention) { openNoteActivity(area); return }
        if let thread = unreadThread(in: area) { openArea(area); lastAreaThread[area] = thread.id; return }
        if reviewingAreas.contains(area) || progressReports[area].map({ areaSeen[area]?["progress"] != String($0.generatedAt.timeIntervalSince1970) }) == true {
            if areaID != area { openArea(area) }; areaTab = "进展"; return
        }
        openNoteActivity(area)
    }
    func openNoteActivity(_ area: String) {
        if areaID != area { openArea(area) }
        areaTab = "资料"
    }
    func requestConsolidation(_ thread: CodexThread, area: String) {
        managingThread = thread; noteActionArea = area; sheet = .consolidateNotes
    }
    func consolidationMessage(thread: CodexThread, area: String, sources: Set<UUID>) async throws -> String {
        guard threadLinks.contains(where: { $0.areaID == area && $0.threadID == thread.id }), let connection = coMind else { throw CoMindFiles.failure("会话或来源关联已变化，请重新选择。") }
        let selected = connection.sources.filter { sources.contains($0.id) && $0.areas.contains(area) }
        guard !selected.isEmpty, Set(selected.map(\.id)) == sources else { throw CoMindFiles.failure("请选择当前阵地已关联的原笔记。") }
        for source in selected {
            guard try KnowledgeSourceLocator.resolve(source.path, repo: connection.repository) != nil else { throw CoMindFiles.failure("整理只写已有个人原笔记，不能改写协作规则。") }
            let path = try CoMindFiles.url(source.path, in: connection.repository)
            guard !path.pathComponents.contains(where: { $0.contains("日记") || $0.contains("梦境") }), path.deletingPathExtension().lastPathComponent.range(of: #"^\d{4}[-.]\d{1,2}[-.]\d{1,2}$"#, options: .regularExpression) == nil else { throw CoMindFiles.failure("日记不作为自动整理目标，请选择主题笔记。") }
        }
        let request = """
        请将当前会话里新增且有长期价值的信息整理并增量写回下面选中的已有原笔记。本次点击是对这些原件的一次整理授权，不扩大后台归拢范围。
        先读取选中原件并去重；只有本人明确自述和本人确认的决定可以直接记，AI 推断、歧义与冲突放在同页「待核对」的独立列表项中，不能自行确认。保留原始日期、说话者、来源会话链接和已有正文。用户消息自动附加的背景不算新的本人自述。
        只处理当前会话中能核实的内容；历史不完整时说明覆盖不足，不宣称全会话已整理。无新增则不写，不新建笔记、不扫描其他会话、不改日记或插件、不修改后台来源登记。遵循下方版本保护写回接口；如果审批或写入失败，明确报告未写入，不绕过保护。完成后简短列出更新的原笔记和待核对项。
        """
        var options = ConversationBackgroundOptions(); options.area = false; options.profile = false; options.memory = false; options.progress = false; options.actions = false; options.sources = sources
        options.fullOriginals = true
        return try await prepareConversationMessage(request: request, areaID: area, options: options, sourceThreadID: thread.id, referenceText: { _ in throw CoMindFiles.failure("本次不读取其他会话。") })
    }
}
