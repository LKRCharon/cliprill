// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import CliprillCore

final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class ActionButton: NSButton {
    var handler: (() -> Void)?
    convenience init(symbol: String, help: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        imagePosition = .imageOnly; bezelStyle = .accessoryBarAction; isBordered = false
        toolTip = help; setAccessibilityLabel(help)
        self.handler = handler; target = self; action = #selector(run)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    @objc private func run() { handler?() }
}
private final class ClipRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.16 : 0.11).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
}
private final class ClipCell: NSTableCellView {
    let primary = NSTextField(labelWithString: "")
    let secondary = NSTextField(labelWithString: "")
    let number = NSTextField(labelWithString: "")
    var trailing: ActionButton?
    init(title: String, detail: String, position: String, next: Bool, add: (() -> Void)?) {
        super.init(frame: .zero)
        primary.stringValue = title.isEmpty ? L("empty.text") : title
        primary.font = .systemFont(ofSize: 13, weight: next ? .medium : .regular)
        secondary.stringValue = detail; secondary.font = .systemFont(ofSize: 11); secondary.textColor = .secondaryLabelColor
        number.stringValue = position; number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        number.textColor = next ? .systemTeal : .tertiaryLabelColor; number.alignment = .center
        for label in [primary, secondary, number] { label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1; label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label) }
        let icon = NSImageView(image: NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)!)
        icon.contentTintColor = .tertiaryLabelColor; icon.translatesAutoresizingMaskIntoConstraints = false
        if position.isEmpty { addSubview(icon) }
        let leading = position.isEmpty ? 36.0 : 38.0
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), number.widthAnchor.constraint(equalToConstant: 26), number.centerYAnchor.constraint(equalTo: centerYAnchor),
            primary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading), primary.topAnchor.constraint(equalTo: topAnchor, constant: 7), primary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: add == nil ? -10 : -38),
            secondary.leadingAnchor.constraint(equalTo: primary.leadingAnchor), secondary.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: 3), secondary.trailingAnchor.constraint(equalTo: primary.trailingAnchor)
        ])
        if position.isEmpty { NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), icon.widthAnchor.constraint(equalToConstant: 15), icon.centerYAnchor.constraint(equalTo: centerYAnchor)]) }
        if let add {
            let button = ActionButton(symbol: "plus", help: L("add.queue"), handler: add)
            button.contentTintColor = .secondaryLabelColor; addSubview(button); trailing = button
            NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), button.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        setAccessibilityLabel([position, title, detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class PanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    unowned let appDelegate: AppDelegate
    private let search = NSSearchField()
    private let tabs = NSSegmentedControl(labels: [L("history"), L("queue")], trackingMode: .selectOne, target: nil, action: nil)
    private let selector = NSPopUpButton()
    private var selectorRow: NSStackView!
    private var queueMenuButton: ActionButton!
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSButton()
    private let count = NSTextField(labelWithString: "")
    private var up: ActionButton!
    private var down: ActionButton!
    private var remove: ActionButton!
    private var undo: ActionButton!
    private var append: ActionButton!
    private var preview: NSPopover?
    private var editor: ImportController?
    private var monitor: Any?
    private var globalMonitor: Any?
    private var messageUntil = Date.distantPast
    private var queues: [ClipQueue] = []
    private var history: [HistoryItem] = []
    private var queueRows: [QueueItem] = []
    private var historyRows: [HistoryItem] = []
    var selectedQueueID: String?
    private var currentQueue: ClipQueue? { queues.first { $0.id == selectedQueueID } }
    private var inQueue: Bool { tabs.selectedSegment == 1 }

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let panel = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 552), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Cliprill"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        super.init(window: panel); panel.delegate = self
        build()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true, self.editor == nil else { return event }
            if (self.search.currentEditor() as? NSTextView)?.hasMarkedText() == true { return event }
            switch event.keyCode {
            case 53: if self.preview?.isShown == true { self.preview?.close() } else { self.window?.orderOut(nil) }; return nil
            case 125: self.select(delta: 1); return nil
            case 126: self.select(delta: -1); return nil
            case 36, 76: if event.modifierFlags.contains(.option) { self.enqueueSelected() } else { self.openSelected() }; return nil
            default: return event
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.editor == nil, self.preview?.isShown != true else { return }
            self.window?.orderOut(nil)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) }; if let globalMonitor { NSEvent.removeMonitor(globalMonitor) } }

    private func build() {
        guard let window else { return }
        let root = NSVisualEffectView(); root.material = .popover; root.blendingMode = .behindWindow; root.state = .active
        root.wantsLayer = true; root.layer?.cornerRadius = 12; root.layer?.masksToBounds = true
        window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)])
        let mark = NSImageView(image: NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: nil)!)
        mark.contentTintColor = .systemTeal
        let name = NSTextField(labelWithString: "Cliprill"); name.font = .systemFont(ofSize: 13, weight: .semibold)
        let add = ActionButton(symbol: "plus", help: L("new.queue")) { [weak self] in self?.showImport(append: false) }
        let settings = ActionButton(symbol: "slider.horizontal.3", help: L("settings")) { [weak self] in self?.appDelegate.showSettings() }
        let close = ActionButton(symbol: "xmark", help: L("close")) { [weak self] in self?.window?.orderOut(nil) }
        let title = row([mark, name, NSView(), add, settings, close]); title.spacing = 6
        stack.addArrangedSubview(title)
        search.placeholderString = L("search.placeholder"); search.font = .systemFont(ofSize: 13)
        search.delegate = self; search.sendsSearchStringImmediately = true; search.focusRingType = .none
        search.heightAnchor.constraint(equalToConstant: 30).isActive = true
        stack.addArrangedSubview(search)
        tabs.selectedSegment = 0; tabs.segmentStyle = .separated; tabs.target = self; tabs.action = #selector(tabChanged)
        tabs.setWidth(100, forSegment: 0); tabs.setWidth(100, forSegment: 1)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); count.textColor = .secondaryLabelColor
        stack.addArrangedSubview(row([tabs, NSView(), count]))
        selector.bezelStyle = .accessoryBar; selector.controlSize = .small
        selector.target = self; selector.action = #selector(queueChanged); selector.setAccessibilityLabel(L("choose.queue"))
        queueMenuButton = ActionButton(symbol: "ellipsis", help: L("queue.actions")) { [weak self] in self?.showQueueMenu() }
        selectorRow = row([selector, queueMenuButton]); selectorRow.spacing = 4
        stack.addArrangedSubview(selectorRow)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 48; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.style = .plain; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.allowsEmptySelection = true; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel(L("clipboard.items"))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        let listContainer = NSView(); listContainer.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; listContainer.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor), scroll.topAnchor.constraint(equalTo: listContainer.topAnchor), scroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor)])
        emptyTitle.font = .systemFont(ofSize: 14, weight: .medium); emptyDetail.font = .systemFont(ofSize: 12); emptyDetail.textColor = .secondaryLabelColor
        let empty = NSStackView(views: [emptyTitle, emptyDetail]); empty.orientation = .vertical; empty.alignment = .centerX; empty.spacing = 6; empty.translatesAutoresizingMaskIntoConstraints = false
        emptyDetail.alignment = .center; listContainer.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor), empty.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor, constant: -20), empty.widthAnchor.constraint(lessThanOrEqualToConstant: 280)])
        stack.addArrangedSubview(listContainer)
        let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
        up = ActionButton(symbol: "arrow.up", help: L("move.up")) { [weak self] in self?.move(-1) }
        down = ActionButton(symbol: "arrow.down", help: L("move.down")) { [weak self] in self?.move(1) }
        remove = ActionButton(symbol: "trash", help: L("remove")) { [weak self] in self?.removeSelected() }
        undo = ActionButton(symbol: "arrow.uturn.backward", help: L("undo.dequeue")) { [weak self] in self?.queueAction("queue_undo_last") }
        append = ActionButton(symbol: "text.badge.plus", help: L("append.text")) { [weak self] in self?.showImport(append: true) }
        let inspect = ActionButton(symbol: "sidebar.right", help: L("preview")) { [weak self] in self?.showPreview() }
        toggle.title = L("start"); toggle.bezelStyle = .rounded; toggle.controlSize = .small; toggle.target = self; toggle.action = #selector(toggleQueue)
        let actions = row([up, down, remove, undo, append, inspect, NSView(), toggle]); actions.spacing = 3; stack.addArrangedSubview(actions)
        stateLabel.font = .systemFont(ofSize: 11); stateLabel.textColor = .secondaryLabelColor; stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true; stack.addArrangedSubview(stateLabel)
        for child in stack.arrangedSubviews { child.translatesAutoresizingMaskIntoConstraints = false; child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        return row
    }
    func showNearPointer() {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main!
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(420, visible.width), height: min(552, visible.height))
        // The first row, rather than the window edge, is placed close to the pointer.
        let x = min(max(pointer.x - 44, visible.minX), visible.maxX - size.width)
        let y = min(max(pointer.y - size.height + 152, visible.minY), visible.maxY - size.height)
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(search)
    }
    func reload(_ value: CoreState) {
        queues = value.queues; history = value.history
        if !queues.contains(where: { $0.id == selectedQueueID }) { selectedQueueID = value.activeID ?? queues.first?.id }
        selector.removeAllItems()
        if queues.isEmpty { selector.addItem(withTitle: L("no.queue")) }
        else {
            for q in queues { selector.addItem(withTitle: "\(q.title)  ·  \(q.remaining)"); selector.lastItem?.representedObject = q.id }
            if let i = queues.firstIndex(where: { $0.id == selectedQueueID }) { selector.selectItem(at: i) }
        }
        reloadRows()
    }
    private func reloadRows() {
        let selectedID: String? = inQueue ? queueRows[safe: table.selectedRow]?.id : historyRows[safe: table.selectedRow]?.id
        let query = search.stringValue
        historyRows = history.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        queueRows = Array((currentQueue?.items ?? []).dropFirst(currentQueue?.cursor ?? 0)).filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.label.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        let rowCount = inQueue ? queueRows.count : historyRows.count
        let selected = inQueue ? queueRows.firstIndex(where: { $0.id == selectedID }) : historyRows.firstIndex(where: { $0.id == selectedID })
        if rowCount > 0 { table.selectRowIndexes(IndexSet(integer: selected ?? 0), byExtendingSelection: false) }
        emptyTitle.isHidden = rowCount != 0; emptyDetail.isHidden = rowCount != 0
        if !query.isEmpty { emptyTitle.stringValue = L("no.matches"); emptyDetail.stringValue = "" }
        else if inQueue {
            emptyTitle.stringValue = currentQueue?.status == .completed ? L("queue.complete") : L("queue.empty")
            emptyDetail.stringValue = L("queue.empty.detail")
        } else { emptyTitle.stringValue = L("history.empty"); emptyDetail.stringValue = L("history.empty.detail") }
        selectorRow.isHidden = !inQueue; selector.isEnabled = !queues.isEmpty; queueMenuButton.isEnabled = !queues.isEmpty
        count.stringValue = inQueue ? "\(currentQueue?.remaining ?? 0) / \(currentQueue?.items.count ?? 0)" : "\(historyRows.count)"
        toggle.isHidden = !inQueue; toggle.title = currentQueue?.status == .active ? L("pause") : L("start")
        toggle.isEnabled = (currentQueue?.remaining ?? 0) > 0
        for button in [up, down, undo, append] { button?.isHidden = !inQueue }
        updateActions()
        if Date() >= messageUntil { updateStatus() }
    }
    private func updateStatus() {
        stateLabel.textColor = .secondaryLabelColor
        if inQueue, let q = currentQueue {
            if q.status == .active { stateLabel.stringValue = L("status.active"); stateLabel.textColor = .systemTeal }
            else if q.pauseReason == "external_copy" { stateLabel.stringValue = L("copied.paused") }
            else if q.pauseReason == "app_restarted" { stateLabel.stringValue = L("status.recovered") }
            else if q.status == .completed { stateLabel.stringValue = L("status.complete") }
            else { stateLabel.stringValue = appDelegate.coordinator.hasPermission ? L("status.paused") : L("permission.required") }
        } else { stateLabel.stringValue = L("status.history") }
        stateLabel.toolTip = stateLabel.stringValue
    }
    func showMessage(_ text: String) {
        messageUntil = Date().addingTimeInterval(4)
        stateLabel.stringValue = text; stateLabel.toolTip = text; stateLabel.textColor = .secondaryLabelColor
        Task { try? await Task.sleep(nanoseconds: 4_100_000_000); if Date() >= messageUntil { updateStatus() } }
    }
    func controlTextDidChange(_ obj: Notification) { reloadRows() }
    @objc private func tabChanged() { search.stringValue = ""; reloadRows(); window?.makeFirstResponder(search) }
    @objc private func queueChanged() { selectedQueueID = selector.selectedItem?.representedObject as? String; reloadRows() }
    func numberOfRows(in tableView: NSTableView) -> Int { inQueue ? queueRows.count : historyRows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClipRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if inQueue, let item = queueRows[safe: row], let q = currentQueue {
            let index = q.items.firstIndex { $0.id == item.id } ?? 0
            let detail = item.label.isEmpty ? "\(item.text.count) \(L("characters"))" : item.label
            return ClipCell(title: compact(item.text), detail: index == q.cursor ? L("next") + "  ·  " + detail : detail, position: String(index + 1), next: index == q.cursor, add: nil)
        }
        guard let item = historyRows[safe: row] else { return nil }
        let date = RelativeDateTimeFormatter().localizedString(for: item.copiedAt, relativeTo: Date())
        return ClipCell(title: compact(item.text), detail: [item.source, date].filter { !$0.isEmpty }.joined(separator: "  ·  "), position: "", next: false) { [weak self] in self?.enqueue(item.text) }
    }
    private func compact(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: " ↵ ").replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\t", with: "  ") }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    private func updateActions() {
        let index = table.selectedRow
        up?.isEnabled = inQueue && index > 0 && search.stringValue.isEmpty
        down?.isEnabled = inQueue && index >= 0 && index + 1 < queueRows.count && search.stringValue.isEmpty
        remove?.isEnabled = index >= 0
        undo?.isEnabled = (currentQueue?.cursor ?? 0) > 0
        append?.isEnabled = currentQueue != nil
    }
    private func select(delta: Int) {
        let count = table.numberOfRows; guard count > 0 else { return }
        let next = min(max(0, table.selectedRow + delta), count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next)
    }
    @objc private func toggleQueue() { queueAction(currentQueue?.status == .active ? "queue_pause" : "queue_activate") }
    private func queueAction(_ method: String) {
        guard let q = currentQueue else { return }
        run {
            _ = try await self.appDelegate.perform(method, ["queue_id": .string(q.id), "expected_revision": .integer(q.revision)])
            if method == "queue_activate" { self.window?.orderOut(nil) }
        }
    }
    private func run(_ body: @escaping () async throws -> Void) {
        Task { do { try await body() } catch { showMessage(error.localizedDescription); if (error as? CoreError)?.code == "accessibility_required" { appDelegate.showSettings() } } }
    }
    @objc private func openSelected() {
        if inQueue { showPreview(); return }
        guard let item = historyRows[safe: table.selectedRow] else { return }
        run {
            try self.appDelegate.coordinator.ensureTap()
            self.window?.orderOut(nil)
            try await self.appDelegate.coordinator.pasteHistory(item.text, target: self.appDelegate.target)
        }
    }
    private func enqueueSelected() { if let item = historyRows[safe: table.selectedRow], !inQueue { enqueue(item.text) } }
    private func enqueue(_ text: String) {
        let q = currentQueue
        run {
            var args: [String: JSONValue] = ["items": .array([.object(["text": .string(text)])])]
            if let q { args["queue_id"] = .string(q.id) } else { args["title"] = .string(L("queue.untitled")) }
            let result = try await self.appDelegate.perform(q == nil ? "queue_create" : "queue_append", args)
            self.selectedQueueID = result["queue_id"].string
            self.showMessage(L("added.queue")); await self.appDelegate.refresh()
        }
    }
    private func move(_ delta: Int) {
        guard let q = currentQueue, search.stringValue.isEmpty else { return }
        let i = table.selectedRow; guard queueRows.indices.contains(i), queueRows.indices.contains(i + delta) else { return }
        var order = queueRows.map(\.id); order.swapAt(i, i + delta)
        run { _ = try await self.appDelegate.perform("queue_reorder", ["queue_id": .string(q.id), "item_ids": .array(order.map(JSONValue.string)), "expected_revision": .integer(q.revision)]) }
    }
    private func removeSelected() {
        if inQueue, let q = currentQueue, let item = queueRows[safe: table.selectedRow] {
            run { _ = try await self.appDelegate.perform("queue_remove", ["queue_id": .string(q.id), "item_id": .string(item.id), "expected_revision": .integer(q.revision)]) }
        } else if !inQueue, let item = historyRows[safe: table.selectedRow] {
            run { _ = try await self.appDelegate.perform("history_delete", ["item_id": .string(item.id)]) }
        }
    }
    private func showPreview() {
        let text = inQueue ? queueRows[safe: table.selectedRow]?.text : historyRows[safe: table.selectedRow]?.text
        guard let text else { return }
        let vc = NSViewController(); let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 320)); scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds); view.string = text; view.isEditable = false; view.isSelectable = true; view.font = .systemFont(ofSize: 13); view.textContainerInset = NSSize(width: 14, height: 14)
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.isVerticallyResizable = true
        scroll.documentView = view; vc.view = scroll
        let popover = NSPopover(); popover.contentViewController = vc; popover.behavior = .semitransient; popover.contentSize = scroll.frame.size
        preview?.close(); preview = popover; popover.show(relativeTo: table.rect(ofRow: table.selectedRow), of: table, preferredEdge: .maxX)
    }
    private func showImport(append: Bool) {
        guard let window, editor == nil else { return }
        let destination = append ? currentQueue : nil
        let controller = ImportController(queue: destination) { [weak self] title, texts in
            guard let self else { return }
            var args: [String: JSONValue] = ["items": .array(texts.map { .object(["text": .string($0)]) })]
            if let destination { args["queue_id"] = .string(destination.id) } else { args["title"] = .string(title) }
            let result = try await self.appDelegate.perform(destination == nil ? "queue_create" : "queue_append", args)
            self.selectedQueueID = result["queue_id"].string; self.tabs.selectedSegment = 1; self.search.stringValue = ""; await self.appDelegate.refresh()
        }
        editor = controller
        window.beginSheet(controller.window!) { [weak self] _ in self?.editor = nil; self?.window?.makeFirstResponder(self?.search) }
    }
    private func showQueueMenu() {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: L("delete.queue"), action: #selector(deleteQueue), keyEquivalent: "")
        item.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: queueMenuButton.bounds.maxY), in: queueMenuButton)
    }
    @objc private func deleteQueue() {
        guard let q = currentQueue, let window else { return }
        let alert = NSAlert(); alert.messageText = L("delete.queue"); alert.informativeText = q.title + "\n" + L("delete.queue.detail")
        alert.addButton(withTitle: L("delete")); alert.addButton(withTitle: L("cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.run { _ = try await self.appDelegate.perform("queue_delete", ["queue_id": .string(q.id), "expected_revision": .integer(q.revision)]) }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
