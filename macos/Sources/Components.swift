import SwiftUI
import AppKit

struct Badge: View {
    @Environment(\.cockpitTheme) var theme
    var text: String
    var body: some View { Text(text).font(CockpitTypography.font(size: 10, weight: .medium)).foregroundStyle(theme.emphasis).padding(.horizontal, 8).padding(.vertical, 4).background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 5)) }
}
/// Native cursor rectangles avoid unbalanced global cursor push/pop state.
private struct ClickCursor: NSViewRepresentable {
    var enabled: Bool
    final class CursorView: NSView {
        var enabled = true
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }
        override func resetCursorRects() {
            if enabled { addCursorRect(visibleRect, cursor: .pointingHand) }
        }
    }
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {
        view.enabled = enabled
        view.window?.invalidateCursorRects(for: view)
    }
}
/// Let macOS own pointer entry/exit and drag transitions instead of a global cursor stack.
struct CockpitPointer: ViewModifier {
    var enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(enabled ? .link : nil)
        } else {
            content.background(ClickCursor(enabled: enabled))
        }
    }
}
enum ButtonTreatment { case primary, quiet, outline, row, sidebar }
struct InteractiveButton: ButtonStyle {
    var treatment: ButtonTreatment = .row
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, treatment: treatment, selected: selected)
    }
    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        let treatment: ButtonTreatment
        let selected: Bool
        @Environment(\.cockpitTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        private var active: Bool { enabled && hovered }
        private var pressed: Bool { enabled && configuration.isPressed }
        private var styledDisabledPrimary: Bool { !enabled && treatment == .primary && theme.palette.primaryDisabled != nil }
        private var fill: Color {
            if theme.binary {
                if !enabled { return .white }
                return treatment == .primary || selected ? .black : .white
            }
            switch treatment {
            case .primary: return styledDisabledPrimary ? theme.primaryDisabled : active || pressed ? theme.primaryHover : theme.primary
            case .quiet, .outline: return active || pressed ? theme.accentSoft : theme.surface
            case .row, .sidebar:
                return selected || pressed ? theme.accentSoft : active ? theme.accent.opacity(theme.opacity(0.08)) : .clear
            }
        }
        var body: some View {
            configuration.label
                .font(CockpitTypography.font(size: treatment == .outline ? 12 : 13, weight: treatment == .primary || selected ? .medium : .regular))
                .padding(.horizontal, treatment == .primary ? 16 : treatment == .quiet ? 13 : treatment == .outline ? 10 : 0)
                .padding(.vertical, treatment == .primary ? 10 : treatment == .quiet ? 9 : treatment == .outline ? 6 : 0)
                .foregroundStyle(theme.binary ? (enabled && (treatment == .primary || selected) ? Color.white : Color.black) : styledDisabledPrimary ? theme.onPrimaryDisabled : treatment == .primary ? theme.onAccent : selected || active || pressed ? theme.emphasis : theme.text)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if treatment == .quiet {
                        RoundedRectangle(cornerRadius: 8).stroke(active ? theme.accent.opacity(theme.opacity(0.35)) : theme.border, lineWidth: 0.5)
                    } else if treatment == .outline {
                        RoundedRectangle(cornerRadius: 7).stroke(active ? theme.accent : theme.muted.opacity(theme.opacity(0.35)), lineWidth: 1)
                    }
                }
                .overlay(alignment: .leading) {
                    if treatment == .sidebar && selected {
                        Capsule().fill(theme.accent).frame(width: 3, height: 14).padding(.leading, 4)
                    }
                }
                .opacity(theme.binary || styledDisabledPrimary ? 1 : enabled ? (pressed ? 0.82 : 1) : 0.42)
                .overlay {
                    if theme.binary && enabled && (active || pressed) {
                        RoundedRectangle(cornerRadius: 8).stroke(.black, lineWidth: pressed ? 2 : 1)
                    }
                    if theme.binary && !enabled {
                        RoundedRectangle(cornerRadius: 8).stroke(.black, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .modifier(CockpitPointer(enabled: enabled))
                .onHover { hovered = $0 }
                .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: active)
                .animation((reduceMotion || theme.binary) ? nil : .easeOut(duration: 0.08), value: pressed)
                .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: selected)
        }
    }
}
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveButton(treatment: .primary).makeBody(configuration: configuration)
    }
}
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveButton(treatment: .quiet).makeBody(configuration: configuration)
    }
}
struct OutlinedButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveButton(treatment: .outline).makeBody(configuration: configuration)
    }
}
struct SectionHeading: View {
    var title: String
    var body: some View { Text(title).font(CockpitTypography.section) }
}
struct Caption: View {
    @Environment(\.cockpitTheme) var theme
    var text: String
    var body: some View { Text(text).font(CockpitTypography.caption).foregroundStyle(theme.muted) }
}
struct AreaCard: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    var area: Area
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        Button { store.openArea(area.id) } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 13) {
                    Image(systemName: area.symbol).font(CockpitTypography.font(size: 20, weight: .regular))
                        .foregroundStyle(theme.accent).frame(width: 42, height: 42)
                        .background(theme.accentSoft.opacity(theme.opacity(0.55)), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            Text(area.name).font(CockpitTypography.section)
                            
                        }
                        Text(area.purpose).font(CockpitTypography.font(size: 12)).foregroundStyle(theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right").font(CockpitTypography.font(size: 12, weight: .medium)).foregroundStyle(hovered ? theme.accent : theme.muted)
                }
                HStack(alignment: .top, spacing: 20) {
                    stat("关联资料", "\(store.documents(for: area.id).count + store.coMindSources(for: area.id).count) 份")
                    stat("Codex 会话", "\(store.threadLinks.filter { $0.areaID == area.id }.count) 个")
                }.padding(.leading, 55)
            }.padding(20).background(hovered ? theme.soft : theme.surface, in: RoundedRectangle(cornerRadius: theme.metrics.radius))
                .overlay(RoundedRectangle(cornerRadius: theme.metrics.radius).stroke(hovered ? theme.accent.opacity(theme.opacity(0.3)) : theme.border.opacity(theme.opacity(0.65)), lineWidth: 0.5))
                .shadow(color: .black.opacity(theme.dark || theme.binary ? 0 : 0.025), radius: 5, y: 2)
                .contentShape(Rectangle())
                .modifier(AreaReorder(id: area.id))
        }.buttonStyle(InteractiveButton()).onHover { hovered = $0 }.animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: hovered).accessibilityLabel("打开\(area.name)")
    }
    func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(CockpitTypography.caption).foregroundStyle(theme.muted)
            Text(value).font(CockpitTypography.font(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct DocumentList: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    let documents: [DocumentRecord]
    var body: some View {
        if documents.isEmpty {
            VStack(spacing: 12) { Image(systemName: "doc.text.magnifyingglass").font(CockpitTypography.font(size: 30)).foregroundStyle(theme.accent); Text("这里还没有资料").font(CockpitTypography.section); Caption(text: "关联本地文件，或新建一篇笔记。") }.frame(maxWidth: .infinity).padding(50)
        } else {
            VStack(spacing: 0) { ForEach(documents) { doc in
                HStack(spacing: 8) {
                    Button { store.filePreview = doc } label: {
                        HStack(spacing: 14) { Image(systemName: "doc.text").font(CockpitTypography.font(size: 23)).foregroundStyle(theme.accent); VStack(alignment: .leading, spacing: 6) { Text(doc.name).font(CockpitTypography.font(size: 14, weight: .medium)); Text("\(doc.source) · \(doc.path)").font(CockpitTypography.font(size: 11)).foregroundStyle(theme.muted).lineLimit(1) }; Spacer(); if doc.isReal { Badge(text: "本地文件") }; Image(systemName: "arrow.up.right").foregroundStyle(theme.muted) }.padding(.vertical, 17).padding(.horizontal, 10).contentShape(Rectangle())
                    }.buttonStyle(InteractiveButton()).accessibilityLabel("打开资料：\(doc.name)")
                    CockpitActionMenu(title: "资料操作：\(doc.name)", actions: [
                        .init(title: "打开资料", symbol: "doc.text") { store.filePreview = doc },
                        .init(title: doc.isReal ? "移除资料…" : "删除资料…", symbol: "trash", destructive: true, enabled: store.canEdit) { store.requestDocumentDeletion(doc.id) }
                    ])
                }.contextMenu {
                    Button(doc.isReal ? "移除资料…" : "删除资料…", systemImage: "trash", role: .destructive) { store.requestDocumentDeletion(doc.id) }.disabled(!store.canEdit)
                }
                theme.border.frame(height: 1)
            } }
        }
    }
}
struct CaptureBar: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    @State private var text = ""
    @State private var destination = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) { Image(systemName: "book.closed").font(CockpitTypography.font(size: 20)).foregroundStyle(theme.accent); TextField("", text: $text).overlay(alignment: .leading) { if text.isEmpty && !focused { Text("随时记录想法，接上正在关注的事…").foregroundStyle(theme.muted).allowsHitTesting(false).accessibilityHidden(true) } }.textFieldStyle(.plain).focused($focused).onSubmit(save).accessibilityLabel("记录想法"); Button { store.notify("语音尚未接入。你可以先记录文字，或从会话页打开 Codex。") } label: { Image(systemName: "mic").font(CockpitTypography.font(size: 20)) }.buttonStyle(InteractiveButton()).help("语音入口 · 尚未接入"); if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Button(action: save) { Image(systemName: "arrow.up.circle.fill").font(CockpitTypography.font(size: 25)).foregroundStyle(theme.accent) }.buttonStyle(InteractiveButton()).help("保存想法") } }.padding(14).background(theme.surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? theme.accent : theme.border, lineWidth: 1))
            if text.isEmpty { Caption(text: "文字保存到\(store.storageLabel) · 不会自动发送给 Codex").padding(.leading, 46) }
            else { HStack { Text("保存到").font(CockpitTypography.font(size: 12)); CockpitSelect(title: "阵地", selection: $destination, options: [SelectOption(id: "", label: "未归类")] + store.areas.map { SelectOption(id: $0.id, label: $0.name) }, showsLabel: false).frame(width: 155); Caption(text: "保留原话，不自动变成待办") } }
        }.onAppear { destination = store.contextArea; if store.focusCapture { focused = true; store.focusCapture = false } }.onChange(of: store.contextArea) { _, value in destination = value }.onChange(of: store.focusCapture) { _, value in if value { focused = true; store.focusCapture = false } }
    }
    func save() { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; store.capture(text, area: destination); text = "" }
}

/// Reorder only known area IDs; external text drops cannot create or change content.
struct AreaReorder: ViewModifier {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var id: String
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .draggable("comind-area:" + id) {
                Label(store.areaName(id), systemImage: store.areas.first(where: { $0.id == id })?.symbol ?? "folder")
                    .font(CockpitTypography.font(size: 13, weight: .medium)).foregroundStyle(theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.border, lineWidth: 1))
            }
            .dropDestination(for: String.self) { values, _ in
                guard values.count == 1, let value = values.first, value.hasPrefix("comind-area:") else { return false }
                return withAnimation((reduceMotion || theme.binary) ? nil : CockpitMotion.selection) {
                    store.moveArea(String(value.dropFirst("comind-area:".count)), to: id)
                }
            } isTargeted: { targeted = $0 }
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(targeted ? theme.accent : .clear, lineWidth: 2).allowsHitTesting(false))
            .help("拖动调整阵地顺序；向上拖放到目标前，向下拖放到目标后")
            .accessibilityAction(named: "上移") { store.moveArea(id, offset: -1) }
            .accessibilityAction(named: "下移") { store.moveArea(id, offset: 1) }
    }
}
