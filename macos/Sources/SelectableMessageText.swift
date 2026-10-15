import AppKit
import SwiftUI

/// Read-only message text with native selection and a small, selection-only action menu.
struct SelectableMessageText: NSViewRepresentable {
    var text: String
    var code = false
    var copySelection: (String) -> Void
    var saveSelection: ((String) -> Void)?
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.chatTypography) private var typography
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> MessageTextView {
        if let view = MessageTextViewPool.shared.take(text: text, style: theme.id + ":" + typography.cacheKey + (code ? ":code" : ":text")) { return view }
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        let view = MessageTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setAccessibilityLabel(code ? "消息代码" : "消息正文")
        view.setAccessibilityHelp("选中文字后右键可复制或保存到资料。")
        return view
    }

    static func dismantleNSView(_ view: MessageTextView, coordinator: ()) {
        SelectionActionMenu.shared.dismiss(for: view)
        view.copySelection = { _ in }
        view.saveSelection = nil
        view.setSelectedRange(NSRange(location: 0, length: 0))
        MessageTextViewPool.shared.recycle(view)
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        if !enabled || view.menuTheme.id != theme.id { SelectionActionMenu.shared.dismiss(for: view) }
        view.menuTheme = theme
        view.isSelectable = enabled
        view.copySelection = copySelection
        view.saveSelection = enabled ? saveSelection : nil
        let key = theme.id + ":" + typography.cacheKey + (code ? ":code" : ":text")
        if view.source != text || view.styleKey != key {
            view.replaceContent(MessageTextStyle.render(text, code: code, theme: theme, typography: typography))
            view.source = text; view.styleKey = key
        }
        view.selectedTextAttributes = [.backgroundColor: NSColor(theme.accentSoft), .foregroundColor: NSColor(theme.text)]
        view.linkTextAttributes = [.foregroundColor: NSColor(theme.accent), .underlineStyle: NSUnderlineStyle.single.rawValue]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let width = code ? 1_000_000 : max(1, proposal.width ?? 640)
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: code ? max(1, ceil(used.width)) : width, height: max(18, ceil(used.height)))
    }
}

/// A small in-memory reuse pool for recycled transcript rows. Never stores files or callbacks.
final class MessageTextViewPool {
    static let shared = MessageTextViewPool()
    private struct Entry { let view: MessageTextView; let characters: Int }
    private var entries: [Entry] = []
    private var characters = 0
    func take(text: String, style: String) -> MessageTextView? {
        guard let index = entries.lastIndex(where: { $0.view.superview == nil && $0.view.window == nil && $0.view.source == text && $0.view.styleKey == style }) else { return nil }
        let entry = entries.remove(at: index)
        characters -= entry.characters
        return entry.view
    }
    func recycle(_ view: MessageTextView) {
        guard !entries.contains(where: { $0.view === view }) else { return }
        let count = view.source.utf16.count
        guard count <= 500_000 else { return }
        entries.append(Entry(view: view, characters: count)); characters += count
        while entries.count > 64 || characters > 500_000 { characters -= entries.removeFirst().characters }
    }
    func removeAll() { entries.removeAll(); characters = 0 }
}

final class MessageTextView: NSTextView {
    var source = ""
    var styleKey = ""
    var copySelection: (String) -> Void = { _ in }
    var saveSelection: ((String) -> Void)?
    var menuTheme = ThemeRegistry.all[0]

    var selectedText: String? {
        let range = selectedRange(), content = string as NSString
        guard range.location != NSNotFound, range.length > 0,
              range.location <= content.length, range.length <= content.length - range.location else { return nil }
        let result = content.substring(with: range)
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
    }

    func replaceContent(_ content: NSAttributedString) {
        let selection = selectedRange()
        // Theme changes and streaming appends must not discard an existing selection.
        let keepSelection = content.string.hasPrefix(string)
        if !keepSelection { SelectionActionMenu.shared.dismiss(for: self) }
        textStorage?.setAttributedString(content)
        if keepSelection, selection.location != NSNotFound, NSMaxRange(selection) <= content.length {
            setSelectedRange(selection)
        } else { setSelectedRange(NSRange(location: 0, length: 0)) }
        invalidateIntrinsicContentSize()
    }

    override func rightMouseDown(with event: NSEvent) { showSelectionMenu(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        rightMouseDown(with: event)
        return nil // Do not let NSTextView append system Services to this focused action menu.
    }
    override func accessibilityPerformShowMenu() -> Bool {
        showSelectionMenu(at: NSPoint(x: visibleRect.minX + 16, y: visibleRect.minY + 18))
        return window != nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { SelectionActionMenu.shared.dismiss(for: self) }
    }
    private func showSelectionMenu(at point: NSPoint) {
        guard isSelectable else { return }
        SelectionActionMenu.shared.show(from: self, at: point, count: selectedText?.count ?? 0,
                                        theme: menuTheme, actions: selectionActions())
    }

    func selectionActions() -> [SelectionMenuAction] {
        // Freeze both the visible text and destination before streaming or list reuse can change them.
        let selection = isSelectable ? selectedText : nil
        let openingText = string, copy = copySelection, save = saveSelection
        return [
            SelectionMenuAction(title: "复制", symbol: "square.on.square", shortcut: "⌘C", help: "复制选中的文字", enabled: selection != nil) { [weak self] in
                guard let self, self.isSelectable, self.string.hasPrefix(openingText), let selection else { return }
                copy(selection)
            },
            SelectionMenuAction(title: "保存到资料", symbol: "bookmark", help: selection == nil ? "请先选中文字" : (save == nil ? "请在可编辑的阵地内保存资料" : "仅保存选中的文字"), enabled: selection != nil && save != nil) { [weak self] in
                guard let self, self.isSelectable, self.saveSelection != nil, self.string.hasPrefix(openingText), let selection else { return }
                save?(selection)
            }
        ]
    }

    override func copy(_ sender: Any?) {
        guard isSelectable, let selection = selectedText else { return }
        copySelection(selection)
    }
}

enum MessageTextStyle {
    private static let widths: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512; cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    static func naturalWidth(_ text: String, theme: CockpitTheme, typography: ChatTypography = .init()) -> CGFloat {
        let key = (theme.id + ":" + typography.cacheKey + ":" + text) as NSString
        if let value = widths.object(forKey: key) { return CGFloat(value.doubleValue) }
        let width = render(text, code: false, theme: theme, typography: typography).size().width
        widths.setObject(NSNumber(value: Double(width)), forKey: key, cost: key.length * 2 + 32)
        return width
    }
    static func render(_ text: String, code: Bool, theme: CockpitTheme, typography: ChatTypography = .init()) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = code ? typography.codeLineSpacing : typography.lineSpacing
        let base = NSFont.systemFont(ofSize: typography.body, weight: .regular)
        let mono = NSFont.monospacedSystemFont(ofSize: typography.code, weight: .regular)
        let defaults: [NSAttributedString.Key: Any] = [.font: code ? mono : base, .foregroundColor: NSColor(theme.text), .paragraphStyle: paragraph]
        guard !code, let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: defaults)
        }
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            var attributes = defaults
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? mono : base
            // Keep chat prose at regular weight, including Markdown strong emphasis.
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attributes[.font] = font
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link; attributes[.foregroundColor] = NSColor(theme.accent) }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
