import Foundation
import AppKit

@main struct ChatContinuitySmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-daily-flow-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fake_daily_codex.py")
        let bridge = CodexBridge(executableOverride: fake)
        await bridge.connect(); defer { bridge.disconnect() }
        func control(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            var params = args; params["fixtureControl"] = name
            return try await bridge.call("config/read", params)
        }
        let store = AppStore(storageURL: root.appendingPathComponent("state.json"), codexBridge: bridge)
        store.areas = [.init(id: "a", name: "合成 A", purpose: ""), .init(id: "b", name: "合成 B", purpose: "")]
        store.employeeProfiles["a"] = .init(autoReview: false); store.employeeProfiles["b"] = .init(autoReview: false)
        store.threadLinks = [.init(areaID: "a", threadID: "daily-a"), .init(areaID: "b", threadID: "daily-b")]
        await bridge.resolveLinks(["daily-a", "daily-b"], refresh: true)
        await bridge.read(bridge.threadMap["daily-a"]!)
        store.observeThreadActivity(); store.markThreadViewed("daily-a", area: "a")
        _ = try await control("external", [:])
        await bridge.resolveLinks(["daily-a"], refresh: true)
        store.markThreadViewed("daily-a", area: "a")
        precondition(store.areaNotice("a") == .unread && !bridge.messages.contains { $0.text == "新回复 3" })
        await bridge.refreshVisibleHistory()
        precondition(bridge.messages.contains { $0.text == "新回复 3" })
        store.markThreadViewed("daily-a", area: "a"); precondition(store.areaNotice("a") == .none)
        _ = try await control("external", [:]); await bridge.resolveLinks(["daily-a"], refresh: true)
        _ = try await control("fail-read", ["enabled": true])
        let previous = bridge.messages.map(\.id)
        await bridge.refreshVisibleHistory(); store.markThreadViewed("daily-a", area: "a")
        precondition(store.areaNotice("a") == .unread && bridge.messages.map(\.id) == previous)
        _ = try await control("fail-read", ["enabled": false]); await bridge.refreshVisibleHistory()
        store.markThreadViewed("daily-a", area: "a"); precondition(store.areaNotice("a") == .none)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try store.addImages([(png, "合成截图.png")], key: "daily-b", area: "b")
        let picture = store.conversationAttachments["daily-b"]![0]
        let validated = try ChatAttachments.validate([picture], root: root)
        precondition(validated.count == 1)
        store.persist()
        precondition(AppStore(storageURL: store.storageURL).conversationAttachments["daily-b"] == [picture])
        let started = await bridge.send("正在执行", to: bridge.threadMap["daily-a"]!)
        precondition(started)
        store.conversationDrafts["daily-b"] = "稍后发送截图"
        precondition(store.enqueueMessage(key: "daily-b", area: "b", thread: bridge.threadMap["daily-b"], options: .init()))
        precondition(store.pendingMessages.count == 1 && store.pendingMessages[0].state == "waiting")
        let reopened = AppStore(storageURL: store.storageURL)
        precondition(reopened.pendingMessages.count == 1 && reopened.pendingMessages[0].state == "paused", "Restart never auto-sends")
        let queuedID = store.pendingMessages[0].id
        precondition(store.editPendingMessage(queuedID)?.text == "稍后发送截图")
        precondition(store.conversationAttachments["daily-b"] == [picture] && store.pendingMessages.isEmpty)
        store.conversationDrafts["daily-b"] = "修改后的截图需求"
        precondition(store.enqueueMessage(key: "daily-b", area: "b", thread: bridge.threadMap["daily-b"], options: .init()))
        _ = try await control("complete", [:])
        for _ in 0..<100 where bridge.runningThreadID != "daily-b" || !store.pendingMessages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        precondition(bridge.runningThreadID == "daily-b" && store.pendingMessages.isEmpty)
        precondition(bridge.selected?.id == "daily-a", "Background queue must not switch the visible conversation")
        let logs = try await control("logs", [:])["sent"] as! [[String: Any]]
        precondition(logs.count == 2)
        let inputs = logs[1]["input"] as! [[String: Any]]
        precondition((inputs[0]["text"] as? String)?.contains("修改后的截图需求") == true && inputs.contains { $0["type"] as? String == "localImage" })
        store.conversationDrafts["daily-a"] = "可撤销"
        precondition(store.enqueueMessage(key: "daily-a", area: "a", thread: bridge.threadMap["daily-a"], options: .init()))
        store.cancelPendingMessage(store.pendingMessages[0].id); precondition(store.pendingMessages.isEmpty)
        _ = try await control("complete", [:])
        for _ in 0..<100 where bridge.runningThreadID != nil || bridge.refreshingHistory { try await Task.sleep(for: .milliseconds(20)) }
        store.conversationDrafts["daily-b"] = "REJECT"
        precondition(store.enqueueMessage(key: "daily-b", area: "b", thread: bridge.threadMap["daily-b"], options: .init()))
        for _ in 0..<100 where store.pendingMessages.first?.state != "paused" { try await Task.sleep(for: .milliseconds(20)) }
        precondition(store.pendingMessages.first?.state == "paused")
        let calls = try await control("logs", [:])["sent"] as! [[String: Any]]
        try await Task.sleep(for: .milliseconds(400))
        let still = try await control("logs", [:])["sent"] as! [[String: Any]]
        precondition(calls.count == still.count && calls.count == 3, "No retry after rejection")
        try Data("tampered".utf8).write(to: picture.url(in: root))
        do { _ = try ChatAttachments.validate([picture], root: root); fatalError("Changed attachment must block") } catch {}
        print("PASS: external updates before read acknowledgement, failed refresh preserves transcript/unread, persistent editable queue, restart pause, cancellation, single dispatch/no retry, image protocol and integrity")
    }
}
