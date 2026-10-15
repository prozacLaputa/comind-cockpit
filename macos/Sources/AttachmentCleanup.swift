import Foundation
import SwiftUI

struct AttachmentLifecycle: Codable {
    var item: ChatAttachment
    var created = Date()
    var removed: Date?
    var submitted = false
}
extension AppStore {
    var liveAttachmentIDs: Set<UUID> {
        Set(conversationAttachments.values.flatMap { $0 }.map(\.id) + pendingMessages.flatMap(\.attachments).map(\.id))
    }
    func retireUnreferencedImages(now: Date = Date()) {
        let live = liveAttachmentIDs
        for key in attachmentLifecycle.keys {
            guard let value = attachmentLifecycle[key], !value.submitted else { continue }
            if live.contains(value.item.id) { attachmentLifecycle[key]?.removed = nil }
            else if value.removed == nil { attachmentLifecycle[key]?.removed = now }
        }
    }
    func protectSubmittedImages(_ items: [ChatAttachment]) throws {
        for item in items {
            // Old/untracked files are deliberately not eligible for automatic cleanup.
            if attachmentLifecycle[item.id.uuidString] != nil { attachmentLifecycle[item.id.uuidString]?.submitted = true }
        }
        guard saveComposerState() else { throw CoMindFiles.failure(composerWarning ?? "附件发送状态未保存，尚未发送") }
    }
    @discardableResult func cleanUnusedImages(now: Date = Date()) throws -> Int {
        guard composerWritable, !pendingDispatching else { throw CoMindFiles.failure("请先完成草稿保存或当前发送") }
        guard attachmentRoot.resolvingSymlinksInPath() == attachmentRoot.standardizedFileURL else { throw CoMindFiles.failure("附件目录已变化，停止清理") }
        retireUnreferencedImages(now: now)
        guard saveComposerState(), let expected = composerData else { throw CoMindFiles.failure(composerWarning ?? "草稿未保存") }
        var protected = liveAttachmentIDs
        for copy in recoveryCopies() {
            let saved = try JSONDecoder().decode(ComposerState.self, from: Data(contentsOf: copy.url.appendingPathComponent("composer-state.json")))
            protected.formUnion((saved.attachments ?? [:]).values.flatMap { $0 }.map(\.id))
            protected.formUnion((saved.pending ?? []).flatMap(\.attachments).map(\.id))
        }
        let candidates = attachmentLifecycle.values.filter { value in
            !value.submitted && !protected.contains(value.item.id) && value.removed.map { now.timeIntervalSince($0) >= 7 * 86400 } == true
        }
        var bytes = 0
        try CockpitStorage.coordinate(composerURL) { file in
            guard try Data(contentsOf: file) == expected else { throw CoMindFiles.failure("草稿已被其他设备更新，已停止图片清理") }
            for value in candidates {
                let item = value.item, file = item.url(in: attachmentRoot)
                guard FileManager.default.fileExists(atPath: file.path) else { attachmentLifecycle[item.id.uuidString] = nil; continue }
                _ = try ChatAttachments.validate([item], root: attachmentRoot)
                try FileManager.default.removeItem(at: file)
                bytes += item.byteCount; attachmentLifecycle[item.id.uuidString] = nil
            }
        }
        guard saveComposerState() else { throw CoMindFiles.failure("无引用图片已清理，但清理记录未保存，请重试保存") }
        return bytes
    }
    func restoreRemovedImage(_ value: AttachmentLifecycle, to key: String) throws {
        guard !value.submitted, value.removed != nil, !liveAttachmentIDs.contains(value.item.id) else { throw CoMindFiles.failure("这张图片已被使用") }
        let previous = conversationAttachments[key] ?? []
        _ = try ChatAttachments.validate(previous + [value.item], root: attachmentRoot)
        conversationAttachments[key] = previous + [value.item]
        attachmentLifecycle[value.item.id.uuidString]?.removed = nil
        guard saveComposerState() else { conversationAttachments[key] = previous; attachmentLifecycle[value.item.id.uuidString] = value; throw CoMindFiles.failure("恢复图片未保存") }
    }
}
struct AttachmentCleanupSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未发送图片").font(CockpitTypography.section)
            Caption(text: "移除后保留 7 天。仅清理本版登记、从未发送且无草稿或恢复副本引用的图片；历史附件与来源图片保持。")
            Button("清理到期副本") {
                do { let bytes = try store.cleanUnusedImages(); issue = nil; store.notify(bytes == 0 ? "没有到期的无引用图片" : "已清理 " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
                catch { issue = error.localizedDescription }
            }.buttonStyle(QuietButton())
            ForEach(store.attachmentLifecycle.values.filter { !$0.submitted && $0.removed != nil && !store.liveAttachmentIDs.contains($0.item.id) }.sorted { $0.created > $1.created }, id: \.item.id) { value in
                HStack {
                    Text(value.item.name).font(CockpitTypography.caption).lineLimit(1)
                    Spacer()
                    Button("找回到当前草稿") {
                        let key = store.codex.selected?.id ?? "new:" + (store.contextArea.isEmpty ? "global" : store.contextArea)
                        do { try store.restoreRemovedImage(value, to: key); issue = nil; store.notify("图片已找回输入框") } catch { issue = error.localizedDescription }
                    }.buttonStyle(QuietButton()).disabled(store.contextArea.isEmpty && store.codex.selected == nil)
                }
            }
            if let issue { Caption(text: issue) }
        }
    }
}
