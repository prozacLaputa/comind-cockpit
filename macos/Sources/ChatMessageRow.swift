import SwiftUI
import AppKit

struct ChatMessageRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.chatTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: CodexMessage
    let text: String
    let areaID: String?
    var threadID: String? = nil
    var isReplying = false
    @Binding var expanded: Bool
    var copyText: (String) -> Void
    @State private var hovered = false
    @FocusState private var copyFocused: Bool
    private var isUser: Bool { message.role == "你" }
    private var showActions: Bool { !isReplying && (!isUser || hovered || copyFocused) }
    private var displayedText: String { expanded ? text : String(text.prefix(24000)) }
    private func source(_ excerpt: Bool) -> DocumentOrigin? {
        threadID.map { .init(threadID: $0, messageID: message.id, excerpt: excerpt) }
    }
    var body: some View {
        let bubbleWidth = isUser && MessageMarkdown.blocks(displayedText).allSatisfy { if case .text = $0 { return true }; return false }
            ? ceil(MessageTextStyle.naturalWidth(displayedText, theme: theme, typography: typography)) + 30 : nil
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 32) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: isUser ? 4 : 12) {
                MessageWidthLayout(idealWidth: bubbleWidth, fontSize: typography.size) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !isUser {
                            HStack(spacing: 6) {
                                Text(message.role)
                                if let elapsed = message.durationLabel {
                                    Text("·").accessibilityHidden(true)
                                    Text(elapsed).help(message.locallyTimed
                                        ? "本机记录的本轮总用时，包含工具执行和等待授权。"
                                        : "Codex 记录的本轮总用时，包含工具执行和等待授权。")
                                }
                            }.font(.system(size: 10, weight: .regular)).foregroundStyle(theme.muted)
                        }
                        if message.isTool {
                            DisclosureGroup("查看工具详情") { Text(displayedText).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                                .font(CockpitTypography.caption)
                        } else {
                        MessageContent(text: displayedText, copySelection: copyText,
                                       saveSelection: areaID.flatMap { id in
                                           store.canEdit ? { store.saveResult($0, area: id, isExcerpt: true, origin: source(true)) } : nil
                                       })
                        }
                        ForEach(message.asyncQuestions) { question in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(question.title).font(CockpitTypography.body)
                                ForEach(question.options, id: \.self) { option in
                                    Button(option) { store.composerSeed = "针对你的问题：" + question.title + "\n我的回答：" + option }.buttonStyle(QuietButton())
                                }
                                Button("输入自己的回答") { store.composerSeed = "针对你的问题：" + question.title + "\n我的回答：" }.buttonStyle(InteractiveButton()).font(CockpitTypography.caption)
                                Caption(text: "选项会填入输入框，检查后发送；不会自动提交。")
                            }.padding(12).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
                        }
                        ForEach(message.attachments, id: \.self) { path in
                            AttachmentPreview(path: path)
                        }
                        if text.count > 24000 {
                            Button(expanded ? "收起长消息" : "展开完整消息") { expanded.toggle() }.buttonStyle(QuietButton())
                        }
                    }
                    .padding(.horizontal, isUser ? 14 : 0)
                    .padding(.vertical, isUser ? 10 : 0)
                    .background(isUser ? theme.soft : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                HStack(spacing: 8) {
                    if isUser, let timestamp = message.timestamp {
                        Text(timestamp.formatted(Calendar.current.isDateInToday(timestamp)
                            ? .dateTime.hour().minute() : .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                            .font(.system(size: 10, weight: .regular)).monospacedDigit()
                            .help("本轮发起于 " + timestamp.formatted(date: .complete, time: .standard))
                    }
                    Button { copyText(text) } label: {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 12, weight: .regular)).frame(width: 22, height: 22)
                    }.buttonStyle(InteractiveButton()).focused($copyFocused)
                        .help("复制消息").accessibilityLabel("复制消息")
                    if !isUser, !message.isTool, let areaID {
                        Button { store.saveResult(message.text, area: areaID, origin: source(false)) } label: {
                            Label("保存整条回复", systemImage: "bookmark")
                        }.buttonStyle(OutlinedButton()).disabled(!store.canEdit)
                            .help("把这条回复保存到当前阵地的资料")
                    }
                }.foregroundStyle(theme.muted)
                    // Reserve the footer's height so hover never moves neighboring messages.
                    .opacity(showActions ? 1 : 0)
                    .allowsHitTesting(showActions)
                    .disabled(isReplying)
                    .accessibilityHidden(isReplying)
                    .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: showActions)
            }.padding(.vertical, isUser ? 0 : 2)
                .frame(maxWidth: isUser ? 640 : .infinity, alignment: isUser ? .trailing : .leading)
                .background(MessageHoverRegion { hovered = $0 })
                .onDisappear { hovered = false; copyFocused = false }
            if !isUser { Spacer(minLength: 0) }
        }
        .accessibilityAction(named: Text("复制消息")) { copyText(text) }
    }
}

/// Track the whole bubble and its footer even when the selectable NSTextView is under the pointer.
/// This view never participates in hit testing, so text selection and copy remain native.
private struct MessageHoverRegion: NSViewRepresentable {
    var changed: (Bool) -> Void
    final class TrackingView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var region: NSTrackingArea?
        private var inside = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let region { removeTrackingArea(region) }
            let region = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
            addTrackingArea(region)
            self.region = region
        }
        override func mouseEntered(with event: NSEvent) { setInside(true) }
        override func mouseExited(with event: NSEvent) { setInside(false) }
        private func setInside(_ value: Bool) {
            guard inside != value else { return }
            inside = value
            changed(value)
        }
    }
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.changed = { _ in } }
}

/// Measure the natural width first, then wrap within the transcript's available width.
/// Code blocks retain the full available width for their independent scroll area.
struct MessageWidthLayout: Layout {
    var idealWidth: CGFloat?
    var fontSize: Int = ChatTypography.defaultSize
    // List asks for the same width with several height proposals. Chat content has an
    // intrinsic height; reuse that result until its content or available width changes.
    struct Cache { var sizes: [CGFloat: CGSize] = [:]; var fontSize: Int? }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.sizes.removeAll(keepingCapacity: true) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        if cache.fontSize != fontSize {
            cache.sizes.removeAll(keepingCapacity: true); cache.fontSize = fontSize
        }
        guard let content = subviews.first else { return .zero }
        let available = proposal.width ?? 640
        let width = max(1, idealWidth.map { min(available, $0, 640) } ?? available)
        if let size = cache.sizes[width] { return size }
        let measured = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let size = CGSize(width: width, height: measured.height)
        if cache.sizes.count >= 4 { cache.sizes.removeAll(keepingCapacity: true) }
        cache.sizes[width] = size
        return size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct AttachmentPreview: View {
    var path: String
    @State private var image: NSImage?
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle(); if expanded { load() } } label: { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "paperclip") }.buttonStyle(QuietButton())
            if expanded {
                if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 400, maxHeight: 280) }
                else { Caption(text: "附件暂不可预览，可在原会话中查看。") }
            }
        }
    }
    private func load() {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(url.pathExtension.lowercased()),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 15_000_000 else { return }
        image = NSImage(contentsOf: url)
    }
}
