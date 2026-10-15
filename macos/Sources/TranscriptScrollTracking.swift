import SwiftUI
import AppKit

struct TranscriptAnchor {
    var rowID: String
    var messageID: String
    var offset: Double
    var rowHeight: Double
    var contentWidth: Double
    var toolDetails: Bool
}

/// Retains native position without publishing scroll offsets into SwiftUI.
@MainActor final class TranscriptScrollController {
    weak var tracker: TranscriptScrollTracking.Tracker?
    private var restoreGeneration = UUID()
    private(set) var restoring = false
    func capture() -> TranscriptAnchor? { tracker?.capture() }
    func cancelRestore() { restoreGeneration = UUID(); restoring = false }
    func restore(_ anchor: TranscriptAnchor) async {
        let token = UUID(); restoreGeneration = token; restoring = true
        defer { if restoreGeneration == token { restoring = false } }
        var stable = 0
        // List first estimates offscreen rows, then measures the destination. Correct
        // only this explicit restoration, until its row settles (bounded to 320 ms).
        for _ in 0..<20 {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard token == restoreGeneration, let tracker, tracker.window != nil else { return }
            if tracker.restore(anchor) { stable += 1 } else { stable = 0 }
            if stable >= 3 { break }
        }
    }
}

/// Read scroll position from the persistent native clip view, not a recycled message row.
struct TranscriptScrollTracking: NSViewRepresentable {
    var turns: [ConversationTurn]
    var entries: [TranscriptEntry]
    var rowOffset: Int
    var controller: TranscriptScrollController
    var report: (Bool) -> Void
    var reportTurn: (String?) -> Void
    var reportIdle: () -> Void
    var reportPosition: (TranscriptAnchor) -> Void
    var nearTop: () -> Void
    func makeNSView(context: Context) -> Tracker { Tracker() }
    func updateNSView(_ view: Tracker, context: Context) {
        view.report = report; view.reportTurn = reportTurn; view.reportIdle = reportIdle
        view.reportPosition = reportPosition; view.nearTop = nearTop
        view.controller = controller; controller.tracker = view
        view.turns = turns; view.entries = entries; view.rowOffset = rowOffset
        view.attachLater()
    }
    static func dismantleNSView(_ view: Tracker, coordinator: ()) { view.detach() }
    final class Tracker: NSView {
        var report: (Bool) -> Void = { _ in }
        var reportTurn: (String?) -> Void = { _ in }
        var reportIdle: () -> Void = {}
        var reportPosition: (TranscriptAnchor) -> Void = { _ in }
        var nearTop: () -> Void = {}
        weak var controller: TranscriptScrollController?
        private var idleWork: DispatchWorkItem?
        var turns: [ConversationTurn] = []
        var entries: [TranscriptEntry] = []
        private var messageCount: Int { entries.count }
        var rowOffset = 0
        private var lastTurnID: String?
        private weak var table: NSTableView?
        private weak var scroll: NSScrollView?
        private var observation: NSObjectProtocol?
        private var liveObservations: [NSObjectProtocol] = []
        private var wheelMonitor: Any?
        private var wheelEnd: DispatchWorkItem?
        private var userScrolling = false
        private var last: Bool?
        private var documentHeight: CGFloat = 0
        private var viewportHeight: CGFloat = 0
        private var previousY: CGFloat = 0
        private var topArmed = true
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachLater() }
        // List hosts its scroll view beside the representable background.
        private func findScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews { if let found = findScroll(in: child) { return found } }
            return nil
        }
        func attachLater() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var parent = self.superview
                var candidate = self.enclosingScrollView
                while candidate == nil, let view = parent {
                    candidate = self.findScroll(in: view); parent = view.superview
                }
                guard let scroll = candidate else { return }
                // SwiftUI's plain List still uses AppKit's full-width row padding.
                // Make our shared content inset the only horizontal row spacing.
                if let table = scroll.documentView as? NSTableView {
                    var changedLayout = false
                    if table.style != .plain { table.style = .plain; changedLayout = true }
                    if table.intercellSpacing.width != 0 {
                        table.intercellSpacing = NSSize(width: 0, height: table.intercellSpacing.height)
                        changedLayout = true
                    }
                    // AppKit retains the old column width after the style changes.
                    if changedLayout { table.sizeLastColumnToFit() }
                }
                if self.scroll === scroll { self.sampleTurn(); return }
                self.detach(); self.scroll = scroll
                self.table = scroll.documentView as? NSTableView
                scroll.contentView.postsBoundsChangedNotifications = true
                self.observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.sample() }
                let center = NotificationCenter.default
                self.liveObservations = [
                    center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.userScrolling = true; self?.controller?.cancelRestore() }
                    },
                    center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in self?.sample(); self?.userScrolling = false }
                ]
                // Also cover ordinary wheel devices, which do not always have a live-scroll phase.
                self.wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let scroll = self.scroll, event.window === scroll.window,
                          scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return event }
                    self.userScrolling = true
                    self.controller?.cancelRestore()
                    self.wheelEnd?.cancel()
                    let end = DispatchWorkItem { [weak self] in self?.userScrolling = false }
                    self.wheelEnd = end
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: end)
                    return event
                }
                self.documentHeight = scroll.documentView?.bounds.height ?? 0
                self.viewportHeight = scroll.contentView.bounds.height
                self.previousY = scroll.documentVisibleRect.minY
                self.sampleTurn()
            }
        }
        private func sample() {
            guard let scroll, let document = scroll.documentView else { return }
            idleWork?.cancel()
            let idle = DispatchWorkItem { [weak self] in self?.reportIdle() }
            idleWork = idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: idle)
            sampleTurn()
            let visible = scroll.documentVisibleRect
            let movingUp = visible.minY < previousY - 0.5
            previousY = visible.minY
            let threshold = max(180, visible.height * 0.5)
            if visible.minY > threshold { topArmed = true }
            if movingUp && userScrolling && visible.minY <= threshold && topArmed && controller?.restoring != true {
                topArmed = false
                DispatchQueue.main.async { [weak self] in self?.nearTop() }
            }
            if controller?.restoring == true { return }
            if let anchor = capture() { reportPosition(anchor) }
            let atBottom = document.isFlipped ? document.bounds.maxY - visible.maxY <= 32 : visible.minY - document.bounds.minY <= 32
            let relayout = abs(documentHeight - document.bounds.height) > 1 || abs(viewportHeight - visible.height) > 1
            documentHeight = document.bounds.height; viewportHeight = visible.height
            // Estimated row heights can move the clip origin without user input.
            // Only real scrolling may opt out; explicit search/rail jumps opt out at their call site.
            if !atBottom && !userScrolling { if relayout { last = nil }; return }
            guard atBottom != last else { return }
            last = atBottom
            DispatchQueue.main.async { [weak self] in
                guard let self, self.last == atBottom else { return }
                self.report(atBottom)
            }
        }
        private func sampleTurn() {
            // NSTableView already knows virtual row positions: no per-row geometry or text measurement.
            guard let table, let scroll, messageCount > 0, table.numberOfRows >= messageCount + rowOffset else { return }
            let visible = table.convert(scroll.contentView.bounds, from: scroll.contentView)
            let row = table.row(at: NSPoint(x: visible.midX, y: visible.minY + min(24, visible.height / 2)))
            guard row >= 0 else { return }
            let id = ConversationTurn.containing(messageIndex: min(messageCount - 1, max(0, row - rowOffset)), in: turns)
            guard id != lastTurnID else { return }
            lastTurnID = id
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastTurnID == id else { return }
                self.reportTurn(id)
            }
        }
        func capture() -> TranscriptAnchor? {
            guard let table, let scroll, !entries.isEmpty, table.numberOfRows >= entries.count + rowOffset else { return nil }
            let visible = table.convert(scroll.contentView.bounds, from: scroll.contentView)
            let row = table.row(at: NSPoint(x: visible.midX, y: visible.minY + 1))
            let index = row - rowOffset
            guard entries.indices.contains(index) else { return nil }
            let rect = table.rect(ofRow: row)
            let entry = entries[index]
            return .init(rowID: entry.id, messageID: entry.message.id,
                         offset: Double(visible.minY - rect.minY), rowHeight: Double(rect.height),
                         contentWidth: Double(visible.width), toolDetails: entry.toolGroupID != nil)
        }
        func restore(_ anchor: TranscriptAnchor) -> Bool {
            guard let table, let scroll, let index = entries.firstIndex(where: { $0.id == anchor.rowID }),
                  table.numberOfRows >= entries.count + rowOffset else { return false }
            table.layoutSubtreeIfNeeded()
            let rect = table.rect(ofRow: index + rowOffset)
            let visible = table.convert(scroll.contentView.bounds, from: scroll.contentView)
            let reflowed = abs(Double(visible.width) - anchor.contentWidth) > 2 || abs(Double(rect.height) - anchor.rowHeight) > 2
            let offset = reflowed && anchor.rowHeight > 0 ? anchor.offset / anchor.rowHeight * Double(rect.height) : anchor.offset
            let target = table.convert(NSPoint(x: visible.minX, y: rect.minY + max(-8, min(rect.height - 1, offset))), to: scroll.documentView)
            let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            let y = max(0, min(maxY, target.y))
            let settled = abs(scroll.contentView.bounds.minY - y) < 0.75
            if !settled {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            return settled
        }
        func detach() {
            idleWork?.cancel(); idleWork = nil
            if let observation { NotificationCenter.default.removeObserver(observation) }
            liveObservations.forEach { NotificationCenter.default.removeObserver($0) }; liveObservations = []
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }; wheelMonitor = nil
            wheelEnd?.cancel(); wheelEnd = nil; userScrolling = false
            observation = nil; scroll = nil; table = nil; last = nil; lastTurnID = nil
            topArmed = true
        }
        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            liveObservations.forEach { NotificationCenter.default.removeObserver($0) }
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            idleWork?.cancel(); wheelEnd?.cancel()
        }
    }
}
