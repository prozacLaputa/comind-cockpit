import SwiftUI

struct ModelControl: View {
    @ObservedObject var bridge: CodexBridge
    let cwd: String
    let thread: CodexThread?
    @Binding var selection: CodexModelSelection?
    var locked = false
    @Environment(\.cockpitTheme) private var theme
    @State private var showing = false
    @State private var context: CodexModelContext?
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    private var inherited: CodexModelSelection? { context?.inherited ?? thread?.modelSettings }
    private var effective: CodexModelSelection? { selection ?? inherited }
    private var label: String {
        if let effective {
            let title = context?.models.first(where: { $0.id == effective.model })?.title ?? effective.model
            return title + (effective.effort.map { " · " + CodexModelSelection.effortName($0) } ?? "")
        }
        return loading ? "读取模型…" : "模型待确认"
    }
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                Text(label).lineLimit(1).truncationMode(.middle)
                Image(systemName: error == nil ? "chevron.down" : "exclamationmark.circle").font(.system(size: 9))
            }.font(.system(size: 12)).padding(.horizontal, 6).padding(.vertical, 6)
        }.buttonStyle(InteractiveButton()).disabled(locked || !bridge.connected)
            .accessibilityLabel("选择模型").accessibilityValue(label)
            .help(selection == nil ? "查看当前模型与推理强度" : "待发送：" + label)
            .popover(isPresented: $showing, arrowEdge: .top) {
                panel.environment(\.isEnabled, bridge.connected && !locked)
            }
            .task(id: cwd + (thread?.id ?? "new") + (thread?.modelSettings?.label ?? "") + String(bridge.connected)) { await load() }
            .onChange(of: showing) { _, visible in if visible { Task { await load() } } }
            .onDisappear { requestID = UUID(); showing = false }
    }
    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("模型与推理强度").font(CockpitTypography.section)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                    .buttonStyle(InteractiveButton()).disabled(loading).accessibilityLabel("刷新模型")
                Button { showing = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(InteractiveButton()).accessibilityLabel("关闭模型选择")
            }
            Text(selection == nil ? (thread == nil ? "本机默认" : "会话设置") + " · " + label : "下一条使用 · " + label)
                .font(CockpitTypography.caption).foregroundStyle(theme.muted)
            Button { selection = nil } label: {
                HStack {
                    Text(thread == nil ? "使用本机默认" : "沿用会话设置")
                    Spacer()
                    if selection == nil { Image(systemName: "checkmark") }
                }.font(CockpitTypography.body).padding(10)
            }.buttonStyle(InteractiveButton(selected: selection == nil))
            if loading { ProgressView("正在读取本机 Codex…").progressViewStyle(CockpitProgressStyle()) }
            if let error { Text(error).font(CockpitTypography.caption).foregroundStyle(theme.emphasis) }
            if let context {
                if context.models.isEmpty { Caption(text: "Codex 暂未提供可选模型，保留当前会话设置。") }
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(context.models) { model in
                            Button { selection = model.selection } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.title).font(CockpitTypography.body)
                                        if !model.detail.isEmpty { Text(model.detail).font(CockpitTypography.caption).foregroundStyle(theme.muted).lineLimit(2) }
                                    }
                                    Spacer(minLength: 8)
                                    if effective?.model == model.id { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            }.buttonStyle(InteractiveButton(selected: effective?.model == model.id))
                                .accessibilityLabel("使用模型 " + model.title)
                        }
                    }
                }.frame(height: min(260, CGFloat(context.models.count) * 72))
                if let effective, let model = context.models.first(where: { $0.id == effective.model }), !model.efforts.isEmpty {
                    Caption(text: "推理强度")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(model.efforts, id: \.self) { effort in
                            Button { selection = .init(model: model.id, effort: effort) } label: {
                                Text(CodexModelSelection.effortName(effort)).font(CockpitTypography.caption)
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }.buttonStyle(InteractiveButton(selected: effective.effort == effort))
                                .accessibilityLabel("推理强度 " + CodexModelSelection.effortName(effort))
                        }
                    }
                }
            }
            Caption(text: "切换从下一条消息生效，发送后沿用到本会话后续消息；不改全局默认或后台整理。查看与选择不消耗模型额度。")
            HStack { Spacer(); Button("完成") { showing = false }.buttonStyle(QuietButton()) }
        }.padding(16).frame(width: 410).background(theme.canvas).foregroundStyle(theme.text)
            .preferredColorScheme(theme.dark ? .dark : .light).onExitCommand { showing = false }
    }
    private func load() async {
        let token = UUID(); requestID = token
        context = nil; error = nil
        guard bridge.connected else { loading = false; return }
        loading = true
        defer { if requestID == token { loading = false } }
        do {
            let value = try await bridge.inspectModels(cwd: cwd, threadID: thread?.id)
            guard !Task.isCancelled, requestID == token else { return }
            context = value
        } catch {
            guard !Task.isCancelled, requestID == token else { return }
            self.error = error.localizedDescription
        }
    }
}
