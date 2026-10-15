import Foundation

@main struct ContextEfficiencySmoke {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("context-efficiency-\(UUID())").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        func put(_ path: String, _ text: String) throws {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        func check(_ condition: Bool, _ message: String, line: UInt = #line) { precondition(condition, "\(line): \(message)") }
        try put("corpus/README.md", "synthetic"); try put("protocols/agent-contract.md", "synthetic"); try put("protocols/write-policy.md", "synthetic")
        try put(".local/knowledge-sources.json", "{\"notes_root\":\"\(root.appendingPathComponent("notes").path)\"}")
        try put("notes/.comind/registry.json", "{\"version\":1,\"documents\":[]}")
        let repo = (0..<3).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let tool = "tools/scripts/knowledge-bridge/bridge.py"
        try put(tool, String(contentsOf: repo.appendingPathComponent(tool), encoding: .utf8))
        let filler = (1...28).map { "## 配件档案 \($0)\n\n2025-01-01 · 外部摘录\n\n" + String(repeating: "archival specimen \($0) with specification details. ", count: 22) }.joined(separator: "\n\n")
        let note = "# 合成设备日志\n\n合成验收资料，不是真实用户记录。\n\n" + filler + "\n\n## 荧光模块\n\n2026-10-01 · 用户自述\n\n荧光模块当前电池：型号甲。\n\n## 更正与边界\n\n2026-10-15 用户确认：不要在工位播放声音。\n\n## 待核对\n\n功耗测试存在冲突，尚未确认，不据此推荐购买。\n"
        try put("notes/设备.md", note)
        let fake = URL(fileURLWithPath: CommandLine.arguments[1])
        let bridge = CodexBridge(executableOverride: fake)
        let store = AppStore(storageURL: root.appendingPathComponent("chat.json"), codexBridge: bridge)
        store.areas = [.init(id: "a", name: "合成设备", purpose: "")]
        try store.connectCoMind(root); try store.attachCoMindSource(path: "notes/设备.md", area: "a")
        let source = store.coMindSources(for: "a")[0]
        try store.setCoMindChatSource(source.id, area: "a", enabled: true)
        func message(_ request: String, full: Bool = false, thread: String? = nil) async throws -> String {
            var options = ConversationBackgroundOptions(); options.fullOriginals = full
            return try await store.prepareConversationMessage(request: request, areaID: "a", options: options, sourceThreadID: thread, referenceText: { _ in "" })
        }
        let compact = try await message("荧光模块用什么电池？")
        let full = try await message("荧光模块用什么电池？", full: true)
        check(compact.contains("型号甲") && compact.contains("2026-10-01 · 用户自述"), "matched passage retains date/speaker")
        check(compact.contains("不要在工位播放声音") && compact.contains("尚未确认"), "unmatched boundaries and conflicts retained")
        check(compact.contains("配件档案 28") && !compact.contains("archival specimen 28"), "outline preserves omitted coverage without shipping its body")
        check(compact.contains("先用下面的只读命令补读") && compact.contains("SHA256") && compact.contains("未附片段不能用旧版本补齐"), "missing coverage requires fresh original read")
        check(compact.utf8.count < full.utf8.count * 65 / 100, "synthetic large source should shrink materially")
        check(full.contains("archival specimen 28") && !full.contains("原笔记按需片段"), "organization mode keeps full originals")
        let version = try CoMindFiles.read(source.path, in: root)
        let updated = note.replacingOccurrences(of: "型号甲", with: "型号乙")
        try put("notes/设备.md", updated)
        let fresh = try await message("荧光模块用什么电池？")
        check(fresh.contains("型号乙") && !fresh.contains("型号甲") && !fresh.contains(version.sha256), "external edit takes effect on next send")
        // Exercise the advertised supplement command, without a model and against synthetic files only.
        let read = try CoMindFiles.bridgeJSON(repository: root, arguments: ["read", source.path])
        let payload = try JSONSerialization.jsonObject(with: read) as! [String: Any]
        let latest = try CoMindFiles.read(source.path, in: root)
        check(payload["text"] as? String == updated && payload["sha256"] as? String == latest.sha256, "supplement command returns current complete original/version")
        await bridge.connect()
        let thread = await bridge.newThread(cwd: root)!
        bridge.selected = thread
        bridge.messages = [.init(id: "synthetic", role: "你", text: "本次需求：\n荧光模块用什么电池？")]
        let followup = try await message("那这个呢？", thread: thread.id)
        check(followup.contains("型号乙"), "short follow-up uses only this thread's actual user text")
        let unrelated = try await message("那这个呢？", thread: "different-thread")
        check(!unrelated.contains("型号乙"), "other selected thread cannot leak retrieval terms")
        check(!unrelated.contains("archival specimen 28") && unrelated.contains("没有命中时也必须先补读"), "unmatched question exposes coverage and supplement rule")
        try store.setCoMindChatSource(source.id, area: "a", enabled: false)
        let deselected = try await message("荧光模块")
        check(!deselected.contains("型号乙") && !deselected.contains(source.path), "revoked source is absent even in same session")
        try store.setCoMindChatSource(source.id, area: "a", enabled: true)
        try fm.removeItem(at: root.appendingPathComponent("notes/设备.md"))
        do { _ = try await message("继续"); preconditionFailure("missing original reused") } catch { }
        bridge.disconnect()
        print("PASS context: synthetic full=\(full.utf8.count) bytes, selected=\(compact.utf8.count) bytes; latest reads, boundaries, follow-up scope, coverage, supplement command, no cache, full organization")

        let policy = ProgressReviewPolicy()
        let zero = Date(timeIntervalSince1970: 1000)
        check(policy.due(.init(changedAt: zero, lastAttempt: nil), previous: nil) == zero.addingTimeInterval(600), "production idle gate")
        check(policy.due(.init(changedAt: zero.addingTimeInterval(50), lastAttempt: zero), previous: nil) == zero.addingTimeInterval(1800), "production cooldown")
        check(policy.due(.init(changedAt: nil, lastAttempt: zero), previous: nil) == nil, "no pending delta means no timer")
        let scheduled = AppStore(storageURL: root.appendingPathComponent("progress.json"))
        scheduled.createArea(name: "合成进展", purpose: "", symbol: "cpu")
        let id = scheduled.areas[0].id
        scheduled.capture("合成设备已接通。", area: id)
        scheduled.progressPolicy = .init(quietPeriod: 0.15, minimumInterval: 0.7)
        var attempts = 0
        scheduled.makeProgressEngine = { attempts += 1; return ProgressEngine(bridge: CodexBridge(executableOverride: fake)) }
        for _ in 0..<4 { scheduled.requestReview(id, automatically: true); try await Task.sleep(for: .milliseconds(30)) }
        check(attempts == 0, "burst waits for quiet period")
        // Allow slow local IPC under build load; production scheduling intervals are asserted above.
        for _ in 0..<750 where scheduled.progressReports[id] == nil { try await Task.sleep(for: .milliseconds(20)) }
        check(attempts == 1 && scheduled.progressReports[id] != nil, "four changes coalesce into one review; attempts=\(attempts), error=\(scheduled.reviewErrors[id] ?? scheduled.storageWarning ?? "none"), scheduled=\(String(describing: scheduled.progressSchedules[id]))")
        scheduled.requestReview(id, automatically: true)
        try await Task.sleep(for: .milliseconds(200))
        check(attempts == 1 && scheduled.progressSchedules[id]?.changedAt != nil, "new change waits for cooldown")
        scheduled.requestReview(id)
        for _ in 0..<750 where scheduled.reviewTasks[id] != nil { try await Task.sleep(for: .milliseconds(20)) }
        check(attempts == 2 && scheduled.progressSchedules[id]?.changedAt == nil, "explicit check bypasses timer and consumes merged delta")
        let attemptDate = scheduled.progressSchedules[id]!.lastAttempt!
        scheduled.progressPolicy = .init(quietPeriod: 600, minimumInterval: 1800)
        scheduled.requestReview(id, automatically: true)
        scheduled.reviewTasks[id]?.cancel(); scheduled.reviewTasks.removeAll()
        let restarted = AppStore(storageURL: scheduled.storageURL)
        check(restarted.progressSchedules[id]?.changedAt != nil && restarted.progressSchedules[id]?.lastAttempt == attemptDate, "pending and cooldown survive restart")
        check(restarted.reviewTasks[id] != nil, "pending task resumes on launch")
        restarted.reviewTasks[id]?.cancel()
        // A failed/stale attempt is not retried on its own.
        scheduled.progressSchedules[id]?.changedAt = nil
        scheduled.makeProgressEngine = { attempts += 1; scheduled.areas[0].purpose += "changed"; return ProgressEngine(bridge: CodexBridge(executableOverride: fake)) }
        scheduled.capture("合成新增资料。", area: id)
        scheduled.requestReview(id)
        for _ in 0..<750 where scheduled.reviewTasks[id] != nil { try await Task.sleep(for: .milliseconds(20)) }
        let failedAttempts = attempts
        try await Task.sleep(for: .milliseconds(200))
        check(scheduled.reviewErrors[id] != nil && attempts == failedAttempts && scheduled.reviewTasks.isEmpty, "failure stops without retry")
        print("PASS progress: production timing, merged burst, cooldown, explicit refresh, persisted pending, restart, no failure retry")
    }
}
