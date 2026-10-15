import Foundation

enum CockpitStorage {
    static var legacy: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoMindCockpit/state-v1.json")
    }
    static var cloudRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }
    static func target(in root: URL) -> URL {
        root.appendingPathComponent("CoMind 驾驶舱/state.json")
    }
    static func validate(_ data: Data) throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard [1, 2, 3, 4, 5, 6].contains(snapshot.version) else { throw CocoaError(.coderReadCorrupt) }
    }
    /// Copy-once migration: the old local file is the untouched migration backup.
    /// An existing iCloud file always wins. Never replace it with an old local snapshot.
    static func prepare(root: URL, legacy: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            throw BridgeError(message: "未找到 iCloud Drive，请先在系统设置中启用；原本地数据仍保留。")
        }
        let destination = target(in: root)
        let placeholder = destination.deletingLastPathComponent().appendingPathComponent(".state.json.icloud")
        if fm.fileExists(atPath: placeholder.path) && !fm.fileExists(atPath: destination.path) {
            try? fm.startDownloadingUbiquitousItem(at: destination)
            throw BridgeError(message: "正在等待 iCloud 数据下载，请在 Finder 中保留下载后重新打开驾驶舱。")
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinate(destination) { url in
            if fm.fileExists(atPath: url.path) {
                try validate(Data(contentsOf: url))
                return
            }
            let data: Data
            if fm.fileExists(atPath: legacy.path) {
                data = try Data(contentsOf: legacy); try validate(data)
            } else {
                data = try JSONEncoder().encode(Snapshot(areas: [], threadLinks: [], documents: [], projects: [], captures: [], completed: []))
            }
            try data.write(to: url, options: .atomic)
        }
        return destination
    }
    static func coordinate(_ url: URL, action: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var actionError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do { try action(coordinated) } catch { actionError = error }
        }
        if let coordinationError { throw coordinationError }
        if let actionError { throw actionError }
    }
    /// Refuse to overwrite an externally changed snapshot; never merge unrelated machines blindly.
    static func save(_ data: Data, to url: URL, expected: Data?) throws {
        try coordinate(url) { coordinated in
            if NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated)?.isEmpty == false {
                throw BridgeError(message: "iCloud 文件存在冲突，已停止覆盖。请先在 Finder 中处理冲突。")
            }
            let current = FileManager.default.fileExists(atPath: coordinated.path) ? try Data(contentsOf: coordinated) : nil
            guard current == expected else {
                throw BridgeError(message: "数据已被其他设备或程序更新，已停止覆盖。请先保留当前修改，再从「设置 → 恢复」读取最新数据。")
            }
            try data.write(to: coordinated, options: .atomic)
        }
    }
}
