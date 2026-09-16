// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import CliprillCore

final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
private final class PanelDragHandle: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
private final class ClipTable: NSTableView {
    var contextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return contextMenu?()
    }
}
private final class ClipRowView: NSTableRowView {
    private var hovering = false
    private var tracking: NSTrackingArea?
    override var isSelected: Bool { didSet { updateActions() } }
    override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); updateActions() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateActions() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateActions() }
    private func updateActions() {
        for cell in subviews.compactMap({ $0 as? ClipCell }) { cell.trailing?.isHidden = !(hovering || isSelected) }
        needsDisplay = true
    }
    override func drawBackground(in dirtyRect: NSRect) {
        if hovering && !isSelected {
            CliprillAppearance.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 10, yRadius: 10).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        CliprillAppearance.selection.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 10, yRadius: 10)
        path.fill()
        if CliprillAppearance.highContrast { CliprillAppearance.secondary.setStroke(); path.lineWidth = 1; path.stroke() }
    }
}
private final class ClipCell: NSTableCellView {
    var trailing: ActionButton?
    private let thumbnailView = NSImageView()
    func setThumbnail(_ image: NSImage) { thumbnailView.image = image }
    init(title: String, detail: String, position: String, next: Bool, image: ClipboardImage? = nil, add: (() -> Void)?) {
        super.init(frame: .zero)
        let primary = bodyLabel(title.isEmpty ? L("empty.text") : title, size: 14)
        let secondary = bodyLabel(detail, size: 12, secondary: true)
        for label in [primary, secondary] {
            label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        }
        let leading: NSView
        if image != nil && position.isEmpty {
            leading = thumbnailView
        } else if position.isEmpty {
            let icon = NSImageView(image: ClipIcon.text.image())
            icon.contentTintColor = CliprillAppearance.secondary; leading = icon
        } else {
            let number = bodyLabel(position, size: 12, secondary: true)
            number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            number.alignment = .center; leading = number
        }
        leading.translatesAutoresizingMaskIntoConstraints = false; addSubview(leading)
        if image != nil {
            thumbnailView.imageScaling = .scaleProportionallyUpOrDown
            thumbnailView.wantsLayer = true; thumbnailView.layer?.cornerRadius = 5
            thumbnailView.layer?.cornerCurve = .continuous; thumbnailView.layer?.masksToBounds = true
            thumbnailView.setAccessibilityLabel(L("image"))
            thumbnailView.translatesAutoresizingMaskIntoConstraints = false
            thumbnailView.heightAnchor.constraint(equalToConstant: 36).isActive = true
            if !position.isEmpty {
                addSubview(thumbnailView)
                NSLayoutConstraint.activate([thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36), thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor), thumbnailView.widthAnchor.constraint(equalToConstant: 36)])
            }
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leading.widthAnchor.constraint(equalToConstant: image != nil && position.isEmpty ? 36 : 20), leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            primary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: image == nil ? 40 : (position.isEmpty ? 58 : 84)),
            primary.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            primary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: next ? -64 : (add == nil ? -12 : -40)),
            secondary.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
            secondary.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: 3),
            secondary.trailingAnchor.constraint(equalTo: primary.trailingAnchor)
        ])
        if next {
            let badge = bodyLabel(L("next"), size: 11, secondary: true)
            badge.font = CliprillAppearance.font(11, weight: .medium)
            badge.translatesAutoresizingMaskIntoConstraints = false; addSubview(badge)
            NSLayoutConstraint.activate([badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), badge.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        if let add {
            let button = ActionButton(icon: .plus, help: L("add.queue"), handler: add)
            addSubview(button); trailing = button
            NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5), button.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        toolTip = [title, detail].joined(separator: "\n")
        setAccessibilityLabel([position, title, next ? L("next") : "", detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class PanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    unowned let appDelegate: AppDelegate
    private let searchSurface = SearchFieldView()
    private var search: NSSearchField { searchSurface.field }
    private let selector = NSPopUpButton()
    private let table = ClipTable()
    private let scroll = NSScrollView()
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyTitle = bodyLabel("", size: 14)
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private var historyTab: ActionButton!
    private var queueTab: ActionButton!
    private var more: ActionButton!
    private var toggle: ActionButton!
    private var emptyAction: ActionButton!
    private var preview: NSPopover?
    private var previewTask: Task<Void, Never>?
    private let thumbnails = NSCache<NSString, NSImage>()
    private var editor: ImportController?
    private var monitor: Any?
    private var globalMonitor: Any?
    private var modeTask: Task<Void, Never>?
    private var messageUntil = Date.distantPast
    private var queues: [ClipQueue] = []
    private var history: [HistoryItem] = []
    private var queueRows: [QueueItem] = []
    private var historyRows: [HistoryItem] = []
    var selectedQueueID: String?
    private var currentQueue: ClipQueue? { queues.first { $0.id == selectedQueueID } }
    private var inQueue = false

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let panel = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 356), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Cliprill"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        super.init(window: panel); panel.delegate = self
        thumbnails.countLimit = 128
        build()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true, self.editor == nil else { return event }
            if (self.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            if event.keyCode == 53 {
                if self.preview?.isShown == true { self.preview?.close() }
                else if !self.search.stringValue.isEmpty { self.clearSearch() }
                else { self.window?.orderOut(nil) }
                return nil
            }
            if flags == .command {
                switch event.charactersIgnoringModifiers {
                case "y": self.showPreview(); return nil
                case ",": self.appDelegate.showSettings(); return nil
                case "1": self.selectMode(queue: false); return nil
                case "2": self.selectMode(queue: true); return nil
                default: break
                }
            }
            let responder = self.window?.firstResponder
            if responder === self.historyTab || responder === self.queueTab {
                if flags.isEmpty && [123, 124].contains(event.keyCode) {
                    self.selectMode(queue: event.keyCode == 124); return nil
                }
                return event
            }
            let editingSearch = self.search.currentEditor() != nil && responder === self.search.currentEditor()
            guard responder === self.table || editingSearch else { return event }
            if flags.isEmpty {
                switch event.keyCode {
                case 125: self.select(delta: 1); return nil
                case 126: self.select(delta: -1); return nil
                case 36, 76: self.openSelected(); return nil
                case 49 where responder === self.table: self.showPreview(); return nil
                default: break
                }
            } else if flags == .option && [36, 76].contains(event.keyCode) {
                self.enqueueSelected(); return nil
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.editor == nil, self.preview?.isShown != true else { return }
            // Release the nonactivating panel's key status so the destination receives Cmd-V.
            self.window?.resignKey()
            if !self.inQueue { self.window?.orderOut(nil) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) }; if let globalMonitor { NSEvent.removeMonitor(globalMonitor) } }

    private func build() {
        guard let window else { return }
        let root = PanelSurfaceView(); window.contentView = root
        let drag = PanelDragHandle(); drag.toolTip = L("drag.panel")
        drag.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(drag)
        NSLayoutConstraint.activate([drag.leadingAnchor.constraint(equalTo: root.leadingAnchor), drag.trailingAnchor.constraint(equalTo: root.trailingAnchor), drag.topAnchor.constraint(equalTo: root.topAnchor), drag.heightAnchor.constraint(equalToConstant: 14)])
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)])

        search.delegate = self
        searchSurface.onClear = { [weak self] in self?.clearSearch() }
        more = ActionButton(icon: .more, help: L("actions")) { [weak self] in self?.showActions() }
        let searchRow = horizontalRow([searchSurface, more]); searchSurface.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(searchRow)

        historyTab = ActionButton(title: L("history")) { [weak self] in self?.selectMode(queue: false) }
        queueTab = ActionButton(title: L("queue")) { [weak self] in self?.selectMode(queue: true) }
        selector.isBordered = false; selector.font = CliprillAppearance.font(12); selector.contentTintColor = CliprillAppearance.secondary
        selector.lineBreakMode = .byTruncatingTail; selector.target = self; selector.action = #selector(queueChanged)
        selector.setAccessibilityLabel(L("choose.queue"))
        selector.widthAnchor.constraint(lessThanOrEqualToConstant: 168).isActive = true
        selector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(horizontalRow([historyTab, queueTab, NSView(), selector], spacing: 4))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = CliprillAppearance.rowHeight; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.style = .plain; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.allowsEmptySelection = true; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel(L("clipboard.items"))
        table.contextMenu = { [weak self] in self?.makeActionsMenu() ?? NSMenu() }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScroller = PanelScroller()
        // NSScrollView automatically follows subsequent system scroller-style changes.
        scroll.scrollerStyle = NSScroller.preferredScrollerStyle
        let list = NSView(); scroll.translatesAutoresizingMaskIntoConstraints = false; list.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor), scroll.topAnchor.constraint(equalTo: list.topAnchor), scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor), list.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)])
        emptyTitle.font = CliprillAppearance.font(14, weight: .medium)
        emptyDetail.font = CliprillAppearance.font(12); emptyDetail.textColor = CliprillAppearance.secondary; emptyDetail.alignment = .center
        emptyAction = ActionButton(title: L("new.queue"), icon: .plus) { [weak self] in self?.showImport(append: false) }
        let empty = NSStackView(views: [emptyTitle, emptyDetail, emptyAction]); empty.orientation = .vertical; empty.alignment = .centerX; empty.spacing = 8
        empty.translatesAutoresizingMaskIntoConstraints = false; list.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: list.centerXAnchor), empty.centerYAnchor.constraint(equalTo: list.centerYAnchor), empty.widthAnchor.constraint(lessThanOrEqualToConstant: 280)])
        stack.addArrangedSubview(list)
        stack.addArrangedSubview(HairlineView())
        stateLabel.font = CliprillAppearance.font(12); stateLabel.textColor = CliprillAppearance.secondary
        stateLabel.maximumNumberOfLines = 2; stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle = ActionButton(title: L("start")) { [weak self] in self?.footerAction() }
        let footer = horizontalRow([stateLabel, NSView(), toggle]); footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        stack.addArrangedSubview(footer)
        for child in stack.arrangedSubviews {
            child.translatesAutoresizingMaskIntoConstraints = false; child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        reloadRows()
    }
    private var desiredHeight: CGFloat {
        // Header, footer and gaps occupy 159 pt; allow whole 52 pt rows below them.
        min(552, max(300, 160 + CliprillAppearance.rowHeight * CGFloat(inQueue ? queueRows.count : historyRows.count)))
    }
    func showNearPointer() {
        guard let window, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let pointer = NSEvent.mouseLocation, visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(CliprillAppearance.panelWidth, visible.width), height: min(desiredHeight, visible.height))
        let x = min(max(pointer.x - 44, visible.minX), visible.maxX - size.width)
        let y = min(max(pointer.y - size.height + 116, visible.minY), visible.maxY - size.height)
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
        reveal()
    }
    private func reveal() { window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(search) }
    private func resizeForContents() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var frame = window.frame
        let height = min(desiredHeight, visible.height)
        frame.origin.y = min(max(frame.maxY - height, visible.minY), visible.maxY - height)
        frame.size.height = height
        window.setFrame(frame, display: window.isVisible)
    }
    func reload(_ value: CoreState) {
        queues = value.queues; history = value.history
        if !queues.contains(where: { $0.id == selectedQueueID }) { selectedQueueID = value.activeID ?? queues.first?.id }
        selector.removeAllItems()
        if queues.isEmpty { selector.addItem(withTitle: L("no.queue")) }
        else {
            for q in queues { selector.addItem(withTitle: q.title); selector.lastItem?.representedObject = q.id }
            if let i = queues.firstIndex(where: { $0.id == selectedQueueID }) { selector.selectItem(at: i) }
        }
        reloadRows()
    }
    private func reloadRows() {
        searchSurface.refresh()
        let selectedID = inQueue ? queueRows[safe: table.selectedRow]?.id : historyRows[safe: table.selectedRow]?.id
        let query = search.stringValue
        historyRows = history.filter { matches(text: $0.text, image: $0.image, query: query) || $0.source.localizedCaseInsensitiveContains(query) }
        queueRows = Array((currentQueue?.items ?? []).dropFirst(currentQueue?.cursor ?? 0)).filter {
            matches(text: $0.text, image: $0.image, query: query) || $0.label.localizedCaseInsensitiveContains(query)
        }
        table.reloadData()
        let rowCount = inQueue ? queueRows.count : historyRows.count
        let selected = inQueue ? queueRows.firstIndex(where: { $0.id == selectedID }) : historyRows.firstIndex(where: { $0.id == selectedID })
        if rowCount > 0 { table.selectRowIndexes(IndexSet(integer: selected ?? 0), byExtendingSelection: false) }
        emptyTitle.isHidden = rowCount != 0; emptyDetail.isHidden = rowCount != 0
        emptyAction.isHidden = rowCount != 0 || !inQueue || !query.isEmpty
        if !query.isEmpty { emptyTitle.stringValue = L("no.matches"); emptyDetail.stringValue = L("search.clear.hint") }
        else if inQueue {
            emptyTitle.stringValue = currentQueue?.status == .completed ? L("queue.complete") : L("queue.empty")
            emptyDetail.stringValue = L("queue.empty.detail")
        } else { emptyTitle.stringValue = L("history.empty"); emptyDetail.stringValue = L("history.empty.detail") }
        selector.isHidden = !inQueue; selector.isEnabled = !queues.isEmpty
        selector.toolTip = currentQueue?.title
        historyTab.state = inQueue ? .off : .on; queueTab.state = inQueue ? .on : .off
        queueTab.title = L("queue") + "  \(currentQueue?.remaining ?? 0)"
        if Date() >= messageUntil { updateStatus() }
        updateFooter()
    }
    private func updateFooter() {
        let q = currentQueue
        if !inQueue { toggle.title = L("actions"); toggle.image = nil; toggle.style = .plain }
        else if !appDelegate.coordinator.hasPermission && (q?.remaining ?? 0) > 0 {
            toggle.title = L("permission.enable"); toggle.image = nil; toggle.style = .prominent
        } else if q?.status == .active {
            toggle.title = L("pause"); toggle.image = ClipIcon.pause.image(); toggle.style = .plain
        } else if (q?.remaining ?? 0) > 0 {
            toggle.title = L("start"); toggle.image = ClipIcon.play.image(); toggle.style = .prominent
        } else if (q?.cursor ?? 0) > 0 {
            toggle.title = L("undo.dequeue.short"); toggle.image = ClipIcon.undo.image(); toggle.style = .plain
        } else { toggle.title = L("new.queue"); toggle.image = ClipIcon.plus.image(); toggle.style = .plain }
        toggle.imagePosition = toggle.image == nil ? .noImage : .imageLeading
        toggle.setAccessibilityLabel(toggle.title); toggle.toolTip = toggle.title
        toggle.invalidateIntrinsicContentSize()
    }
    private func updateStatus() {
        stateLabel.textColor = CliprillAppearance.secondary
        if inQueue, let q = currentQueue {
            let remaining = String(format: L("remaining.format"), q.remaining)
            if q.status == .active { stateLabel.stringValue = L("status.active") + " · " + remaining }
            else if q.pauseReason == "external_copy" { stateLabel.stringValue = L("copied.paused") }
            else if q.pauseReason == "app_restarted" { stateLabel.stringValue = L("status.recovered") + " · " + remaining }
            else if q.status == .completed { stateLabel.stringValue = L("status.complete") }
            else { stateLabel.stringValue = appDelegate.coordinator.hasPermission ? L("status.paused") + " · " + remaining : L("permission.required") }
        } else { stateLabel.stringValue = inQueue ? L("queue.empty.detail") : L("status.history") }
        stateLabel.toolTip = stateLabel.stringValue
    }
    func showMessage(_ text: String) {
        messageUntil = Date().addingTimeInterval(4)
        stateLabel.stringValue = text; stateLabel.toolTip = text
        Task { try? await Task.sleep(nanoseconds: 4_100_000_000); if Date() >= messageUntil { updateStatus() } }
    }
    func controlTextDidChange(_ obj: Notification) { reloadRows(); if search.stringValue.isEmpty { resizeForContents() } }
    func controlTextDidBeginEditing(_ obj: Notification) { searchSurface.needsDisplay = true }
    func controlTextDidEndEditing(_ obj: Notification) { searchSurface.needsDisplay = true }
    func windowDidBecomeKey(_ notification: Notification) { searchSurface.needsDisplay = true }
    func windowDidResignKey(_ notification: Notification) { searchSurface.needsDisplay = true }
    private func clearSearch() { search.stringValue = ""; reloadRows(); resizeForContents(); window?.makeFirstResponder(search) }
    private func selectMode(queue: Bool) {
        guard inQueue != queue else { return }
        inQueue = queue; clearSearch(); synchronizeQueueMode()
    }
    @objc private func queueChanged() {
        selectedQueueID = selector.selectedItem?.representedObject as? String
        clearSearch(); synchronizeQueueMode()
    }
    // Refreshes never restart manually paused or safety-paused queues.
    private func synchronizeQueueMode() {
        modeTask?.cancel()
        modeTask = Task {
            await appDelegate.coordinator.pause(reason: "view_changed")
            guard !Task.isCancelled, inQueue, let q = currentQueue, q.remaining > 0 else { return }
            await activate(q)
        }
    }
    private func activate(_ queue: ClipQueue) async {
        do {
            _ = try await appDelegate.perform("queue_activate", ["queue_id": .string(queue.id), "expected_revision": .integer(queue.revision)])
        } catch {
            showMessage(error.localizedDescription)
            if (error as? CoreError)?.code == "accessibility_required" { requestPermission(queueID: queue.id) }
        }
    }
    private func requestPermission(queueID: String? = nil) {
        appDelegate.showPermissionGuide { [weak self] in
            guard let self else { return }
            self.reveal()
            // Recheck navigation and use the current revision after returning from System Settings.
            if let queueID, self.inQueue, let q = self.currentQueue, q.id == queueID, q.remaining > 0 {
                self.modeTask?.cancel()
                self.modeTask = Task { await self.activate(q) }
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { inQueue ? queueRows.count : historyRows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClipRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if inQueue, let item = queueRows[safe: row], let q = currentQueue {
            let index = q.items.firstIndex { $0.id == item.id } ?? 0
            let detail = item.image.map(imageDetail) ?? "\(item.text.count) \(L("characters"))"
            let cell = ClipCell(title: item.image == nil ? compact(item.text) : (item.label.isEmpty ? L("image") : item.label),
                                detail: item.label.isEmpty || item.image != nil ? detail : item.label,
                                position: String(index + 1), next: index == q.cursor, image: item.image, add: nil)
            loadThumbnail(item.image, into: cell)
            return cell
        }
        guard let item = historyRows[safe: row] else { return nil }
        let date = RelativeDateTimeFormatter().localizedString(for: item.copiedAt, relativeTo: Date())
        let detail = [item.image.map(imageDetail) ?? "", item.source, date].filter { !$0.isEmpty }.joined(separator: " · ")
        let cell = ClipCell(title: item.image == nil ? compact(item.text) : L("image"), detail: detail,
                            position: "", next: false, image: item.image) { [weak self] in self?.enqueue(item) }
        loadThumbnail(item.image, into: cell)
        return cell
    }
    private func imageDetail(_ image: ClipboardImage) -> String {
        "\(image.width) × \(image.height) · " + ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file)
    }
    private func matches(text: String, image: ClipboardImage?, query: String) -> Bool {
        if query.isEmpty || text.localizedCaseInsensitiveContains(query) { return true }
        guard let image else { return false }
        return [L("image"), "image", "图片", "\(image.width) × \(image.height)"].contains { $0.localizedCaseInsensitiveContains(query) }
    }
    private func loadThumbnail(_ image: ClipboardImage?, into cell: ClipCell) {
        guard let image else { return }
        if let cached = thumbnails.object(forKey: image.id as NSString) { cell.setThumbnail(cached); return }
        Task { [weak cell] in
            guard let data = try? await appDelegate.core.imageData(image, thumbnail: true), let thumbnail = NSImage(data: data) else { return }
            thumbnails.setObject(thumbnail, forKey: image.id as NSString)
            cell?.setThumbnail(thumbnail)
        }
    }
    private func compact(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: " ↵ ").replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\t", with: "  ") }
    private func select(delta: Int) {
        let count = table.numberOfRows; guard count > 0 else { return }
        let next = min(max(0, table.selectedRow + delta), count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next)
    }
    private func footerAction() {
        if !inQueue { showActions(anchor: toggle) }
        else if (currentQueue?.remaining ?? 0) == 0 {
            if (currentQueue?.cursor ?? 0) > 0 { queueAction("queue_undo_last") }
            else { showImport(append: false) }
        } else if !appDelegate.coordinator.hasPermission { requestPermission(queueID: currentQueue?.id) }
        else { queueAction(currentQueue?.status == .active ? "queue_pause" : "queue_activate") }
    }
    private func queueAction(_ method: String) {
        guard let q = currentQueue else { return }
        if method == "queue_activate" {
            modeTask?.cancel(); modeTask = Task { await activate(q) }; return
        }
        run { _ = try await self.appDelegate.perform(method, ["queue_id": .string(q.id), "expected_revision": .integer(q.revision)]) }
    }
    private func run(_ body: @escaping () async throws -> Void) {
        Task { do { try await body() } catch {
            showMessage(error.localizedDescription)
            if (error as? CoreError)?.code == "accessibility_required" { requestPermission() }
        } }
    }
    @objc private func openSelected() {
        if inQueue { showPreview(); return }
        guard let item = historyRows[safe: table.selectedRow] else { return }
        run {
            try self.appDelegate.coordinator.ensureTap()
            self.window?.orderOut(nil)
            try await self.appDelegate.coordinator.pasteHistory(item, target: self.appDelegate.target)
        }
    }
    private func enqueueSelected() { if let item = historyRows[safe: table.selectedRow], !inQueue { enqueue(item) } }
    private func showActions(anchor: NSView? = nil) {
        let source = anchor ?? more!
        makeActionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: source.bounds.minY), in: source)
    }
    private func makeActionsMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ key: String, _ command: String, _ icon: ClipIcon, enabled: Bool = true, shortcut: String = "") {
            let item = menu.addItem(withTitle: L(key), action: #selector(menuAction(_:)), keyEquivalent: shortcut)
            item.target = self; item.representedObject = command; item.image = icon.image(); item.isEnabled = enabled
        }
        add("new.queue", "new", .plus)
        if inQueue { add("append.text", "append", .text, enabled: currentQueue != nil) }
        menu.addItem(.separator())
        add("preview", "preview", .preview, enabled: table.selectedRow >= 0, shortcut: "y")
        if !inQueue { add("add.queue", "enqueue", .plus, enabled: table.selectedRow >= 0) }
        else {
            add("move.up", "up", .up, enabled: table.selectedRow > 0 && search.stringValue.isEmpty)
            add("move.down", "down", .down, enabled: table.selectedRow >= 0 && table.selectedRow + 1 < queueRows.count && search.stringValue.isEmpty)
            add("undo.dequeue", "undo", .undo, enabled: (currentQueue?.cursor ?? 0) > 0)
        }
        add("remove", "remove", .trash, enabled: table.selectedRow >= 0)
        if inQueue { add("delete.queue", "delete", .trash, enabled: currentQueue != nil) }
        menu.addItem(.separator())
        add("settings", "settings", .settings, shortcut: ",")
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "new": showImport(append: false)
        case "append": showImport(append: true)
        case "preview": showPreview()
        case "enqueue": enqueueSelected()
        case "up": move(-1)
        case "down": move(1)
        case "remove": removeSelected()
        case "undo": queueAction("queue_undo_last")
        case "delete": deleteQueue()
        case "settings": appDelegate.showSettings()
        default: break
        }
    }
    private func enqueue(_ item: HistoryItem) {
        let q = currentQueue
        run {
            var args: [String: JSONValue] = ["items": .array([.object(["history_id": .string(item.id)])])]
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
        let row = table.selectedRow
        let text = inQueue ? queueRows[safe: row]?.text : historyRows[safe: row]?.text
        let image = inQueue ? queueRows[safe: row]?.image : historyRows[safe: row]?.image
        guard let text else { return }
        previewTask?.cancel(); preview?.close()
        let vc = NSViewController()
        let size = NSSize(width: image == nil ? 440 : 560, height: image == nil ? 320 : 400)
        if let image {
            let root = SurfaceView(); root.frame = NSRect(origin: .zero, size: size)
            let view = NSImageView(); view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityLabel(L("image") + " · " + imageDetail(image))
            let caption = bodyLabel(imageDetail(image), size: 12, secondary: true)
            for child in [view, caption] { child.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(child) }
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), view.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), view.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -12), caption.centerXAnchor.constraint(equalTo: root.centerXAnchor), caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)])
            vc.view = root
            previewTask = Task { [weak view] in
                do {
                    let data = try await appDelegate.core.imageData(image)
                    guard !Task.isCancelled else { return }
                    view?.image = NSImage(data: data)
                } catch { if !Task.isCancelled { showMessage(error.localizedDescription) } }
            }
        } else {
            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size)); scroll.hasVerticalScroller = true
            let view = NSTextView(frame: scroll.bounds); view.string = text; view.isEditable = false; view.isSelectable = true
            view.font = CliprillAppearance.font(14); view.backgroundColor = CliprillAppearance.windowBackground
            view.textColor = CliprillAppearance.ink; view.textContainerInset = NSSize(width: 14, height: 14)
            view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.isVerticallyResizable = true
            scroll.documentView = view; vc.view = scroll
        }
        let popover = NSPopover(); popover.contentViewController = vc; popover.behavior = .semitransient; popover.contentSize = size
        preview = popover; popover.show(relativeTo: table.rect(ofRow: row), of: table, preferredEdge: .maxX)
    }
    private func showImport(append: Bool) {
        guard let window, editor == nil else { return }
        let destination = append ? currentQueue : nil
        let controller = ImportController(queue: destination) { [weak self] title, texts in
            guard let self else { return }
            var args: [String: JSONValue] = ["items": .array(texts.map { .object(["text": .string($0)]) })]
            if let destination { args["queue_id"] = .string(destination.id) } else { args["title"] = .string(title) }
            let result = try await self.appDelegate.perform(destination == nil ? "queue_create" : "queue_append", args)
            self.selectedQueueID = result["queue_id"].string; self.inQueue = true; self.search.stringValue = ""; await self.appDelegate.refresh()
            self.resizeForContents()
            self.synchronizeQueueMode()
        }
        editor = controller
        window.beginSheet(controller.window!) { [weak self] _ in self?.editor = nil; self?.window?.makeFirstResponder(self?.search) }
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
