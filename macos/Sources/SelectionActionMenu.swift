import AppKit
import SwiftUI

struct SelectionMenuAction {
    let title: String
    let symbol: String
    var shortcut = ""
    var help = ""
    var enabled = true
    let perform: () -> Void
}

/// A themed, transient context menu. It owns no document data beyond the opening snapshot.
final class SelectionActionMenu {
    static let shared = SelectionActionMenu()
    private var panel: SelectionMenuPanel?
    private var rows: [SelectionMenuRow] = []
    private var actions: [SelectionMenuAction] = []
    private var focused: Int?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var source: NSView?
    private var animated = true

    static func frame(at point: NSPoint, size: NSSize, screen: NSRect) -> NSRect {
        let bounds = screen.insetBy(dx: 8, dy: 8)
        let y = point.y - size.height >= bounds.minY ? point.y - size.height : point.y + 4
        return NSRect(x: min(max(point.x + 4, bounds.minX), bounds.maxX - size.width),
                      y: min(max(y, bounds.minY), bounds.maxY - size.height), width: size.width, height: size.height)
    }

    func show(from source: NSView, at point: NSPoint, count: Int, theme: CockpitTheme, actions: [SelectionMenuAction]) {
        dismiss(animated: false)
        guard let parent = source.window, let screen = parent.screen else { return }
        self.source = source; self.actions = actions
        animated = !theme.binary && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let size = NSSize(width: 248, height: 122)
        let origin = parent.convertPoint(toScreen: source.convert(point, to: nil))
        let menu = SelectionMenuPanel(contentRect: Self.frame(at: origin, size: size, screen: screen.visibleFrame),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false; menu.isOpaque = false; menu.backgroundColor = .clear
        menu.hasShadow = true; menu.hidesOnDeactivate = true; menu.level = .popUpMenu
        menu.setAccessibilityLabel("所选文字操作")
        menu.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(theme.surface).cgColor
        content.layer?.cornerRadius = 12
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(theme.border).cgColor
        let heading = NSTextField(labelWithString: count > 0 ? "所选文字" : "请先选中文字")
        heading.font = .systemFont(ofSize: 11); heading.textColor = NSColor(theme.muted)
        heading.frame = NSRect(x: 15, y: 95, width: 155, height: 15)
        content.addSubview(heading)
        let countLabel = NSTextField(labelWithString: count > 0 ? "\(count) 字" : "")
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = NSColor(theme.muted); countLabel.alignment = .right
        countLabel.frame = NSRect(x: 170, y: 95, width: 62, height: 15)
        content.addSubview(countLabel)
        let divider = NSView(frame: NSRect(x: 14, y: 87, width: 220, height: 0.5))
        divider.wantsLayer = true; divider.layer?.backgroundColor = NSColor(theme.border).cgColor
        content.addSubview(divider)
        rows = actions.enumerated().map { index, action in
            let row = SelectionMenuRow(action: action, theme: theme)
            row.frame = NSRect(x: 7, y: 47 - CGFloat(index) * 38, width: 234, height: 34)
            row.onHover = { [weak self] inside in self?.focus(inside ? index : nil) }
            row.invoke = { [weak self] in self?.invoke(index) }
            content.addSubview(row)
            return row
        }
        menu.contentView = content; panel = menu
        parent.addChildWindow(menu, ordered: .above)
        menu.alphaValue = animated ? 0 : 1
        menu.makeKeyAndOrderFront(nil)
        menu.makeFirstResponder(menu)
        if animated { NSAnimationContext.runAnimationGroup { context in
            context.duration = CockpitMotion.feedbackDuration
            menu.animator().alphaValue = 1
        } }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown { return self.handleKey(event) ? nil : event }
            if event.window !== panel { self.dismiss(restoreFocus: false) }
            return event
        }
        let center = NotificationCenter.default
        for (name, object) in [(NSApplication.didResignActiveNotification, nil as AnyObject?),
                               (NSWindow.willCloseNotification, parent), (NSWindow.didResizeNotification, parent),
                               (NSWindow.didMoveNotification, parent), (NSWindow.willMiniaturizeNotification, parent)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.dismiss(animated: false) })
        }
    }

    func dismiss(for source: NSView) { if self.source === source { dismiss(animated: false) } }

    func dismiss(animated shouldAnimate: Bool = true, restoreFocus: Bool = true) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        guard let menu = panel else { return }
        panel = nil; rows.removeAll(); actions.removeAll(); focused = nil
        let parent = menu.parent, responder = source
        let ownedFocus = menu.isKeyWindow
        source = nil
        menu.ignoresMouseEvents = true
        let close = {
            parent?.removeChildWindow(menu); menu.orderOut(nil); menu.close()
            // Closing a key panel can clear the key window. Restore only after it has closed,
            // and never take focus back from another window or an outside click's target.
            if ownedFocus, let parent, parent.isVisible, NSApp.isActive,
               NSApp.keyWindow == nil || NSApp.keyWindow === parent {
                parent.makeKeyAndOrderFront(nil)
                if restoreFocus, let responder, responder.window === parent { parent.makeFirstResponder(responder) }
            }
        }
        if animated && shouldAnimate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = CockpitMotion.feedbackDuration
                menu.animator().alphaValue = 0
            }, completionHandler: close)
        } else { close() }
    }

    private func focus(_ index: Int?) {
        focused = index.flatMap { actions[$0].enabled ? $0 : nil }
        for (i, row) in rows.enumerated() { row.setActive(i == focused, animated: animated) }
    }
    private func invoke(_ index: Int) {
        guard actions.indices.contains(index), actions[index].enabled else { return }
        let perform = actions[index].perform
        dismiss(); perform()
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel != nil else { return false }
        if event.keyCode == 53 { dismiss(); return true }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" { invoke(0); return true }
        if event.keyCode == 125 || event.keyCode == 126 || event.keyCode == 48 {
            let enabled = actions.indices.filter { actions[$0].enabled }
            guard !enabled.isEmpty else { return true }
            let backwards = event.keyCode == 126 || (event.keyCode == 48 && event.modifierFlags.contains(.shift))
            if let focused, let current = enabled.firstIndex(of: focused) {
                focus(enabled[(current + (backwards ? enabled.count - 1 : 1)) % enabled.count])
            } else { focus(backwards ? enabled.last : enabled.first) }
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 {
            if let focused { invoke(focused) }; return true
        }
        return false
    }
}

private final class SelectionMenuPanel: NSPanel {
    var keyHandler: (NSEvent) -> Bool = { _ in false }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { if !keyHandler(event) { super.keyDown(with: event) } }
}

/// AppKit wrapper keeps native button accessibility while drawing the shared theme's menu treatment.
private final class SelectionMenuRow: NSButton {
    var onHover: (Bool) -> Void = { _ in }
    var invoke: () -> Void = {}
    private let theme: CockpitTheme
    private var tracking: NSTrackingArea?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "")

    init(action: SelectionMenuAction, theme: CockpitTheme) {
        self.theme = theme
        super.init(frame: .zero)
        title = ""; isBordered = false; bezelStyle = .regularSquare; isEnabled = action.enabled
        wantsLayer = true; layer?.cornerRadius = 7
        target = self; self.action = #selector(activate)
        setAccessibilityLabel(action.title); setAccessibilityHelp(action.help)
        toolTip = action.help
        icon.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        icon.contentTintColor = NSColor(theme.muted); icon.imageScaling = .scaleProportionallyDown
        icon.frame = NSRect(x: 9, y: 10, width: 14, height: 14)
        label.stringValue = action.title; label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(theme.text); label.frame = NSRect(x: 34, y: 8, width: 145, height: 18)
        key.stringValue = action.shortcut; key.font = .systemFont(ofSize: 11, weight: .regular)
        key.textColor = NSColor(theme.muted); key.alignment = .right
        key.frame = NSRect(x: 184, y: 9, width: 39, height: 16)
        for child in [icon, label, key] as [NSView] { child.setAccessibilityElement(false); addSubview(child) }
        alphaValue = action.enabled ? 1 : 0.4
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {} // The theme layer and child views provide all visuals.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    func setActive(_ active: Bool, animated: Bool) {
        let color = NSColor(active ? theme.accentSoft : theme.surface).cgColor
        if animated, let layer {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            animation.toValue = color; animation.duration = CockpitMotion.feedbackDuration
            layer.add(animation, forKey: "menu-hover")
        }
        layer?.backgroundColor = color
        icon.contentTintColor = NSColor(active ? theme.accent : theme.muted)
    }
    @objc private func activate() { invoke() }
}
