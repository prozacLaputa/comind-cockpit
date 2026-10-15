import Foundation

/// Portable document identities live with the notes; only the root binding is machine-local.
/// No source body is cached, scanned, or sent merely by resolving an address.
enum KnowledgeSourceLocator {
    struct Binding: Decodable { let notes_root: String; let routes: [String: String]? }
    struct Entry: Decodable { let id: String; let path: String; let aliases: [String]? }
    struct Registry: Decodable { let version: Int; let documents: [Entry] }
    static func safe(_ path: String, root: URL, metadata: Bool = false) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && (metadata || !$0.hasPrefix(".")) }) else { throw CoMindFiles.failure("无效的来源地址。") }
        var file = root.standardizedFileURL
        guard file == file.resolvingSymlinksInPath() else { throw CoMindFiles.failure("来源根不能经过符号链接。") }
        for part in parts {
            file.appendPathComponent(String(part))
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CoMindFiles.failure("来源路径包含符号链接。") }
        }
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.standardizedFileURL.path + "/") else { throw CoMindFiles.failure("来源地址越界。") }
        return file
    }
    static func binding(_ repo: URL) throws -> Binding? {
        let file = try safe(".local/knowledge-sources.json", root: repo, metadata: true)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Binding.self, from: Data(contentsOf: file))
    }
    static func notesRoot(_ repo: URL) throws -> URL? {
        guard let config = try binding(repo) else { return nil }
        let root = URL(fileURLWithPath: config.notes_root).standardizedFileURL
        guard root.path.hasPrefix("/"), root == root.resolvingSymlinksInPath(), (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw CoMindFiles.failure("笔记来源暂不可用，请等待 iCloud 下载或重新绑定；不会创建替代知识库。") }
        return root
    }
    static func entries(_ root: URL) throws -> [Entry] {
        let file = try safe(".comind/registry.json", root: root, metadata: true)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 5_000_000 else { throw CoMindFiles.failure("来源登记文件无效。") }
        let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: file))
        guard registry.version == 1 else { throw CoMindFiles.failure("来源登记版本不支持。") }
        return registry.documents
    }
    static func resolve(_ reference: String, repo: URL) throws -> URL? {
        guard let config = try binding(repo) else {
            if reference.hasPrefix("note:") || reference.hasPrefix("notes/") { throw CoMindFiles.failure("尚未绑定笔记来源。") }
            return nil
        }
        // System context remains usable even when the external notes root is offline.
        guard reference.hasPrefix("note:") || reference.hasPrefix("notes/") || reference.hasPrefix("corpus/") else { return nil }
        guard let root = try notesRoot(repo) else { return nil }
        let matches = try entries(root).filter { "note:" + $0.id == reference || "notes/" + $0.path == reference || ($0.aliases ?? []).contains(reference) }
        guard matches.count <= 1 else { throw CoMindFiles.failure("来源身份重复，请重新定位。") }
        if let entry = matches.first {
            let file = try safe(entry.path, root: root)
            guard FileManager.default.fileExists(atPath: file.path) else { throw CoMindFiles.failure("原件已移动或尚未下载，请通过知识桥接重新定位；原引用保留。") }
            return file
        }
        if reference.hasPrefix("note:") { throw CoMindFiles.failure("文档标识不存在，请重新定位。") }
        if reference.hasPrefix("notes/") { return try safe(String(reference.dropFirst(6)), root: root) }
        for (old, new) in config.routes ?? [:] where reference.hasPrefix(old) { return try safe(new + String(reference.dropFirst(old.count)), root: root) }
        return nil
    }
    static func reference(_ file: URL, repo: URL) throws -> String? {
        guard let root = try notesRoot(repo), file.standardizedFileURL.path.hasPrefix(root.path + "/") else { return nil }
        let relative = String(file.standardizedFileURL.path.dropFirst(root.path.count + 1))
        _ = try safe(relative, root: root)
        let matches = try entries(root).filter { $0.path == relative }
        guard matches.count <= 1 else { throw CoMindFiles.failure("来源身份重复。") }
        return matches.first.map { "note:" + $0.id } ?? "notes/" + relative
    }
}
