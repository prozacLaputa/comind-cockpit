import AppKit

@main struct ChatInputSmoke {
    @MainActor static func main() {
        func action(_ key: UInt16 = 36, _ flags: NSEvent.ModifierFlags = [], marked: Bool = false, repeated: Bool = false) -> ChatReturnAction {
            ChatReturnAction.resolve(keyCode: key, modifiers: flags, composing: marked, repeated: repeated)
        }
        precondition(action() == .submit)
        precondition(action(76) == .submit)
        precondition(action(36, .shift) == .newline)
        precondition(action(76, [.shift, .numericPad]) == .newline)
        precondition(action(36, .command) == .submit)
        precondition(action(36, .capsLock) == .submit)
        precondition(action(36, .option) == .system)
        precondition(action(36, .control) == .system)
        precondition(action(0) == .system)
        precondition(action(repeated: true) == .ignore)
        precondition(action(36, .shift, repeated: true) == .newline)
        // Actual NSTextView composition state, without posting events to any window.
        let editor = ChatInputTextView()
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(editor.hasMarkedText())
        precondition(action(marked: editor.hasMarkedText()) == .system)
        precondition(action(36, .shift, marked: editor.hasMarkedText()) == .system)
        editor.unmarkText()
        precondition(action(marked: editor.hasMarkedText()) == .submit)
        print("PASS: Return/keypad submit, Shift newline, marked text defers to IME, held Return ignored, other keys preserved")

        let scroll = ChatInputScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 48))
        func measure(_ text: String, width: CGFloat = 420) -> CGFloat {
            scroll.setFrameSize(NSSize(width: width, height: 48))
            scroll.tile(); scroll.layout()
            scroll.editor.string = text
            scroll.editor.sizeToFit()
            return scroll.updateContentHeight()
        }
        precondition(measure("") == ChatInputScrollView.minimumHeight)
        precondition(measure("短消息 👩🏽‍💻") == ChatInputScrollView.minimumHeight)
        let fourLines = measure("第一行\n第二行\n第三行\n第四行")
        let extraLine = measure("第一行\n第二行\n第三行\n第四行\n")
        precondition(fourLines > ChatInputScrollView.minimumHeight)
        precondition(extraLine > fourLines && extraLine < ChatInputScrollView.maximumHeight)
        let wrapped = String(repeating: "中文输入与自动换行测试 👩🏽‍💻 ", count: 10)
        let wide = measure(wrapped, width: 720)
        let narrow = measure(wrapped, width: 240)
        precondition(narrow > wide)
        precondition(measure(String(repeating: "长文本的一行\n", count: 40)) == ChatInputScrollView.maximumHeight)
        precondition(scroll.editor.frame.height > ChatInputScrollView.maximumHeight, "Long content must remain scrollable")
        precondition(measure("删短后") == ChatInputScrollView.minimumHeight)
        scroll.editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let selection = scroll.editor.selectedRange()
        _ = scroll.updateContentHeight()
        precondition(scroll.editor.hasMarkedText() && scroll.editor.selectedRange() == selection)
        scroll.applyTypography(ChatTypography(size: 22))
        precondition(scroll.editor.hasMarkedText() && scroll.editor.selectedRange() == selection)
        precondition(scroll.editor.font?.pointSize == 15, "font changes wait for IME to commit")
        scroll.editor.unmarkText()
        let draft = "保留草稿与选区。\n第二行用来检查字号变化。\n第三行也需要正常换行。"
        scroll.applyTypography(ChatTypography(size: 12))
        let smallHeight = measure(draft)
        let draftSelection = NSRange(location: 2, length: 4)
        scroll.editor.setSelectedRange(draftSelection)
        scroll.applyTypography(ChatTypography(size: 22))
        let largeHeight = scroll.updateContentHeight()
        precondition(scroll.editor.string == draft && scroll.editor.selectedRange() == draftSelection)
        precondition(scroll.editor.font?.pointSize == 22 && largeHeight > smallHeight)
        precondition((scroll.editor.typingAttributes[.font] as? NSFont)?.pointSize == 22)
        precondition(measure(String(repeating: "长文本的一行\n", count: 40)) == ChatInputScrollView.maximumHeight)
        print("PASS: font changes retain draft/selection, defer during IME and remeasure the growing input with its height cap")
        print("PASS: native wrapped-line growth, trailing newline, resize reflow, capped scrollable content, shrink and IME selection preserved")
    }
}
