import Foundation
import CryptoKit

/// Only addresses and grants live in the cockpit index. Source bodies are always read from the original file.
struct CoMindSource: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var areas: Set<String>
}
struct CoMindConnection: Codable, Equatable {
    var repository: URL
    var sources: [CoMindSource] = []
    // Optional for backwards-compatible decoding. Store grants and choices, never source bodies.
    var chatSources: [String: Set<UUID>]? = nil
    var originalsOnlyAreas: Set<String>? = nil
    func selectedSources(for area: String) -> Set<UUID> { chatSources?[area] ?? [] }
    func prefersOriginals(for area: String) -> Bool { originalsOnlyAreas?.contains(area) == true }
}
enum CoMindSourceKind: String {
    case formal = "协作规则", candidates = "规则待审草稿", document = "原文件"
}
struct CoMindFileVersion {
    let repository: URL
    let path: String
    let file: URL
    let data: Data
    var text: String { String(data: data, encoding: .utf8)! }
    var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
struct CoMindFileChange {
    let before: CoMindFileVersion
    let after: String
}

/// File operations deliberately do not know about area names, Codex, or old app records.
/// A source is selected explicitly; nothing recursively scans or classifies the personal corpus.
enum CoMindFiles {
    static let memory = "context/memory/memory.md"
    static let candidates = "context/memory/memory-candidates.md"
    static let byteLimit = 1_000_000
    static func failure(_ text: String) -> BridgeError { .init(message: text) }
    static func validateRoot(_ root: URL) throws {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        for path in ["protocols/agent-contract.md", "protocols/write-policy.md", "corpus"] {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else {
                throw failure("请选择包含 protocols 和 corpus 的 CoMind 根目录。")
            }
        }
    }
    static func kind(_ path: String) -> CoMindSourceKind {
        if path == memory || path.hasPrefix("context/core/") { return .formal }
        if path == candidates || path.hasSuffix("/memory-candidates.md") { return .candidates }
        return .document
    }
    static func url(_ path: String, in root: URL) throws -> URL {
        try validateRoot(root)
        if let external = try KnowledgeSourceLocator.resolve(path, repo: root) {
            guard external.pathExtension == "md" else { throw failure("请选择 Markdown 原文件。") }
            return external
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }), path.hasSuffix(".md"),
              path == memory || path == candidates || path.hasPrefix("context/core/") || path.hasPrefix("context/inbox/") || path.hasPrefix("corpus/") else {
            throw failure("只关联 CoMind 中明确选择的 Markdown 原文件；不允许隐藏路径、协议或目录遍历。")
        }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var cursor = root
        for component in parts {
            cursor.appendPathComponent(String(component))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw failure("来源路径包含符号链接，请直接选择真实文件，避免越过私密目录边界。")
            }
        }
        guard cursor.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw failure("来源不在选定的 CoMind 内。") }
        if path.hasPrefix("corpus/health/") && !path.hasPrefix("corpus/health/private/") {
            throw failure("健康正文只接入 corpus/health/private 内的文件。")
        }
        if path.hasPrefix("corpus/people/") && !path.hasPrefix("corpus/people/private/") {
            throw failure("人物正文只接入 corpus/people/private 内的文件。")
        }
        return cursor
    }
    static func relativePath(_ file: URL, in root: URL) throws -> String {
        if let external = try KnowledgeSourceLocator.reference(file, repo: root) {
            _ = try url(external, in: root)
            return external
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(base) else { throw failure("请选择已绑定的 CoMind 或我的笔记中的原文件。") }
        let relative = String(path.dropFirst(base.count))
        _ = try url(relative, in: root)
        return relative
    }
    static func read(_ path: String, in root: URL) throws -> CoMindFileVersion {
        let file = try url(path, in: root)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? byteLimit + 1) <= byteLimit else { throw failure("原文件须是小于 1 MB 的 Markdown 文本。") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit, String(data: data, encoding: .utf8) != nil else { throw failure("原文件过大或不是 UTF-8，未读取为正文。") }
        return .init(repository: root, path: path, file: file, data: data)
    }
    static func candidateDraft(in version: CoMindFileVersion, text: String, source: String, scope: String) throws -> String {
        guard kind(version.path) == .candidates else { throw failure("候选只能追加到选定的 memory-candidates.md。") }
        let clean = [text, source, scope].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard clean.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }) else { throw failure("候选、来源与范围必须填写为单行文字。") }
        var lines = version.text.components(separatedBy: "\n")
        guard let section = lines.firstIndex(of: "## New"), lines.filter({ $0 == "## New" }).count == 1 else { throw failure("候选文件缺少唯一的 New 区块，请先在原编辑器检查格式。") }
        let end = lines[(section + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        let entry = "- candidate: \(clean[0])\n  source: \(clean[1])\n  confidence: medium\n  scope: \(clean[2])\n  confirmation-status: pending\n"
        lines.insert(entry, at: end)
        return lines.joined(separator: "\n")
    }
    static func historyDirectory(for version: CoMindFileVersion) throws -> URL {
        let file = try url(version.path, in: version.repository)
        let history = file.deletingLastPathComponent().appendingPathComponent(".history").appendingPathComponent(file.lastPathComponent)
        for directory in [history.deletingLastPathComponent(), history] {
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw failure("历史目录为符号链接，已停止写入。") }
        }
        return history
    }
    static func history(for version: CoMindFileVersion) throws -> [URL] {
        let directory = try historyDirectory(for: version)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey])
            .filter { $0.pathExtension == "md" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])).map { $0.isSymbolicLink != true && $0.isRegularFile == true } == true }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }
    static func historyText(_ file: URL, for version: CoMindFileVersion) throws -> String {
        let directory = try historyDirectory(for: version)
        guard file.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              try history(for: version).contains(where: { $0.standardizedFileURL.path == file.standardizedFileURL.path }) else { throw failure("只允许恢复当前原文件同域的历史版本。") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit, let text = String(data: data, encoding: .utf8) else { throw failure("历史版本过大或无法解码。") }
        return text
    }
    @discardableResult static func commit(_ change: CoMindFileChange) throws -> URL? {
        guard Data(change.after.utf8).count <= byteLimit else { throw failure("修改后的文件超过 1 MB，未保存。") }
        let file = try url(change.before.path, in: change.before.repository)
        guard file == change.before.file else { throw failure("原件位置已变化，请重新读取后保存。") }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?, operationError: Error?, backup: URL?, completed = false
        coordinator.coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { _ in
            do {
                // Revalidate after coordination. Never overwrite a file changed by another editor.
                let current = try read(change.before.path, in: change.before.repository)
                guard current.file == file, current.data == change.before.data else { throw failure("原文件已在外部更新。你的修改仍留在编辑框；请重新读取并核对后保存。") }
                if try KnowledgeSourceLocator.resolve(current.path, repo: current.repository) != nil {
                    backup = try writeNoteThroughBridge(change)
                    completed = true
                    return
                }
                if current.text == change.after { completed = true; return }
                let directory = try historyDirectory(for: current)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let revision = directory.appendingPathComponent(UUID().uuidString + ".md")
                try current.data.write(to: revision, options: .withoutOverwriting)
                try Data(change.after.utf8).write(to: file, options: .atomic)
                guard try read(current.path, in: current.repository).data == Data(change.after.utf8) else { throw failure("写后回读不一致，请核对原件与历史，未确认保存。") }
                backup = revision
                completed = true
            } catch { operationError = error }
        }
        if let error = coordinationError ?? operationError as NSError? { throw error }
        guard completed else { throw failure("文件协调未完成，未确认保存。") }
        return backup
    }

    /// UI edits and AI/CLI edits share one notes writer, lock, registry and history format.
    /// The caller runs this off the UI thread and retains macOS file coordination.
    private static func writeNoteThroughBridge(_ change: CoMindFileChange) throws -> URL? {
        let before = change.before
        let contentHash = SHA256.hash(data: Data(change.after.utf8)).map { String(format: "%02x", $0) }.joined()
        let output = try bridgeJSON(repository: before.repository, arguments: ["write", before.path,
            "--expected-sha256", before.sha256, "--expected-path", before.file.path,
            "--content-sha256", contentHash, "--stdin"], input: Data(change.after.utf8))
        struct Receipt: Decodable { let changed: Bool; let sha256: String; let history: String? }
        let receipt = try JSONDecoder().decode(Receipt.self, from: output)
        let after = try read(before.path, in: before.repository)
        guard after.file == before.file, after.text == change.after, after.sha256 == receipt.sha256 else { throw failure("写后原件已变化，未确认保存；请保留修改并重新核对。") }
        guard receipt.changed else { return nil }
        guard let path = receipt.history else { throw failure("桥接缺少历史回执，未确认保存。") }
        let backup = URL(fileURLWithPath: path)
        guard try historyText(backup, for: before) == before.text else { throw failure("历史回读不一致，请核对原件与历史。") }
        return backup
    }
    /// Bounded bridge execution shared by original edits and metadata-only organization receipts.
    static func bridgeJSON(repository: URL, arguments: [String], input data: Data? = nil) throws -> Data {
        let tool = try KnowledgeSourceLocator.safe("tools/scripts/knowledge-bridge/bridge.py", root: repository)
        guard FileManager.default.fileExists(atPath: tool.path) else { throw failure("原笔记桥接工具不可用。") }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", tool.path, "--repo", repository.path] + arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let group = DispatchGroup()
        final class Capture: @unchecked Sendable { var out = Data(); var error = Data() }
        let captured = Capture()
        group.enter(); DispatchQueue.global().async { captured.out = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { captured.error = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async {
            if let data { try? input.fileHandleForWriting.write(contentsOf: data) }
            try? input.fileHandleForWriting.close(); group.leave()
        }
        if exited.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 2) }
            _ = group.wait(timeout: .now() + 2)
            throw failure("桥接未收到回执，请核对原件与历史；不会自动重试。")
        }
        group.wait()
        guard process.terminationStatus == 0 else {
            let reason = String(data: captured.error, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? "桥接工具未完成"
            throw failure("操作未确认：\(reason)。请核对原文与历史。")
        }
        return captured.out
    }
    static func title(_ source: CoMindSource, connection: CoMindConnection?) -> String {
        if source.path == memory { return "协作约定" }
        if source.path == candidates { return "规则待审草稿" }
        guard let connection, let file = try? url(source.path, in: connection.repository) else { return source.path }
        return file.deletingPathExtension().lastPathComponent
    }
    /// Locate the existing bridge even when a new or resumed chat works outside the CoMind repo.
    /// This is guidance for an explicitly requested edit, not a filesystem permission grant.
    static func writebackInstructions(versions: [CoMindFileVersion], threadID: String?) throws -> String? {
        let notes = try versions.filter { try KnowledgeSourceLocator.resolve($0.path, repo: $0.repository) != nil }
        guard let repository = notes.first?.repository else { return nil }
        let tool = try KnowledgeSourceLocator.safe("tools/scripts/knowledge-bridge/bridge.py", root: repository)
        guard FileManager.default.fileExists(atPath: tool.path) else {
            return "原笔记写回入口暂不可用：可以按当前原文回答，但不能声称已经记住或保存。若用户要求保存，请先恢复 CoMind 桥接工具；不要另建记忆或直接绕过历史保护写文件。"
        }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let command = "python3 -B \(quote(tool.path)) --repo \(quote(repository.path))"
        let source = threadID.map { "来源会话：codex://threads/\($0)。" } ?? "当前未提供会话来源 ID，不得编造。"
        return """
        驾驶舱原笔记写回方式（工具说明，不是资料正文）：
        只有用户在本次需求中明确要求记住、保存或更正时才提出写回；仅勾选背景不等于同意修改。
        本轮仅可处理这些已有原件：\(notes.map(\.path).joined(separator: "、"))。不要搜索其他笔记，不修改日记、插件或独立员工记忆。
        读取命令：\(command) read '<上述来源引用>'。当前工作目录不必是 CoMind，必须使用这里的绝对工具地址。
        增量写回命令：\(command) patch '<同一来源引用>' --expected-sha256 '<本次读取的 SHA256>'
        通过命令标准输入的 JSON {"old":"唯一匹配的原文片段","new":"替换后的片段"} 提供修改；不要把笔记正文另存到临时文件。工具会核对版本、保存原件同目录历史并写后回读；禁止直接用 echo、脚本或 apply_patch 绕过它覆盖原件。
        保留其他正文和原始日期。新增长期信息需注明用户自述或用户确认、记录日期及来源；\(source) AI 推断、歧义与冲突不能提升为事实，只能作为待核对，明确更正与旧依据保持关联。
        遇到只读权限限制，使用已有的单次命令审批，让用户看到具体修改；不请求整个目录或持续写权限。只有工具返回成功回执后才能说已保存。版本变化或失败就停止并报告，不自动换新版本重试覆盖。重复内容不追加。
        """
    }
    static func selectedVersions(connection: CoMindConnection?, area: String, selected: Set<UUID>) throws -> [CoMindFileVersion] {
        guard !selected.isEmpty else { return [] }
        guard let connection else { throw failure("CoMind 连接已移除，请重新选择背景。") }
        let sources = connection.sources.filter { selected.contains($0.id) && $0.areas.contains(area) }
        guard Set(sources.map(\.id)) == selected else { throw failure("部分来源已解除关联，请重新核对背景选择。") }
        var bytes = 0, files = Set<URL>(), versions: [CoMindFileVersion] = []
        for source in sources {
            let file = try url(source.path, in: connection.repository).standardizedFileURL
            guard files.insert(file).inserted else { continue }
            let version = try read(source.path, in: connection.repository)
            guard version.file.standardizedFileURL == file else { throw failure("来源位置已变化，请重新准备消息。") }
            bytes += version.data.count
            guard bytes <= 60_000 else { throw failure("选中的 CoMind 原文超过 60 KB，请减少背景文件。") }
            versions.append(version)
        }
        return versions
    }
    static func context(_ versions: [CoMindFileVersion]) -> [String] {
        versions.map { version in
            let label = kind(version.path) == .candidates ? "候选与审核记录，不代表已确认事实" : "原文件背景资料"
            return "CoMind \(label) · \(version.file.lastPathComponent)\n来源：\(version.path)\n本次读取版本：SHA256 \(version.sha256)\n\(version.text)"
        }
    }
    static func context(connection: CoMindConnection?, area: String, selected: Set<UUID>) throws -> [String] {
        context(try selectedVersions(connection: connection, area: area, selected: selected))
    }
}

extension AppStore {
    func connectCoMind(_ repository: URL) throws {
        try CoMindFiles.validateRoot(repository)
        let resolved = repository.standardizedFileURL.resolvingSymlinksInPath()
        if let old = coMind, old.repository.standardizedFileURL.resolvingSymlinksInPath().path != resolved.path, !old.sources.isEmpty { throw CoMindFiles.failure("请先解除现有来源引用，再更换 CoMind 根目录。") }
        var connection = coMind ?? .init(repository: resolved)
        connection.repository = resolved
        try updateCoMind(connection)
    }
    func updateCoMind(_ connection: CoMindConnection) throws {
        guard canEdit else { throw CoMindFiles.failure("驾驶舱索引暂不可写。") }
        let old = coMind
        coMind = connection; persist()
        if let error = storageWarning { coMind = old; throw CoMindFiles.failure(error) }
    }
    func attachCoMindSource(path: String, area: String) throws {
        guard var connection = coMind else { throw CoMindFiles.failure("请先选择 CoMind 根目录。") }
        // Existence/type check without reading a private body merely to link it.
        let url = try CoMindFiles.url(path, in: connection.repository)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CoMindFiles.failure("请选择已有的 Markdown 文件。") }
        if let i = connection.sources.firstIndex(where: { (try? CoMindFiles.url($0.path, in: connection.repository)) == url }) { connection.sources[i].areas.insert(area) }
        else { connection.sources.append(.init(path: path, areas: [area])) }
        try updateCoMind(connection)
    }
    func detachCoMindSource(_ id: UUID, area: String) throws {
        guard var connection = coMind else { return }
        if let i = connection.sources.firstIndex(where: { $0.id == id }) { connection.sources[i].areas.remove(area) }
        connection.sources.removeAll { $0.areas.isEmpty }
        connection.chatSources?[area]?.remove(id)
        try updateCoMind(connection)
        if var policy = noteWritebackPolicies[area], policy.sources.contains(id) {
            policy.sources.removeAll { $0 == id }; policy.enabled = false; policy.revision = UUID().uuidString
            noteWritebackPolicies[area] = policy; persist()
            notify("已解除关联，自动整理已暂停；可重新选择默认笔记")
        }
    }
    func setCoMindChatSource(_ source: UUID, area: String, enabled: Bool) throws {
        guard var connection = coMind,
              connection.sources.contains(where: { $0.id == source && $0.areas.contains(area) }) else {
            throw CoMindFiles.failure("来源已解除关联，请重新选择。")
        }
        var selections = connection.chatSources ?? [:]
        if enabled { selections[area, default: []].insert(source) }
        else { selections[area]?.remove(source) }
        connection.chatSources = selections
        if enabled {
            var scopes = connection.originalsOnlyAreas ?? []
            scopes.insert(area); connection.originalsOnlyAreas = scopes
        }
        try updateCoMind(connection)
    }
    func coMindSources(for area: String) -> [CoMindSource] { coMind?.sources.filter { $0.areas.contains(area) } ?? [] }
    func openCoMindSource(_ source: CoMindSource, focusReview: Bool = false) {
        editingCoMindSource = source; focusCoMindSourceReview = focusReview; sheet = .coMindSource
    }
}
