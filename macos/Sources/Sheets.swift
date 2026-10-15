import SwiftUI
import AppKit

struct SheetHost: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    var sheet: AppStore.Sheet
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(title).font(CockpitTypography.font(size: 22, weight: .medium)); Spacer(); Button { store.sheet = nil } label: { Image(systemName: "xmark").font(CockpitTypography.font(size: 12, weight: .medium)).frame(width: 30, height: 30) }.buttonStyle(InteractiveButton()).keyboardShortcut(.cancelAction).help("关闭") }
            switch sheet {
            case .noteWriteback: NoteWritebackSettingsView()
            case .noteChanges: NoteChangesView()
            case .reviewNotes: NoteReviewView()
            case .consolidateNotes: ConsolidateNotesView(bridge: store.codex)
            case .coMindSource: CoMindSourceEditor()
            case .search: WorkspaceSearchView()
            case .area: AreaForm()
            case .editCapture: CaptureEditor()
            case .employee: EmployeeForm()
            case .memory: MemoryEditor()
            case .codexInfo: CodexRelationshipView(bridge: store.codex)
            case .manageArea: AreaManagement()
            case .deleteArea:
                if let area = store.areas.first(where: { $0.id == store.editingAreaID }) {
                    AreaDeletionConfirmation(area: area) { store.sheet = nil }
                } else { Text("这个阵地已不存在。") }
            case .deleteThread: ThreadDeletion(bridge: store.codex)
            case .renameThread:
                if let thread = store.managingThread { ThreadRenameEditor(bridge: store.codex, thread: thread).id(thread.id) }
            case .deleteDocument: DocumentDeletionConfirmation()
            case .note: OriginalNoteCaptureForm()
            case .theme: SettingsView()
            case .link: LinkForm()
            }
        }.padding(28).frame(width: sheet.modalWidth).background(theme.canvas).foregroundStyle(theme.text).tint(theme.accent)
    }
    var title: String { switch sheet { case .noteWriteback: "默认写回与自动整理"; case .noteChanges: "原笔记的最近改动"; case .reviewNotes: "待你核对"; case .consolidateNotes: "整理到已有笔记"; case .coMindSource: "原文件"; case .search: "统一搜索"; case .employee: "员工配置"; case .memory: "旧版历史条目"; case .codexInfo: "与 Codex 的关系"; case .area: "新建阵地"; case .editCapture: "编辑随手记"; case .manageArea: "编辑阵地"; case .deleteArea: "归档阵地"; case .deleteThread: "删除 Codex 会话"; case .renameThread: "重命名会话"; case .deleteDocument: store.documents.first(where: { $0.id == store.deletingDocumentID })?.isReal == true ? "移除资料" : "删除资料"; case .note: "记录到原笔记"; case .theme: "设置"; case .link: "关联已有资料" } }
}
struct LinkForm: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "只建立关联，不移动或复制原文件。")
            let candidates = store.documents.filter { $0.areaID != store.contextArea && !$0.linkedAreas.contains(store.contextArea) }
            if candidates.isEmpty { Caption(text: "现有资料都已关联。") }
            ForEach(candidates) { doc in Button { store.link(doc.id, area: store.contextArea) } label: { HStack { Image(systemName: "doc.text"); Text(doc.name); Spacer(); Image(systemName: "plus") }.padding(15).background(theme.surface, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(InteractiveButton()) }
        }
    }
}
struct FilePreview: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    var document: DocumentRecord
    @State private var editing = false
    @State private var name = ""
    @State private var text = ""
    @State private var history = false
    @State private var restoring: DocumentRevision?
    private var draftKey: String { "legacy:" + document.id.uuidString }
    private var current: DocumentRecord { store.documents.first { $0.id == document.id } ?? document }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editing ? "编辑资料" : current.name).font(CockpitTypography.title(20)).lineLimit(2)
                Spacer()
                Button { store.filePreview = nil } label: { Image(systemName: "xmark").frame(width: 30, height: 30) }.buttonStyle(InteractiveButton()).keyboardShortcut(.cancelAction)
            }
            if editing {
                CockpitField(title: "资料名称", text: $name)
                CockpitEditor(title: "正文", text: $text)
                Caption(text: "保存会保留上一版。已迁移的资料写回同一个 CoMind 知识范围。")
                HStack {
                    Button("取消编辑") { editing = false }.buttonStyle(QuietButton())
                    Spacer()
                    Button("保存修改") { store.editDocument(current.id, name: name, body: text); if store.storageWarning == nil { _ = store.clearEditingDraft(draftKey); editing = false } }.buttonStyle(PrimaryButton()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                ScrollView { Text(store.readBody(current)).font(CockpitTypography.body).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }.frame(height: 280).background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 10) {
                    if !current.isReal {
                        Button("编辑名称与正文") { let saved = store.editorBuffers[draftKey]; name = saved?.title ?? current.name; text = saved?.text ?? current.body; editing = true }.buttonStyle(OutlinedButton())
                        Button("版本 · \(current.revisions?.count ?? 0)") { history.toggle() }.buttonStyle(QuietButton())
                    } else {
                        Button("重新定位文件…") { store.relocateDocument(current.id) }.buttonStyle(QuietButton())
                    }
                    if current.origin != nil { Button("回到原消息") { store.openDocumentSource(current) }.buttonStyle(QuietButton()) }
                    Spacer()
                    Button { store.requestDocumentDeletion(current.id) } label: { Image(systemName: "trash") }.buttonStyle(QuietButton()).help("移入回收站")
                }
                if history {
                    if let restoring {
                        HStack {
                            Text("恢复这一版？当前正文也会保留为历史。").font(CockpitTypography.caption)
                            Button("取消") { self.restoring = nil }.buttonStyle(QuietButton())
                            Button("确认恢复") { store.editDocument(current.id, name: restoring.name, body: restoring.body); self.restoring = nil }.buttonStyle(PrimaryButton())
                        }
                    }
                    ScrollView {
                        ForEach((current.revisions ?? []).reversed()) { revision in
                            HStack { Text(revision.date.formatted(date: .abbreviated, time: .shortened)); Text(revision.name).lineLimit(1); Spacer(); Button("恢复此版") { restoring = revision }.buttonStyle(QuietButton()) }
                        }
                    }.frame(maxHeight: 100)
                }
                HStack {
                    if let url = current.localURL {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(QuietButton())
                        Button("用原编辑器打开") { NSWorkspace.shared.open(url) }.buttonStyle(QuietButton())
                    } else { Button("导出 Markdown…") { store.export(current) }.buttonStyle(QuietButton()) }
                    Spacer()
                    if store.areas.contains(where: { $0.id == current.areaID }) { Button("进入所属阵地") { store.filePreview = nil; store.openArea(current.areaID) }.buttonStyle(QuietButton()) }
                }
            }
        }.onChange(of: text) { _, _ in retainDraft() }.onChange(of: name) { _, _ in retainDraft() }
        .onDisappear { retainDraft(); _ = store.flushEditingDraft(draftKey) }
        .padding(28).frame(width: 740).background(theme.canvas).foregroundStyle(theme.text)
    }
    private func retainDraft() {
        guard editing else { return }
        store.retainEditingDraft(key: draftKey, value: .init(title: name, text: text), source: nil, version: nil, area: current.areaID)
    }

}

struct DocumentDeletionConfirmation: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    var body: some View {
        if let document = store.documents.first(where: { $0.id == store.deletingDocumentID }) {
            VStack(alignment: .leading, spacing: 16) {
                Label(document.name, systemImage: "doc.text")
                    .font(CockpitTypography.section).lineLimit(3).textSelection(.enabled)
                Text(document.isReal
                     ? "将从驾驶舱及所有关联阵地移除这份资料的引用。原文件保留在原位置，可以重新关联。"
                     : "将把这份资料移入回收站，可在「设置 → 恢复」找回。原始 Codex 会话和导出的文件保留。")
                    .font(CockpitTypography.body).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                let linked = store.areas.filter { $0.id == document.areaID || document.linkedAreas.contains($0.id) }
                if !linked.isEmpty {
                    Text("关联阵地：" + linked.map(\.name).joined(separator: "、"))
                        .font(CockpitTypography.caption).foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = store.storageWarning {
                    Text(warning).font(CockpitTypography.caption).foregroundStyle(theme.emphasis)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("取消") { store.sheet = nil }.buttonStyle(QuietButton())
                    Spacer()
                    Button(document.isReal ? "确认移除" : "确认删除", role: .destructive) {
                        store.deleteDocument(document.id)
                    }.buttonStyle(PrimaryButton()).disabled(!store.canEdit)
                }
            }
        } else { Caption(text: "这份资料已不存在。") }
    }
}

struct AreaIconPicker: View {
    @Binding var symbol: String
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let icons: [(String, String)] = [
        ("square.stack.3d.up", "空间"), ("briefcase", "工作"), ("terminal", "编程"),
        ("cpu", "硬件"), ("chart.line.uptrend.xyaxis", "成长"), ("target", "目标"),
        ("heart", "健康"), ("brain.head.profile", "心理"), ("figure.run", "运动"),
        ("moon", "睡眠"), ("fork.knife", "饮食"), ("leaf", "自然"),
        ("book", "阅读"), ("graduationcap", "学习"), ("lightbulb", "想法"),
        ("pencil", "写作"), ("paintpalette", "设计"), ("camera", "摄影"),
        ("house", "生活"), ("airplane", "旅行"), ("music.note", "音乐"),
        ("gamecontroller", "游戏"), ("person.2", "关系"), ("folder", "资料")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("选择图标").font(CockpitTypography.font(size: 12, weight: .medium))
                Spacer()
                Label(Self.icons.first(where: { $0.0 == symbol })?.1 ?? "当前图标", systemImage: symbol)
                    .font(CockpitTypography.caption).foregroundStyle(theme.accent)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(Self.icons, id: \.0) { icon in
                    Button { symbol = icon.0 } label: {
                        VStack(spacing: 5) {
                            Image(systemName: icon.0).font(CockpitTypography.font(size: 18, weight: .regular)).frame(height: 22)
                            Text(icon.1).font(CockpitTypography.font(size: 10, weight: symbol == icon.0 ? .medium : .regular))
                        }.frame(maxWidth: .infinity).frame(height: 51)
                            .foregroundStyle(symbol == icon.0 ? theme.emphasis : theme.muted)
                    }.buttonStyle(InteractiveButton(selected: symbol == icon.0))
                        .help(icon.1).accessibilityLabel(icon.1)
                        .accessibilityAddTraits(symbol == icon.0 ? .isSelected : [])
                }
            }.padding(5).background(theme.sidebar, in: RoundedRectangle(cornerRadius: 11))
                .animation(reduceMotion ? nil : CockpitMotion.feedback, value: symbol)
        }
    }
}

struct AreaForm: View {
    @EnvironmentObject var store: AppStore
    @State private var name = ""
    @State private var purpose = ""
    @State private var symbol = "square.stack.3d.up"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CockpitField(title: "阵地名称", text: $name, placeholder: "给这个长期关注的主题起个名字")
            CockpitField(title: "阵地目标", text: $purpose, placeholder: "你想持续关注什么")
            AreaIconPicker(symbol: $symbol)
            Caption(text: "填写用途后，AI 会拟定职责、性格、能力和工作方式，等你审核；资料和会话可以稍后关联。")
            HStack { Spacer(); Button("创建并拟定配置") { store.createArea(name: name, purpose: purpose, symbol: symbol, configureEmployee: true) }.buttonStyle(PrimaryButton()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
        }
    }
}

struct AreaManagement: View {
    @EnvironmentObject var store: AppStore
    @State private var name = ""
    @State private var purpose = ""
    @State private var symbol = "square.stack.3d.up"
    @State private var confirmingDelete = false
    var body: some View {
        if let id = store.editingAreaID, let area = store.areas.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 20) {
                if confirmingDelete {
                    AreaDeletionConfirmation(area: area, cancelTitle: "返回编辑") { confirmingDelete = false }
                } else {
                    CockpitField(title: "阵地名称", text: $name, placeholder: "输入新的阵地名称")
                    CockpitField(title: "阵地目标", text: $purpose, placeholder: "你想持续关注什么")
                    AreaIconPicker(symbol: $symbol)
                    HStack {
                        Button("删除阵地…") { confirmingDelete = true }.buttonStyle(QuietButton())
                        Spacer()
                        Button("保存修改") { store.updateArea(id, name: name, purpose: purpose, symbol: symbol) }.buttonStyle(PrimaryButton())
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.onAppear { name = area.name; purpose = area.purpose; symbol = area.symbol }
        } else { Text("这个阵地已不存在。") }
    }
}

struct AreaDeletionConfirmation: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    var area: Area
    var cancelTitle = "取消"
    var cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(area.name, systemImage: area.symbol).font(CockpitTypography.section)
            VStack(alignment: .leading, spacing: 10) {
                Text("将把阵地从日常导航中归档，员工配置、记忆、进展和会话关联全部保留。")
                Text("资料、随手记与原始文件留在原位置。")
                    .foregroundStyle(theme.muted)
            }.font(CockpitTypography.body).fixedSize(horizontal: false, vertical: true)
            Text("可以在「设置 → 恢复」中找回。").font(CockpitTypography.caption).foregroundStyle(theme.emphasis)
            HStack {
                Button(cancelTitle, action: cancel).buttonStyle(QuietButton())
                Spacer()
                Button("确认归档阵地") { store.deleteArea(area.id) }.buttonStyle(PrimaryButton())
            }
        }
    }
}

struct ThreadDeletion: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var bridge: CodexBridge
    @Environment(\.cockpitTheme) var theme
    var body: some View {
        if let thread = store.managingThread {
            VStack(alignment: .leading, spacing: 16) {
                Text(thread.title).font(CockpitTypography.section)
                Caption(text: "这会永久删除 Codex 中的整条会话，无法撤销；并清理所有阵地对它的关联。已保存的笔记和工作文件不会删除。")
                let count = store.threadLinks.filter { $0.threadID == thread.id }.count
                Caption(text: "当前有 \(count) 处阵地关联。若只想从当前阵地移除，请取消并使用「解除关联」。")
                if let error = bridge.error { Text(error).font(CockpitTypography.caption).foregroundStyle(theme.emphasis).textSelection(.enabled) }
                HStack {
                    Button("取消") { store.sheet = nil }.buttonStyle(QuietButton())
                    Spacer()
                    Button(bridge.deletingThreadID == nil ? "永久删除会话" : "正在删除…") {
                        Task {
                            if await bridge.deleteThread(thread) {
                                store.removeDeletedThreadReferences(thread.id)
                                if store.managingThread?.id == thread.id { store.sheet = nil; store.managingThread = nil }
                            }
                        }
                    }.buttonStyle(PrimaryButton()).disabled(bridge.deletingThreadID != nil || bridge.runningThreadID == thread.id || bridge.sending || bridge.reading)
                }
            }
        }
    }
}

struct ThreadRenameEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @ObservedObject var bridge: CodexBridge
    let thread: CodexThread
    @State private var name: String
    init(bridge: CodexBridge, thread: CodexThread) {
        self.bridge = bridge; self.thread = thread
        _name = State(initialValue: CodexBridge.cleanThreadName(thread.title))
    }
    private var cleanName: String { CodexBridge.cleanThreadName(name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CockpitField(title: "会话名称", text: $name, placeholder: "给这次对话起个名字", symbol: "pencil")
                .disabled(bridge.renamingThreadID != nil)
            Caption(text: "同步修改 Codex 中这条会话的名称，所有关联阵地都会显示新名称。")
            if let error = bridge.error { Text(error).font(CockpitTypography.caption).foregroundStyle(theme.emphasis).textSelection(.enabled) }
            HStack {
                Button("取消") { store.sheet = nil }.buttonStyle(QuietButton())
                Spacer()
                Button(bridge.renamingThreadID == thread.id ? "正在保存…" : "保存名称") {
                    let submitted = cleanName
                    Task {
                        if await bridge.renameThread(thread, name: submitted) {
                            if store.sheet == .renameThread && store.managingThread?.id == thread.id {
                                store.sheet = nil; store.managingThread = nil
                            }
                            store.notify("会话已重命名")
                        }
                    }
                }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                    .disabled(cleanName.isEmpty || cleanName == CodexBridge.cleanThreadName(thread.title) || !bridge.canRenameThread(thread))
            }
        }
    }
}
