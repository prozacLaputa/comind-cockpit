import SwiftUI

enum OriginalNoteCapture {
    static func appended(_ draft: EditingDraft, to version: CoMindFileVersion, key: String) throws -> String {
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoMindFiles.failure("请先填写内容") }
        guard draft.baseHash == version.sha256 else { throw CoMindFiles.failure("原文已变化，请重新预览后保存；草稿仍保留") }
        let fingerprint = ChatAttachments.hash(Data((key + draft.title + draft.text).utf8))
        let marker = "<!-- cockpit-capture:" + fingerprint + " -->"
        if version.text.contains(marker) { return version.text }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return version.text.trimmingCharacters(in: .newlines) + "\n\n" + marker + "\n## " + (title.isEmpty ? "补充记录" : title) + "\n\n记录于：" + draft.updated.ISO8601Format() + "\n\n" + draft.text + "\n"
    }
}
extension AppStore {
    func openOriginalCapture() {
        if noteSeed == nil { noteDraftArea = contextArea; noteDraftSource = nil }
        sheet = .note
    }
    func requestOriginalCapture(_ text: String, area: String, origin: DocumentOrigin? = nil, excerpt: Bool = false) {
        guard noteSeed == nil else { sheet = .note; notify("还有一份未保存的摘录，请先处理；新摘录未覆盖它"); return }
        noteDraftArea = area; noteDraftSource = nil
        if let origin {
            noteSeed = "来源：[原会话](codex://threads/\(origin.threadID)) · 消息 \(origin.messageID)\n类型：" + (excerpt ? "选段摘录" : "整条回复摘录") + "，不自动视为已确认事实\n\n" + text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        } else { noteSeed = text }
        sheet = .note
    }
    func commitOriginalCapture(key: String, source: CoMindSource, version: CoMindFileVersion, draft: EditingDraft, area: String) async throws {
        guard let connection = coMind, connection.repository == version.repository,
              coMindSources(for: area).contains(where: { $0.id == source.id && $0.path == version.path }),
              CoMindFiles.kind(source.path) == .document else { throw CoMindFiles.failure("来源或授权已变化，未写入") }
        guard !version.file.pathComponents.contains(where: { $0.contains("日记") || $0.contains("梦境") || $0.contains("模板") || $0 == ".obsidian" }) else { throw CoMindFiles.failure("日记、梦境、模板和插件不作为记录目标") }
        let after = try OriginalNoteCapture.appended(draft, to: version, key: key)
        _ = try await Task.detached { try CoMindFiles.commit(.init(before: version, after: after)) }.value
        let cleared = clearEditingDraft(key)
        noteSeed = nil
        refreshOriginalActivity()
        notify(cleared ? "已写回原笔记，上一版已保留" : "原笔记已写回；编辑草稿清理未完成，可到恢复页处理")
    }
}

struct OriginalNoteCaptureForm: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @State private var area = ""
    @State private var selected = ""
    @State private var title = ""
    @State private var text = ""
    @State private var version: CoMindFileVersion?
    @State private var baseHash = ""
    @State private var loading = false
    @State private var saving = false
    @State private var preview = false
    @State private var issue: String?
    @State private var loadedKey = ""
    @State private var finished = false
    private var key: String { "append:" + area + ":" + selected }
    private var source: CoMindSource? { sources.first { $0.id.uuidString == selected } }
    private var sources: [CoMindSource] { store.coMindSources(for: area).filter { CoMindFiles.kind($0.path) == .document } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "写入已有原文件，保留来源和上一版；不额外创建驾驶舱知识库。")
            CockpitSelect(title: "所属阵地", selection: $area, options: [.init(id: "", label: "未归类")] + store.areas.map { .init(id: $0.id, label: $0.name) })
            CockpitSelect(title: "写到哪份原文件", selection: $selected, options: [.init(id: "", label: "选择与内容对应的已有原件")] + sources.map { .init(id: $0.id.uuidString, label: CoMindFiles.title($0, connection: store.coMind)) })
            if sources.isEmpty { Button("关联已有原笔记…") { store.chooseCoMindSource(area: area) }.buttonStyle(OutlinedButton()) }
            if loading { HStack { CockpitSpinner(); Caption(text: "读取原件与未完成编辑…") } }
            if let source, let version {
                Caption(text: version.file.path)
                if store.coMind?.selectedSources(for: area).contains(source.id) == true { Caption(text: "用于聊天已开启，下次发送会检查最新原文。") }
                else { Caption(text: "当前仅保存；可在资料中开启「用于聊天」。") }
                if preview {
                    ScrollView { VStack(alignment: .leading, spacing: 12) {
                        Caption(text: "将追加到原文件末尾，其他正文保持；摘录不自动成为本人事实。")
                        Text(text).font(CockpitTypography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(12) }.frame(height: 220).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    CockpitField(title: "记录标题", text: $title, placeholder: "可选")
                    CockpitEditor(title: "补充内容", height: 190, text: $text)
                }
                if let seed = store.noteSeed, !seed.isEmpty {
                    Button("把待保存摘录加入草稿") { text += (text.isEmpty ? "" : "\n\n") + seed; store.noteSeed = nil; retain() }.buttonStyle(QuietButton())
                }
                Caption(text: "关闭后可继续编辑；未完成草稿保存在原文件同目录，不用于聊天。")
                HStack {
                    Button("稍后继续") { retain(); _ = store.flushEditingDraft(key); store.sheet = nil }.buttonStyle(QuietButton())
                    Button("放弃草稿") { if store.clearEditingDraft(key) { finished = true; text = ""; title = ""; store.noteSeed = nil; store.sheet = nil } }.buttonStyle(QuietButton())
                    Spacer()
                    if preview {
                        Button("返回编辑") { preview = false }.buttonStyle(QuietButton())
                        Button("确认写回原文件") { save(source, version) }.buttonStyle(PrimaryButton())
                    } else {
                        Button("预览追加") { previewLatest() }.buttonStyle(PrimaryButton()).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else if !loading { Caption(text: "先选择原件，再编辑内容；默认写回只有一份时会自动选中。") }
            if let issue = issue ?? store.editorWarnings[key] { Text(issue).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
        }.disabled(saving)
            .onAppear { area = store.noteDraftArea.isEmpty ? store.contextArea : store.noteDraftArea; chooseDefault() }
            .onChange(of: area) { _, value in store.noteDraftArea = value; chooseDefault() }
            .task(id: key) { await load() }
            .onChange(of: text) { _, _ in if !loading { retain() } }
            .onChange(of: title) { _, _ in if !loading { retain() } }
            .onDisappear { if !saving { retain(); _ = store.flushEditingDraft(key) } }
    }
    private func chooseDefault() {
        let defaults = store.defaultWritebackSources(area: area)
        if let wanted = store.noteDraftSource, sources.contains(where: { $0.id == wanted }) { selected = wanted.uuidString }
        else { selected = defaults.count == 1 ? defaults.first!.uuidString : "" }
    }
    private func load() async {
        version = nil; loadedKey = ""; preview = false; issue = nil; loading = false
        guard let source, let connection = store.coMind else { return }
        let loadingKey = key
        loading = true
        defer { if key == loadingKey { loading = false } }
        do {
            let current = try await Task.detached { try CoMindFiles.read(source.path, in: connection.repository) }.value
            guard !Task.isCancelled, key == loadingKey, store.coMind == connection else { return }
            // Explicit capture follows existing document scope; diaries/plugins are never a target here.
            guard !current.file.pathComponents.contains(where: { $0.contains("日记") || $0.contains("模板") || $0 == ".obsidian" }) else { throw CoMindFiles.failure("请选已有主题笔记，日记和插件不作为记录目标") }
            try store.loadEditingDraft(key: key, source: source, version: current, area: area)
            version = current; loadedKey = loadingKey
            let saved = store.editorBuffers[key]
            text = saved?.text ?? ""; title = saved?.title ?? ""; baseHash = saved?.baseHash ?? current.sha256
            if saved == nil, let seed = store.noteSeed { text = seed; store.noteSeed = nil }
            store.noteDraftSource = source.id
            retain()
        } catch { issue = error.localizedDescription }
    }
    private func retain() {
        guard let source, let version, loadedKey == key, version.path == source.path, !saving, !finished else { return }
        store.retainEditingDraft(key: key, value: .init(title: title, text: text, baseHash: baseHash), source: source, version: version, area: area)
    }
    private func previewLatest() {
        guard let source, let connection = store.coMind else { return }
        let originalKey = key
        Task {
            do {
                let current = try await Task.detached { try CoMindFiles.read(source.path, in: connection.repository) }.value
                guard key == originalKey else { return }
                if baseHash != current.sha256 { issue = "原文已有更新。本次只追加下面的内容，不替换原文，请核对是否已记录过。" }
                version = current; baseHash = current.sha256; retain(); preview = true
            } catch { issue = error.localizedDescription }
        }
    }
    private func save(_ source: CoMindSource, _ version: CoMindFileVersion) {
        let draft = EditingDraft(title: title, text: text, baseHash: baseHash)
        let savingKey = key
        saving = true
        Task {
            defer { saving = false }
            do { try await store.commitOriginalCapture(key: savingKey, source: source, version: version, draft: draft, area: area); finished = true; store.sheet = nil }
            catch { issue = error.localizedDescription }
        }
    }
}
