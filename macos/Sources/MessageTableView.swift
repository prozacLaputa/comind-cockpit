import AppKit
import SwiftUI

/// One selectable text view per table, including selection across rows and columns.
/// Only horizontal overflow is handled here; vertical scrolling stays with the transcript.
struct MessageTableView: NSViewRepresentable {
    let table: MessageTable
    var copySelection: (String) -> Void
    var saveSelection: ((String) -> Void)?
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.chatTypography) private var typography
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> MessageTableScrollView { MessageTableScrollView() }
    func updateNSView(_ view: MessageTableScrollView, context: Context) {
        let text = view.messageText
        if !enabled || text.menuTheme.id != theme.id { SelectionActionMenu.shared.dismiss(for: text) }
        text.menuTheme = theme; text.isSelectable = enabled
        text.copySelection = copySelection; text.saveSelection = enabled ? saveSelection : nil
        let key = theme.id + ":" + typography.cacheKey
        if text.source != table.source || text.styleKey != key {
            text.replaceContent(MessageTableStyle.render(table, theme: theme, typography: typography))
            text.source = table.source; text.styleKey = key
            view.minimumContentWidth = CGFloat(table.columns) * typography.body * 10
            view.invalidateMeasurements()
        }
        text.selectedTextAttributes = [.backgroundColor: NSColor(theme.accentSoft), .foregroundColor: NSColor(theme.text)]
        text.linkTextAttributes = [.foregroundColor: NSColor(theme.accent), .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.scrollerKnobStyle = theme.dark ? .light : .dark
        view.setAccessibilityLabel("表格，\(table.columns) 列，\(table.rows.count) 行，含表头")
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTableScrollView, context: Context) -> CGSize? {
        nsView.measuredSize(availableWidth: max(1, proposal.width ?? 640))
    }
    static func dismantleNSView(_ view: MessageTableScrollView, coordinator: ()) {
        SelectionActionMenu.shared.dismiss(for: view.messageText)
        view.messageText.copySelection = { _ in }; view.messageText.saveSelection = nil
    }
}

final class MessageTableScrollView: NSScrollView {
    let messageText: MessageTextView
    var minimumContentWidth: CGFloat = 300
    private var measuredHeights: [CGFloat: CGFloat] = [:]
    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        container.lineFragmentPadding = 0; container.widthTracksTextView = false
        messageText = MessageTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)
        messageText.isEditable = false; messageText.isSelectable = true
        messageText.drawsBackground = false; messageText.textContainerInset = .zero
        messageText.isHorizontallyResizable = false; messageText.isVerticallyResizable = false
        messageText.setAccessibilityLabel("消息表格")
        messageText.setAccessibilityHelp("选中文字后右键可复制或保存到资料；宽表格可横向滚动。")
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = false; hasHorizontalScroller = true
        // Reserve a slim horizontal track only when necessary; it never covers the last row.
        scrollerStyle = .legacy; autohidesScrollers = true
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        documentView = messageText
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func invalidateMeasurements() { measuredHeights.removeAll(keepingCapacity: true); needsLayout = true }
    func measuredSize(availableWidth: CGFloat) -> CGSize {
        let width = max(minimumContentWidth, availableWidth)
        let height: CGFloat
        if let cached = measuredHeights[width] { height = cached }
        else {
            messageText.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            if let layout = messageText.layoutManager, let container = messageText.textContainer {
                layout.ensureLayout(for: container)
                height = ceil(layout.usedRect(for: container).height) + 1
            } else { height = 18 }
            if measuredHeights.count >= 4 { measuredHeights.removeAll(keepingCapacity: true) }
            measuredHeights[width] = height
        }
        let scroller = width > availableWidth + 0.5 ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return NSSize(width: availableWidth, height: height + scroller)
    }
    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        let size = measuredSize(availableWidth: width)
        let contentWidth = max(minimumContentWidth, width)
        let track = contentWidth > width + 0.5 ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        messageText.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        let contentSize = NSSize(width: contentWidth, height: size.height - track)
        if messageText.frame.size != contentSize { messageText.setFrameSize(contentSize) }
    }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { nextResponder?.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

enum MessageTableStyle {
    static func render(_ source: MessageTable, theme: CockpitTheme, typography: ChatTypography = .init()) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = source.columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true; table.hidesEmptyCells = false
        table.setValue(100, type: .percentageValueType, for: .width)
        let result = NSMutableAttributedString(string: "")
        for (rowIndex, row) in source.rows.enumerated() {
            for column in 0..<source.columns {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setValue(100 / CGFloat(source.columns), type: .percentageValueType, for: .width)
                cell.setWidth(10, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(NSColor(theme.border))
                cell.backgroundColor = NSColor(rowIndex == 0 ? theme.soft : theme.canvas)
                cell.verticalAlignment = .topAlignment
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = typography.lineSpacing; paragraph.textBlocks = [cell]
                switch column < source.alignments.count ? source.alignments[column] : .left {
                case .left: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                }
                let content = column < row.count ? row[column] : ""
                let text = NSMutableAttributedString(attributedString: MessageTextStyle.render(content + "\n", code: false, theme: theme, typography: typography))
                text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
                result.append(text)
            }
        }
        return result
    }
}
