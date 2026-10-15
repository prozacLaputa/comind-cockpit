import AppKit
import SwiftUI

/// Chat-only key handling. Other multiline forms retain normal Return behavior.
enum ChatReturnAction: Equatable {
    case system, newline, submit, ignore
    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool, repeated: Bool) -> Self {
        guard keyCode == 36 || keyCode == 76 else { return .system }
        // The input method owns Return until its marked text has been committed.
        guard !composing else { return .system }
        let keys = modifiers.intersection([.shift, .command, .option, .control])
        if keys == .shift { return .newline }
        if keys.isEmpty || keys == .command { return repeated ? .ignore : .submit }
        return .system
    }
}

final class ChatInputTextView: NSTextView {
    var submit: () -> Void = {}
    var focusChanged: (Bool) -> Void = { _ in }
    var receiveImages: ((NSPasteboard) -> Void)?
    override func paste(_ sender: Any?) {
        if let receiveImages, ChatAttachments.hasImages(.general) { receiveImages(.general) }
        else { super.paste(sender) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        receiveImages != nil && ChatAttachments.hasImages(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let receiveImages, ChatAttachments.hasImages(sender.draggingPasteboard) { receiveImages(sender.draggingPasteboard); return true }
        return super.performDragOperation(sender)
    }
    override func keyDown(with event: NSEvent) {
        switch ChatReturnAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                       composing: hasMarkedText(), repeated: event.isARepeat) {
        case .system: super.keyDown(with: event)
        case .newline: insertNewline(nil)
        case .submit: submit()
        case .ignore: break
        }
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged(false) }
        return result
    }
}

/// Measures the editor's real wrapped lines, including the empty line after Return.
final class ChatInputScrollView: NSScrollView {
    static let minimumHeight: CGFloat = 48
    static let maximumHeight: CGFloat = 220
    let editor = ChatInputTextView(frame: .zero)
    var heightChanged: (CGFloat) -> Void = { _ in }
    private var previousViewport = NSSize.zero
    private var appliedTypography: ChatTypography?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        borderType = .noBorder
        editor.isRichText = false
        editor.importsGraphics = false
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 0, height: 3)
        documentView = editor
        applyTypography(.init())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTypography(_ typography: ChatTypography) {
        // A setting change must not commit marked text or reset the user's draft/selection.
        guard appliedTypography != typography, !editor.hasMarkedText() else { return }
        let selection = editor.selectedRange()
        let font = NSFont.systemFont(ofSize: typography.body, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = typography.lineSpacing + 1
        editor.font = font
        editor.defaultParagraphStyle = paragraph
        if let storage = editor.textStorage {
            storage.addAttributes([.font: font, .paragraphStyle: paragraph], range: NSRange(location: 0, length: storage.length))
        }
        editor.typingAttributes[.font] = font
        editor.typingAttributes[.paragraphStyle] = paragraph
        editor.setSelectedRange(selection)
        appliedTypography = typography
        updateContentHeight()
    }

    override func layout() {
        super.layout()
        let viewport = contentSize
        editor.minSize = NSSize(width: 0, height: viewport.height)
        if abs(editor.frame.width - viewport.width) > 0.5 {
            editor.setFrameSize(NSSize(width: viewport.width, height: editor.frame.height))
        }
        updateContentHeight()
        if previousViewport != viewport {
            previousViewport = viewport
            if window?.firstResponder === editor, editor.selectedRange().length == 0 {
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
    }

    @discardableResult func updateContentHeight() -> CGFloat {
        guard editor.bounds.width > 1, let layout = editor.layoutManager, let container = editor.textContainer else {
            return Self.minimumHeight
        }
        layout.ensureLayout(for: container)
        let end = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let height = min(Self.maximumHeight, max(Self.minimumHeight, ceil(end + editor.textContainerInset.height * 2)))
        heightChanged(height)
        return height
    }
}

struct ChatInput: View {
    @Binding var text: String
    var canSend: Bool
    var send: () -> Void
    var receiveImages: ((NSPasteboard) -> Void)? = nil
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.chatTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var focused = false
    @State private var editorHeight = ChatInputScrollView.minimumHeight
    var body: some View {
        NativeChatInput(text: $text, focused: $focused, height: $editorHeight, theme: theme, typography: typography, editable: enabled, canSend: canSend && enabled, send: send, receiveImages: receiveImages)
            .frame(height: editorHeight).padding(10)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? theme.accent : theme.border, lineWidth: 1).allowsHitTesting(false))
            .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: focused)
            .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: editorHeight)
    }
}

private struct NativeChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var height: CGFloat
    var theme: CockpitTheme
    var typography: ChatTypography
    var editable: Bool
    var canSend: Bool
    var send: () -> Void
    var receiveImages: ((NSPasteboard) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ChatInputScrollView {
        let scroll = ChatInputScrollView(frame: .zero)
        let editor = scroll.editor
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("发送消息")
        editor.setAccessibilityHelp("Enter 发送，Shift+Enter 换行；输入法选字时不会发送。")
        editor.string = text
        scroll.heightChanged = { [weak coordinator = context.coordinator] height in coordinator?.scheduleHeight(height) }
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: ChatInputScrollView, context: Context) {
        context.coordinator.parent = self
        let editor = scroll.editor
        editor.receiveImages = editable ? receiveImages : nil
        editor.isEditable = editable
        editor.isSelectable = editable
        // Avoid resetting native selection, undo and IME composition on every SwiftUI update.
        if !editor.hasMarkedText(), editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            editor.undoManager?.removeAllActions()
        }
        scroll.applyTypography(typography)
        editor.textColor = NSColor(theme.text)
        editor.insertionPointColor = NSColor(theme.accent)
        editor.selectedTextAttributes = [.backgroundColor: NSColor(theme.accentSoft), .foregroundColor: NSColor(theme.text)]
        editor.submit = { [weak coordinator = context.coordinator] in
            guard let parent = coordinator?.parent, parent.canSend else { return }
            parent.send()
        }
        editor.focusChanged = { [weak coordinator = context.coordinator] value in
            DispatchQueue.main.async { coordinator?.parent.focused = value }
        }
        scroll.updateContentHeight()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeChatInput
        private var pendingHeight: CGFloat?
        private var heightScheduled = false
        init(_ parent: NativeChatInput) { self.parent = parent }
        func scheduleHeight(_ height: CGFloat) {
            pendingHeight = height
            guard !heightScheduled else { return }
            heightScheduled = true
            // AppKit can measure during SwiftUI layout; publish once, after that pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightScheduled = false
                if let height = self.pendingHeight, abs(self.parent.height - height) > 0.5 { self.parent.height = height }
            }
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            if let scroll = editor.enclosingScrollView as? ChatInputScrollView {
                scroll.applyTypography(parent.typography)
                scroll.updateContentHeight()
            }
        }
    }
}
