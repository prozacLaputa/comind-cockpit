import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension AppStore {
    func chooseCoMindSource(area: String) {
        guard canEdit else { notify("数据暂不可写，请先处理存储提示"); return }
        guard let connection = coMind else { settingsTab = "数据"; sheet = .theme; return }
        let panel = NSOpenPanel()
        panel.title = "关联已有原笔记"
        panel.message = "选择现有笔记或 CoMind 工作资料；只保存引用，原文件留在原位置。"
        panel.directoryURL = (try? KnowledgeSourceLocator.notesRoot(connection.repository)) ?? connection.repository
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try attachCoMindSource(path: CoMindFiles.relativePath(url, in: connection.repository), area: area)
                notify("已关联原文件；可开启「用于聊天」使用")
            } catch { notify(error.localizedDescription) }
        }
    }
}

struct CoMindSourceEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var version: CoMindFileVersion?
    @State private var draft = ""
    @State private var editing = false
    @State private var preview = false
    @State private var candidate = false
    @State private var candidateText = ""
    @State private var sourceText = ""
    @State private var scopeText = ""
    @State private var issue: String?
    @State private var backup: URL?
    @State private var saving = false
    @State private var history: [URL]?
    @State private var blocks: [SourceTextBlock] = []
    @State private var reviewLocations: [SourceReviewLocation] = []
    @State private var focusedReviewLine: Int?
    @State private var draftConflict = false
    private var draftKey: String { source.map { store.editingKey($0) } ?? "" }
    private var source: CoMindSource? { store.editingCoMindSource }
    private var sourceDisplayPath: String {
        guard let source, let connection = store.coMind, let file = try? CoMindFiles.url(source.path, in: connection.repository) else { return source?.path ?? "" }
        return file.path
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let source {
                Text(sourceDisplayPath).font(CockpitTypography.caption).textSelection(.enabled)
                Caption(text: CoMindFiles.kind(source.path) == .candidates ? "这是 CoMind 规则待审草稿。保留 New、Reviewed、Rejected 结构，草稿不会自动成为已确认规则。" : CoMindFiles.kind(source.path) == .formal ? "这是 CoMind 协作规则，描述 AI 的工作方式。修改先预览，确认后写回原文件。" : "直接读取原资料；编辑写回同一个文件，其他 Agent 随后读取的是同一份内容。")
                if let issue { Text(issue).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
                if version == nil && issue != nil { RelocateOriginalButton(source: source) { load() } }
                if let warning = store.editorWarnings[draftKey] { Text(warning).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
                if draftConflict {
                    Caption(text: "原文在编辑期间发生变化，未保存的修改已找回。先对照最新原文，再决定写回。")
                    Button("对照最新原文与草稿") { draftConflict = false; preview = true; retainDraft() }.buttonStyle(OutlinedButton())
                }
                if preview, let version {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("写入前").font(CockpitTypography.section)
                            Text(version.text).textSelection(.enabled)
                            Divider()
                            Text("确认后原文件将变为").font(CockpitTypography.section)
                            Text(draft).textSelection(.enabled)
                        }.font(CockpitTypography.body).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(height: 300).background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    Caption(text: "保存前重新核对外部变更；上一版保存在原文件同目录的 .history 中。私密文件的历史也留在同一 private 范围。")
                    HStack {
                        Button("返回修改") { preview = false }.buttonStyle(QuietButton())
                        Spacer()
                        Button(CoMindFiles.kind(source.path) == .formal ? "确认修改正式文件" : "确认写回原文件") { save() }.buttonStyle(PrimaryButton()).disabled(draftConflict)
                    }
                } else if candidate {
                    CockpitEditor(title: "候选内容（单条）", height: 90, text: $candidateText)
                    CockpitField(title: "来源", text: $sourceText, placeholder: "来源文件或会话 ID")
                    CockpitField(title: "适用范围", text: $scopeText, placeholder: "例如 collaboration-workflow")
                    Caption(text: "这里只记录协作规则草稿；个人、健康和人物信息请写回对应原笔记。")
                    HStack {
                        Button("取消") { candidate = false }.buttonStyle(QuietButton())
                        Spacer()
                        Button("预览追加") {
                            guard let version else { return }
                            do { draft = try CoMindFiles.candidateDraft(in: version, text: candidateText, source: sourceText, scope: scopeText); issue = nil; preview = true } catch { issue = error.localizedDescription }
                        }.buttonStyle(PrimaryButton())
                    }
                } else if editing {
                    CockpitEditor(title: "原文件正文", height: 300, text: $draft)
                    Caption(text: "尚未写入。外部同时修改时会停止保存，保留编辑内容供你核对。")
                    HStack {
                        Button("稍后继续") { retainDraft(); store.sheet = nil }.buttonStyle(QuietButton())
                        Button("放弃修改") { if store.clearEditingDraft(draftKey) { editing = false; preview = false; draftConflict = false; load() } }.buttonStyle(QuietButton())
                        Spacer()
                        Button("预览修改") { preview = true }.buttonStyle(PrimaryButton()).disabled(draft == version?.text || draftConflict)
                    }
                } else {
                    originalReader
                    HStack {
                        Button("重新读取") { load() }.buttonStyle(QuietButton())
                        Button("历史") {
                            guard let version else { return }
                            do { history = try CoMindFiles.history(for: version); issue = nil } catch { issue = error.localizedDescription }
                        }.buttonStyle(QuietButton()).disabled(version == nil)
                        Button("编辑原文件") { draft = version?.text ?? ""; editing = true }.buttonStyle(OutlinedButton()).disabled(version == nil)
                        if CoMindFiles.kind(source.path) == .candidates {
                            Button("新增候选") { candidate = true }.buttonStyle(OutlinedButton()).disabled(version == nil)
                        }
                        Spacer()
                        Button("Finder") { reveal() }.buttonStyle(QuietButton())
                    }
                    if let history {
                        if history.isEmpty { Caption(text: "尚无驾驶舱保存的历史。") }
                        ScrollView {
                            ForEach(history, id: \.path) { file in
                                HStack {
                                    let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                                    Text(date.formatted(date: .abbreviated, time: .standard)).font(CockpitTypography.caption)
                                    Spacer()
                                    Button("预览恢复") {
                                        guard let version else { return }
                                        do { draft = try CoMindFiles.historyText(file, for: version); editing = true; preview = true; issue = nil } catch { issue = error.localizedDescription }
                                    }.buttonStyle(QuietButton())
                                }
                            }
                        }.frame(maxHeight: 100)
                    }
                    if let backup {
                        Button("查看上一版原文") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }.buttonStyle(QuietButton())
                    }
                }
                if issue != nil && (editing || preview || candidate) {
                    Button("保留草稿并对照最新原文") { retainDraft(); _ = store.flushEditingDraft(draftKey); load() }.buttonStyle(OutlinedButton())
                    Button("复制未保存的修改") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft, forType: .string); store.notify("修改已复制，可先保留再重新核对")
                    }.buttonStyle(QuietButton())
                }
            } else { Caption(text: "这个来源已解除关联。") }
        }.disabled(saving).overlay(alignment: .bottom) {
            if saving { Text("正在核对并写回原文件…").font(CockpitTypography.caption).padding(8).background(theme.surface) }
        }.onAppear { load() }
            .onChange(of: draft) { _, _ in if editing || candidate || preview { retainDraft() } }
            .onDisappear { if editing || candidate || preview { retainDraft(); _ = store.flushEditingDraft(draftKey) } }
    }
    private func retainDraft() {
        guard let source, let version else { return }
        let oldHash = store.editorBuffers[draftKey]?.baseHash
        store.retainEditingDraft(key: draftKey,
            value: .init(text: draft, baseHash: draftConflict ? (oldHash ?? version.sha256) : version.sha256),
            source: source, version: version, area: store.contextArea)

    }
    private func load() {
        guard let source, let connection = store.coMind else { return }
        Task {
            do {
                let current = try await Task.detached { try CoMindFiles.read(source.path, in: connection.repository) }.value
                guard store.editingCoMindSource?.id == source.id else { return }
                version = current; blocks = SourceReviewLocations.blocks(in: current.text)
                reviewLocations = SourceReviewLocations.find(in: current.text, candidateFile: CoMindFiles.kind(source.path) == .candidates)
                focusedReviewLine = store.focusCoMindSourceReview ? reviewLocations.first?.line : nil
                try store.loadEditingDraft(key: draftKey, source: source, version: current, area: store.contextArea)
                if let saved = store.editorBuffers[draftKey], saved.active != false {
                    draft = saved.text; editing = true; draftConflict = saved.baseHash != current.sha256
                }
                issue = nil
            } catch { version = nil; blocks = []; reviewLocations = []; focusedReviewLine = nil; issue = error.localizedDescription }
        }
    }

    private var focusedBlock: Int? {
        guard let line = focusedReviewLine else { return nil }
        return blocks.last(where: { $0.line <= line })?.line
    }
    private var originalReader: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                if !reviewLocations.isEmpty {
                    HStack {
                        Label("原文待核对 · \(reviewLocations.count) 处", systemImage: "text.badge.checkmark").font(CockpitTypography.caption).foregroundStyle(theme.muted)
                        Spacer()
                        if let line = focusedReviewLine, let index = reviewLocations.firstIndex(where: { $0.line == line }) {
                            Caption(text: "\(index + 1) / \(reviewLocations.count)")
                            Button("下一处") { focusedReviewLine = reviewLocations[(index + 1) % reviewLocations.count].line }.buttonStyle(QuietButton())
                        } else {
                            Button("定位待核对") { focusedReviewLine = reviewLocations.first?.line }.buttonStyle(QuietButton())
                        }
                    }
                } else if store.focusCoMindSourceReview && version != nil {
                    Caption(text: "已重新读取，当前原文未见待核对标记。")
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if version == nil { Caption(text: "尚未读取原文件") }
                        ForEach(blocks) { block in
                            Text(block.text).font(CockpitTypography.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(focusedBlock == block.line ? theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .id(block.line)
                        }
                    }.padding(8)
                }.frame(height: 300).background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            .onChange(of: focusedBlock) { _, block in
                guard let block else { return }
                withAnimation(reduceMotion ? nil : CockpitMotion.navigation) { proxy.scrollTo(block, anchor: .top) }
            }
            .task(id: version?.data) {
                await Task.yield()
                if let block = focusedBlock { proxy.scrollTo(block, anchor: .top) }
            }
        }
    }
    private func save() {
        guard let version, !saving, !draftConflict else { return }
        let change = CoMindFileChange(before: version, after: draft)
        saving = true
        Task {
            defer { saving = false }
            do {
                backup = try await Task.detached { try CoMindFiles.commit(change) }.value
                _ = store.clearEditingDraft(draftKey)
                preview = false; candidate = false; editing = false; history = nil; load()
                store.notify(backup == nil ? "原文没有变化" : "已写回原文件，上一版已保留")
            } catch { issue = error.localizedDescription }
        }
    }
    private func reveal() {
        guard let source, let connection = store.coMind, let url = try? CoMindFiles.url(source.path, in: connection.repository) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
