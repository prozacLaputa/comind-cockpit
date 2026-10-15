import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OriginalRelocationPlan {
    let source: CoMindSource
    let repository: URL
    let identity: String
    let previousPath: String
    let relativePath: String
    let target: URL
    let registryHash: String
    let targetHash: String
}
enum OriginalRelocation {
    static func prepare(source: CoMindSource, repository: URL, target: URL) throws -> OriginalRelocationPlan {
        guard let root = try KnowledgeSourceLocator.notesRoot(repository), target.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw CoMindFiles.failure("只能选择已绑定笔记库中的原文件") }
        let relative = String(target.standardizedFileURL.path.dropFirst(root.path.count + 1))
        let checked = try KnowledgeSourceLocator.safe(relative, root: root)
        guard checked.pathExtension == "md", !checked.pathComponents.contains(where: { $0.contains("日记") || $0.contains("模板") || $0.contains("梦境") }) else { throw CoMindFiles.failure("请选择原来的主题笔记，日记、梦境和模板不参与重新定位") }
        let registryFile = try KnowledgeSourceLocator.safe(".comind/registry.json", root: root, metadata: true)
        let data = try Data(contentsOf: registryFile)
        let entries = try JSONDecoder().decode(KnowledgeSourceLocator.Registry.self, from: data).documents
        let matches = entries.filter { "note:" + $0.id == source.path || "notes/" + $0.path == source.path || ($0.aliases ?? []).contains(source.path) }
        guard matches.count == 1, let old = matches.first else { throw CoMindFiles.failure("来源尚未登记稳定身份，请先通过知识桥接登记；不会猜测替换") }
        guard !entries.contains(where: { $0.id != old.id && $0.path == relative }) else { throw CoMindFiles.failure("所选文件已有另一份资料身份，不能合并") }
        let attributes = try checked.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= CoMindFiles.byteLimit else { throw CoMindFiles.failure("请选择小于 1 MB 的 Markdown 原件") }
        let content = try Data(contentsOf: checked)
        guard String(data: content, encoding: .utf8) != nil else { throw CoMindFiles.failure("原件不是 UTF-8 文本") }
        return .init(source: source, repository: repository, identity: old.id, previousPath: old.path, relativePath: relative, target: checked,
                     registryHash: ChatAttachments.hash(data), targetHash: ChatAttachments.hash(content))
    }
    static func apply(_ plan: OriginalRelocationPlan) throws {
        _ = try CoMindFiles.bridgeJSON(repository: plan.repository, arguments: ["rebind", plan.identity, plan.relativePath,
            "--expected-registry-sha256", plan.registryHash, "--expected-target-sha256", plan.targetHash, "--expected-old-path", plan.previousPath])
        guard try CoMindFiles.url(plan.source.path, in: plan.repository) == plan.target else { throw CoMindFiles.failure("位置回读不一致，请查看登记历史，未确认修复") }
    }
}
struct RelocateOriginalButton: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    let source: CoMindSource
    var onComplete: () -> Void = {}
    @State private var plan: OriginalRelocationPlan?
    @State private var issue: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("重新定位原件…") { choose() }.buttonStyle(QuietButton()).disabled(busy)
            if let plan {
                Caption(text: "原位置：\(plan.previousPath)\n所选位置：\(plan.relativePath)\n请确认这是同一份笔记。已有聊天授权和默认写回关系保留，登记旧版本可回退。")
                HStack {
                    Button("取消") { self.plan = nil }.buttonStyle(QuietButton())
                    Button("确认是原来的笔记") { apply(plan) }.buttonStyle(OutlinedButton()).disabled(busy)
                }
            }
            if let issue { Text(issue).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
        }
    }
    private func choose() {
        guard let connection = store.coMind else { return }
        let panel = NSOpenPanel(); panel.title = "重新定位原笔记"; panel.message = "选择移动或改名后的同一份笔记；随后核对位置。"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = try? KnowledgeSourceLocator.notesRoot(connection.repository)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do { plan = try await Task.detached { try OriginalRelocation.prepare(source: source, repository: connection.repository, target: target) }.value; issue = nil }
            catch { issue = error.localizedDescription }
        }
    }
    private func apply(_ plan: OriginalRelocationPlan) {
        guard store.coMind?.repository == plan.repository, store.coMind?.sources.contains(where: { $0.id == source.id && $0.path == source.path }) == true else { issue = "来源已变化，请重新打开"; return }
        busy = true
        Task {
            defer { busy = false }
            do { try await Task.detached { try OriginalRelocation.apply(plan) }.value; self.plan = nil; issue = nil; store.refreshOriginalActivity(); onComplete(); store.notify("原件位置已修复，关联与授权保留") }
            catch { issue = error.localizedDescription }
        }
    }
}
