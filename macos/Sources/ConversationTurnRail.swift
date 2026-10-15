import SwiftUI

/// Navigation is based on user prompts, not individual streaming assistant items.
struct ConversationTurn: Identifiable, Equatable {
    let id: String
    let messageIndex: Int
    let preview: String
    let timestamp: Date?

    static func index(_ messages: [CodexMessage]) -> [Self] {
        messages.enumerated().compactMap { index, message in
            guard message.role == "你" else { return nil }
            let visible = ConversationContext.visibleUserText(message.text)
            let preview = String(visible.prefix(240)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return Self(id: message.id, messageIndex: index, preview: preview.isEmpty ? "未包含文字的消息" : preview, timestamp: message.timestamp)
        }
    }

    static func containing(messageIndex: Int, in turns: [Self]) -> String? {
        guard !turns.isEmpty, messageIndex >= turns[0].messageIndex else { return nil }
        var lower = 0, upper = turns.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if turns[middle].messageIndex <= messageIndex { lower = middle + 1 }
            else { upper = middle }
        }
        return turns[lower - 1].id
    }

    static func position(at y: CGFloat, height: CGFloat, count: Int) -> Int {
        guard count > 1, height > 0 else { return 0 }
        return min(count - 1, max(0, Int((min(height, max(0, y)) / height * CGFloat(count - 1)).rounded())))
    }
}

/// A bounded canvas keeps thousands of turns from creating thousands of controls.
struct ConversationTurnRail: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let turns: [ConversationTurn]
    var activeID: String?
    var select: (String) -> Void
    @State private var hovered: Int?
    @State private var lastDragged: Int?
    @State private var keyboardPreview = false
    @FocusState private var focused: Bool

    private var active: Int? { turns.firstIndex { $0.id == activeID } }
    var body: some View {
        GeometryReader { geometry in
            let height = max(1, min(geometry.size.height - 48, CGFloat(max(1, turns.count - 1)) * 13))
            let top = max(24, (geometry.size.height - height) / 2)
            let highlighted = hovered ?? active
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    let slots = min(80, turns.count)
                    for slot in 0..<slots {
                        let y = top + (slots > 1 ? CGFloat(slot) / CGFloat(slots - 1) * height : 0)
                        let rect = CGRect(x: size.width - 16, y: y - 1, width: 10, height: 2)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(theme.muted.opacity(hovered == nil ? 0.28 : 0.42)))
                    }
                    if let active {
                        let y = top + CGFloat(active) / CGFloat(max(1, turns.count - 1)) * height
                        context.fill(Path(roundedRect: CGRect(x: size.width - 23, y: y - 2, width: 18, height: 4), cornerRadius: 2), with: .color(theme.accent))
                    }
                    if let hovered, hovered != active {
                        let y = top + CGFloat(hovered) / CGFloat(max(1, turns.count - 1)) * height
                        context.fill(Path(roundedRect: CGRect(x: size.width - 21, y: y - 1.5, width: 16, height: 3), cornerRadius: 1.5), with: .color(theme.text.opacity(0.7)))
                    }
                }.allowsHitTesting(false)
                Color.clear.frame(height: height + 24).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = ConversationTurn.position(at: location.y - 12, height: height, count: turns.count)
                        case .ended: if lastDragged == nil { hovered = nil }
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard !turns.isEmpty else { return }
                        keyboardPreview = false
                        let index = ConversationTurn.position(at: value.location.y - 12, height: height, count: turns.count)
                        hovered = index
                        if lastDragged != index { lastDragged = index; select(turns[index].id) }
                    }.onEnded { value in
                        lastDragged = nil
                        if value.location.x < 0 || value.location.x > geometry.size.width || value.location.y < 0 || value.location.y > height + 24 { hovered = nil }
                    })
                    .modifier(CockpitPointer(enabled: true))
                    .offset(y: top - 12)
            }
            .overlay(alignment: .topTrailing) {
                if let highlighted, turns.indices.contains(highlighted), hovered != nil || (focused && keyboardPreview) {
                    preview(turns[highlighted], index: highlighted)
                        .frame(width: 250, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: -36, y: min(max(0, top + CGFloat(highlighted) / CGFloat(max(1, turns.count - 1)) * height - 42), max(0, geometry.size.height - 140)))
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .offset(x: 4)))
                }
            }
            .contentShape(Rectangle())
            .focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(.upArrow) { keyboardPreview = true; step(-1); return .handled }
            .onKeyPress(.downArrow) { keyboardPreview = true; step(1); return .handled }
            .onKeyPress(.escape) { focused = false; hovered = nil; keyboardPreview = false; return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("按对话轮次导航")
            .accessibilityValue(active.map { "第 \($0 + 1) 轮，共 \(turns.count) 轮" } ?? "共 \(turns.count) 轮")
            .accessibilityHint("上下方向键切换轮次；悬停预览，点击或拖动定位")
            .accessibilityAdjustableAction { direction in
                switch direction { case .increment: step(1); case .decrement: step(-1); @unknown default: break }
            }
            .animation(reduceMotion ? nil : CockpitMotion.feedback, value: hovered != nil || (focused && keyboardPreview))
        }
        .frame(width: ChatLayout.navigationGutter)
        .onChange(of: turns.map(\.id)) { _, _ in hovered = nil; lastDragged = nil; keyboardPreview = false }
    }

    private func step(_ offset: Int) {
        guard !turns.isEmpty else { return }
        let index = min(turns.count - 1, max(0, (active ?? 0) + offset))
        select(turns[index].id)
    }

    private func preview(_ turn: ConversationTurn, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("第 \(index + 1) / \(turns.count) 轮").foregroundStyle(theme.emphasis)
                Spacer(minLength: 4)
                if let date = turn.timestamp { Text(date, format: .dateTime.month().day().hour().minute()).foregroundStyle(theme.muted) }
            }.font(.system(size: 10, weight: .medium))
            Text(turn.preview).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(3)
        }.padding(12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(theme.dark ? 0.22 : 0.09), radius: 12, y: 4)
    }
}
