import Foundation

struct PendingChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var key: String
    var area: String?
    var threadID: String?
    var text: String
    var skills: [CodexSkill]
    var model: CodexModelSelection?
    var options: ConversationBackgroundOptions
    var attachments: [ChatAttachment]
    var state = "waiting"
    var detail = "当前回复完成后发送"
}

extension AppStore {
    var pendingDispatchBlocked: Bool { !codex.connected || codex.sending || codex.reading || codex.refreshingHistory || codex.needsRecovery || codex.runningThreadID != nil || pendingDispatching }
    @discardableResult func enqueueMessage(key: String, area: String?, thread: CodexThread?, options: ConversationBackgroundOptions) -> Bool {
        guard composerWritable, !pendingMessages.contains(where: { $0.key == key }) else { notify("请先处理这条待发送消息"); return false }
        let text = conversationDrafts[key] ?? "", images = conversationAttachments[key] ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return false }
        let item = PendingChatMessage(key: key, area: area, threadID: thread?.id, text: text, skills: conversationSkills[key] ?? [], model: conversationModels[key], options: options, attachments: images)
        pendingMessages.append(item)
        conversationDrafts[key] = ""; conversationAttachments[key] = []
        conversationSkills[key] = []; conversationModels[key] = nil
        guard saveComposerState() else {
            pendingMessages.removeAll { $0.id == item.id }; conversationDrafts[key] = text; conversationAttachments[key] = images
            conversationSkills[key] = item.skills; conversationModels[key] = item.model
            return false
        }
        if !pendingDispatchBlocked { Task { await dispatchPendingMessage() } }
        return true
    }
    func cancelPendingMessage(_ id: UUID) {
        guard let index = pendingMessages.firstIndex(where: { $0.id == id && $0.state != "sending" }) else { return }
        let previous = pendingMessages
        pendingMessages.remove(at: index); retireUnreferencedImages()
        if !saveComposerState() { pendingMessages = previous; retireUnreferencedImages() }
    }
    func editPendingMessage(_ id: UUID, targetKey: String? = nil) -> PendingChatMessage? {
        guard let item = pendingMessages.first(where: { $0.id == id && $0.state != "sending" && $0.state != "uncertain" }) else { return nil }
        let destination = targetKey ?? item.key
        guard (conversationDrafts[destination] ?? "").isEmpty, (conversationAttachments[destination] ?? []).isEmpty else { notify("输入框里还有草稿，请先处理后再编辑待发送消息"); return nil }
        conversationDrafts[destination] = item.text; conversationAttachments[destination] = item.attachments
        conversationSkills[destination] = item.skills; conversationModels[destination] = item.model
        draftOwners[destination] = item.area ?? ""
        pendingMessages.removeAll { $0.id == id }; saveComposerState()
        return item
    }
    func resumePendingMessage(_ id: UUID) {
        guard let index = pendingMessages.firstIndex(where: { $0.id == id && $0.state == "paused" }), !codex.needsRecovery else { return }
        pendingMessages[index].state = "waiting"; pendingMessages[index].detail = "等待发送"
        guard saveComposerState() else { pendingMessages[index].state = "paused"; return }
        Task { await dispatchPendingMessage() }
    }
    func pendingTurnFinished(status: String) {
        if status != "completed" {
            for index in pendingMessages.indices where pendingMessages[index].state == "waiting" {
                pendingMessages[index].state = "paused"; pendingMessages[index].detail = "上一轮已停止或失败，确认后再发送"
            }
            saveComposerState(); return
        }
        Task { await Task.yield(); await dispatchPendingMessage() }
    }
    func pendingContext(_ item: PendingChatMessage, destination: String?) async throws -> String {
        guard pendingMessages.contains(where: { $0.id == item.id && $0.state == "sending" }) else { throw BridgeError(message: "待发送消息已取消") }
        if let area = item.area {
            guard areas.contains(where: { $0.id == area }) else { throw BridgeError(message: "原阵地已移除，待发送内容已保留") }
            if let destination, !threadLinks.contains(where: { $0.areaID == area && $0.threadID == destination }) { throw BridgeError(message: "会话关联已变化，请核对后再发送") }
        }
        _ = try ChatAttachments.validate(item.attachments, root: attachmentRoot)
        var recent: String?
        if let destination, codex.selected?.id != destination {
            let (_, history, _) = try await codex.searchHistoryPage(thread: destination, cursor: nil)
            recent = history.filter { $0.role == "你" }.suffix(2).map { String(ConversationContext.visibleUserText($0.text).suffix(1200)) }.joined(separator: "\n")
        }
        let message = try await prepareConversationMessage(request: item.text, areaID: item.area, options: item.options,
            sourceThreadID: destination, recentUserText: recent, referenceText: { try await self.codex.referenceText($0) })
        _ = try ChatAttachments.validate(item.attachments, root: attachmentRoot)
        return message
    }
    func dispatchPendingMessage() async {
        guard !pendingDispatchBlocked, let next = pendingMessages.first(where: { $0.state == "waiting" }) else { return }
        pendingDispatching = true
        defer {
            pendingDispatching = false
            if !pendingDispatchBlocked, pendingMessages.contains(where: { $0.state == "waiting" }) {
                Task { await Task.yield(); await dispatchPendingMessage() }
            }
        }
        guard let index = pendingMessages.firstIndex(where: { $0.id == next.id }) else { return }
        pendingMessages[index].state = "sending"; pendingMessages[index].detail = "正在核对背景并发送…"
        guard saveComposerState() else { pendingMessages[index].state = "paused"; return }
        var item = pendingMessages[index]
        do {
            _ = try await pendingContext(item, destination: item.threadID)
            let destination: CodexThread
            if let id = item.threadID {
                await codex.resolveLinks([id], refresh: true)
                guard let thread = codex.threadMap[id] else { throw BridgeError(message: "原会话暂不可用，消息已保留") }
                destination = thread
            } else {
                guard let area = item.area,
                      let thread = await codex.newThread(cwd: workDirectory(for: area), select: areaID == area && areaTab == "开始工作") else { throw BridgeError(message: codex.error ?? "无法创建会话") }
                destination = thread; linkThread(thread.id, areaID: area); lastAreaThread[area] = thread.id
                item.threadID = thread.id
                if let index = pendingMessages.firstIndex(where: { $0.id == item.id }) { pendingMessages[index].threadID = thread.id }
                guard saveComposerState() else { throw BridgeError(message: composerWarning ?? "消息未保存") }
            }
            let paths = try ChatAttachments.validate(item.attachments, root: attachmentRoot)
            let message = try await pendingContext(item, destination: destination.id)
            try protectSubmittedImages(item.attachments)
            let accepted = await codex.send(message, to: destination, skills: item.skills, modelSelection: item.model,
                draftText: item.text, draftKeys: ["pending:" + item.id.uuidString], attachments: paths,
                refreshText: { try await self.pendingContext(item, destination: destination.id) })
            guard accepted else { throw BridgeError(message: codex.error ?? "消息未发送，内容已保留") }
            // Successful sends retain image assets for history previews. Only queued references are removed.
            pendingMessages.removeAll { $0.id == item.id }; saveComposerState()
        } catch {
            if let index = pendingMessages.firstIndex(where: { $0.id == item.id }) {
                pendingMessages[index].state = codex.needsRecovery ? "uncertain" : "paused"
                pendingMessages[index].detail = error.localizedDescription
                for other in pendingMessages.indices where pendingMessages[other].state == "waiting" {
                    pendingMessages[other].state = "paused"; pendingMessages[other].detail = "前一条发送失败，确认后继续"
                }
                saveComposerState()
            }
        }
    }
}
