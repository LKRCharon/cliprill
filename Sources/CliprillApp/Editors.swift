// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import ServiceManagement
import ApplicationServices
import KeyboardShortcuts
import CliprillCore

@MainActor
final class ImportController: NSWindowController {
    private let titleField = NSTextField()
    private let textView = NSTextView()
    private let mode = NSSegmentedControl(labels: [L("whole.text"), L("split.lines")], trackingMode: .selectOne, target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var submit: NSButton!
    private let save: (String, [String]) async throws -> Void
    init(queue: ClipQueue?, save: @escaping (String, [String]) async throws -> Void) {
        self.save = save
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 410), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = queue == nil ? L("new.queue") : L("append.text")
        window.backgroundColor = CliprillAppearance.windowBackground
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        let root = SurfaceView(); window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)])
        titleField.placeholderString = L("queue.title"); titleField.stringValue = queue?.title ?? L("queue.untitled"); titleField.isEnabled = queue == nil
        titleField.font = CliprillAppearance.font(14); titleField.isBezeled = false
        titleField.drawsBackground = false; titleField.setAccessibilityLabel(L("queue.title"))
        let titleSurface = SurfaceView(radius: 8); titleSurface.surfaceColor = CliprillAppearance.input
        titleField.translatesAutoresizingMaskIntoConstraints = false; titleSurface.addSubview(titleField)
        NSLayoutConstraint.activate([titleField.leadingAnchor.constraint(equalTo: titleSurface.leadingAnchor, constant: 10), titleField.trailingAnchor.constraint(equalTo: titleSurface.trailingAnchor, constant: -10), titleField.centerYAnchor.constraint(equalTo: titleSurface.centerYAnchor), titleSurface.heightAnchor.constraint(equalToConstant: 36)])
        stack.addArrangedSubview(titleSurface)
        mode.selectedSegment = 0; mode.segmentStyle = .roundRect; stack.addArrangedSubview(mode)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10; scroll.layer?.cornerCurve = .continuous
        textView.font = CliprillAppearance.font(14); textView.backgroundColor = CliprillAppearance.input; textView.textColor = CliprillAppearance.ink; textView.isRichText = false; textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12); textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true; scroll.documentView = textView
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        stack.addArrangedSubview(scroll)
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed; stack.addArrangedSubview(errorLabel)
        let cancel = ActionButton(title: L("cancel")) { [weak self] in self?.cancel() }; cancel.keyEquivalent = "\u{1b}"
        submit = ActionButton(title: L("add.queue"), style: .prominent) { [weak self] in self?.add() }; submit.keyEquivalent = "\r"; submit.keyEquivalentModifierMask = [.command]
        let actions = NSStackView(views: [NSView(), cancel, submit]); actions.spacing = 8; stack.addArrangedSubview(actions)
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.initialFirstResponder = textView
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func cancel() { if let window { window.sheetParent?.endSheet(window) } }
    @objc private func add() {
        let text = textView.string
        guard !text.isEmpty else { errorLabel.stringValue = L("enter.text"); return }
        let values: [String]
        if mode.selectedSegment == 1 {
            // Keep deliberate blank lines; only normalize line separators.
            values = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        } else { values = [text] }
        submit.isEnabled = false
        Task {
            do { try await save(titleField.stringValue, values); cancel() }
            catch { errorLabel.stringValue = error.localizedDescription; submit.isEnabled = true }
        }
    }
}

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate {
    unowned let appDelegate: AppDelegate
    private let permission = NSTextField(labelWithString: "")
    private let capture = NSButton(checkboxWithTitle: L("capture.history"), target: nil, action: nil)
    private let images = NSButton(checkboxWithTitle: L("settings.images"), target: nil, action: nil)
    private let autoDeleteQueues = NSButton(checkboxWithTitle: L("settings.queue.cleanup"), target: nil, action: nil)
    private let previews = NSButton(checkboxWithTitle: L("settings.previews"), target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: L("settings.login"), target: nil, action: nil)
    private let automaticPreview = NSButton(checkboxWithTitle: L("settings.preview.automatic"), target: nil, action: nil)
    private let showSourceApps = NSButton(checkboxWithTitle: L("settings.source.apps"), target: nil, action: nil)
    private let pasteMovesToTop = NSButton(checkboxWithTitle: L("settings.paste.top"), target: nil, action: nil)
    private let previewDelay = NSPopUpButton()
    private let speed = NSPopUpButton()
    private let capacity = NSPopUpButton()
    private let retention = NSPopUpButton()
    private let excluded = NSTextView()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cliprill · " + L("settings"); window.isReleasedWhenClosed = false
        window.backgroundColor = CliprillAppearance.windowBackground
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        window.contentView = scroll
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 460, height: 740))
        root.autoresizingMask = [.width]; scroll.documentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20)])

        window.delegate = self
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleCliprill)
        let historyRecorder = KeyboardShortcuts.RecorderCocoa(for: .openHistory)
        stack.addArrangedSubview(section(L("settings.general"), views: [row(L("history.shortcut"), historyRecorder), row(L("queue.shortcut"), recorder), row(L("board.shortcut"), KeyboardShortcuts.RecorderCocoa(for: .openBoards))]))
        images.state = UserDefaults.standard.bool(forKey: "captureImages") ? .on : .off
        previews.state = UserDefaults.standard.bool(forKey: "boardPreviews") ? .on : .off
        automaticPreview.state = UserDefaults.standard.bool(forKey: "automaticPreview") ? .on : .off
        showSourceApps.state = UserDefaults.standard.bool(forKey: "showSourceApps") ? .on : .off
        pasteMovesToTop.state = UserDefaults.standard.bool(forKey: "pasteMovesToTop") ? .on : .off
        for delay in [0.2, 0.3, 0.5, 0.8, 1.0, 2.0] {
            previewDelay.addItem(withTitle: String(format: "%.1f s", delay))
            previewDelay.lastItem?.representedObject = delay
            if abs(UserDefaults.standard.double(forKey: "previewDelay") - delay) < 0.001 {
                previewDelay.selectItem(at: previewDelay.numberOfItems - 1)
            }
        }
        previewDelay.isEnabled = automaticPreview.state == .on
        previewDelay.target = self; previewDelay.action = #selector(savePreferences)
        for button in [images, previews, automaticPreview, pasteMovesToTop, showSourceApps] { button.target = self; button.action = #selector(savePreferences) }
        for value in ["fast", "balanced", "low"] {
            speed.addItem(withTitle: L("speed." + value)); speed.lastItem?.representedObject = value
            if UserDefaults.standard.string(forKey: "captureSpeed") == value { speed.selectItem(at: speed.numberOfItems - 1) }
        }
        speed.target = self; speed.action = #selector(savePreferences)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self; login.action = #selector(changeLogin)
        stack.addArrangedSubview(section(L("settings.behavior"), views: [login, automaticPreview, row(L("settings.preview.delay"), previewDelay), previews, row(L("settings.speed"), speed)]))
        autoDeleteQueues.state = UserDefaults.standard.bool(forKey: "autoDeleteEmptyQueues") ? .on : .off
        autoDeleteQueues.target = self; autoDeleteQueues.action = #selector(changeQueueCleanup)
        autoDeleteQueues.toolTip = L("settings.queue.cleanup.hint")
        stack.addArrangedSubview(section(L("queue"), views: [autoDeleteQueues]))
        capture.state = UserDefaults.standard.bool(forKey: "captureEnabled") ? .on : .off; capture.target = self; capture.action = #selector(savePreferences)
        capture.font = CliprillAppearance.font(13)
        for n in [100, 500, 1000, 2000] { capacity.addItem(withTitle: String(n)); capacity.lastItem?.tag = n }
        capacity.selectItem(withTag: UserDefaults.standard.integer(forKey: "historyCapacity")); capacity.target = self; capacity.action = #selector(savePreferences)
        for n in [1, 7, 30, 90] { retention.addItem(withTitle: "\(n) " + L("days")); retention.lastItem?.tag = n }
        retention.selectItem(withTag: UserDefaults.standard.integer(forKey: "retentionDays")); retention.target = self; retention.action = #selector(savePreferences)

        let excludedScroll = NSScrollView(); excludedScroll.hasVerticalScroller = true; excludedScroll.borderType = .noBorder
        excludedScroll.wantsLayer = true; excludedScroll.layer?.cornerRadius = 8; excludedScroll.layer?.cornerCurve = .continuous
        excluded.isRichText = false; excluded.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        excluded.backgroundColor = CliprillAppearance.input; excluded.textColor = CliprillAppearance.ink
        excluded.textContainerInset = NSSize(width: 10, height: 10)
        excluded.autoresizingMask = [.width]; excluded.textContainer?.widthTracksTextView = true; excluded.isVerticallyResizable = true
        excluded.string = UserDefaults.standard.string(forKey: "excludedApps") ?? "com.1password.1password\ncom.agilebits.onepassword7\ncom.apple.keychainaccess"
        excluded.setAccessibilityLabel(L("excluded.apps"))
        excludedScroll.documentView = excluded; excludedScroll.heightAnchor.constraint(equalToConstant: 78).isActive = true
        let save = ActionButton(title: L("save.exclusions")) { [weak self] in self?.savePreferences() }
        let clear = ActionButton(title: L("clear.history"), icon: .trash) { [weak self] in self?.clearHistory() }
        let exclusions = NSStackView(views: [excludedScroll, save])
        exclusions.orientation = .vertical; exclusions.alignment = .leading; exclusions.spacing = 8
        excludedScroll.widthAnchor.constraint(equalTo: exclusions.widthAnchor).isActive = true
        exclusions.isHidden = true
        let disclose = ActionButton(title: L("excluded.apps")) { [weak exclusions, weak root, weak stack] in
            guard let exclusions, let root, let stack else { return }
            exclusions.isHidden.toggle()
            root.layoutSubtreeIfNeeded()
            root.setFrameSize(NSSize(width: root.frame.width, height: max(640, stack.fittingSize.height + 44)))
        }
        stack.addArrangedSubview(section(L("history"), views: [
            capture, images, pasteMovesToTop, showSourceApps, row(L("history.limit"), capacity), row(L("history.retention"), retention),
            horizontalRow([disclose, NSView(), clear]), exclusions
        ]))
        permission.font = CliprillAppearance.font(13); permission.lineBreakMode = .byTruncatingTail
        let grant = ActionButton(title: L("permission.manage")) { [weak self] in self?.openPermission() }
        stack.addArrangedSubview(section(L("permission.title"), views: [horizontalRow([permission, NSView(), grant])]))
        let mcp = ActionButton(title: L("copy.mcp.config"), icon: .clipboard) { [weak self] in self?.copyMCP() }
        stack.addArrangedSubview(section(L("settings.integration"), views: [row(L("settings.mcp"), mcp)]))
        let version = bodyLabel("Cliprill 0.5.0 · AGPL-3.0-only", size: 12, secondary: true)
        stack.addArrangedSubview(version)
        feedback.font = CliprillAppearance.font(12); feedback.textColor = CliprillAppearance.secondary; stack.addArrangedSubview(feedback)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(NSSize(width: root.frame.width, height: max(640, stack.fittingSize.height + 44)))
        refreshPermission()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        timer?.tolerance = 0.4
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
    @objc private func changeLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                feedback.stringValue = L("settings.login.approval")
                SMAppService.openSystemSettingsLoginItems()
            } else { feedback.stringValue = L("saved") }
        } catch { feedback.stringValue = error.localizedDescription }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    private func section(_ title: String, views: [NSView]) -> NSView {
        let group = NSStackView()
        group.orientation = .vertical; group.alignment = .leading; group.spacing = 10
        let heading = bodyLabel(title, size: 13)
        heading.font = CliprillAppearance.font(13, weight: .semibold)
        heading.setContentHuggingPriority(.required, for: .horizontal)
        let rule = HairlineView()
        rule.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        let header = horizontalRow([heading, rule], spacing: 12)
        group.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true

        let content = NSStackView(views: views)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 8
        for view in views { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let inset = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        inset.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
            content.topAnchor.constraint(equalTo: inset.topAnchor),
            content.bottomAnchor.constraint(equalTo: inset.bottomAnchor)
        ])
        group.addArrangedSubview(inset)
        inset.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        horizontalRow([bodyLabel(title), NSView(), control])
    }
    func windowDidBecomeKey(_ notification: Notification) { refreshPermission() }
    func refreshPermission() {
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if login.state == .on && feedback.stringValue == L("settings.login.approval") { feedback.stringValue = L("saved") }
        permission.stringValue = appDelegate.coordinator.hasPermission ? L("permission.ready") : L("permission.missing")
        permission.textColor = CliprillAppearance.secondary
    }
    @objc private func changeQueueCleanup() {
        let enabled = autoDeleteQueues.state == .on
        autoDeleteQueues.isEnabled = false
        Task {
            defer { autoDeleteQueues.isEnabled = true }
            do {
                try await appDelegate.core.setAutoDeleteEmptyQueues(enabled)
                UserDefaults.standard.set(enabled, forKey: "autoDeleteEmptyQueues")
                await appDelegate.refresh(); feedback.stringValue = L("saved")
            } catch {
                autoDeleteQueues.state = UserDefaults.standard.bool(forKey: "autoDeleteEmptyQueues") ? .on : .off
                feedback.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(capture.state == .on, forKey: "captureEnabled"); defaults.set(capacity.selectedTag(), forKey: "historyCapacity"); defaults.set(retention.selectedTag(), forKey: "retentionDays"); defaults.set(excluded.string, forKey: "excludedApps")
        defaults.set(images.state == .on, forKey: "captureImages")
        defaults.set(showSourceApps.state == .on, forKey: "showSourceApps")
        defaults.set(pasteMovesToTop.state == .on, forKey: "pasteMovesToTop")
        defaults.set(previewDelay.selectedItem?.representedObject as? Double ?? 0.5, forKey: "previewDelay")
        previewDelay.isEnabled = automaticPreview.state == .on
        defaults.set(automaticPreview.state == .on, forKey: "automaticPreview")
        defaults.set(previews.state == .on, forKey: "boardPreviews")
        defaults.set(speed.selectedItem?.representedObject as? String ?? "balanced", forKey: "captureSpeed")
        appDelegate.coordinator.configurePolling()
        Task {
            do { try await appDelegate.core.pruneHistory(capacity: capacity.selectedTag(), retentionDays: retention.selectedTag()); await appDelegate.refresh(); feedback.stringValue = L("saved") }
            catch { feedback.stringValue = error.localizedDescription }
        }
    }
    @objc private func openPermission() { appDelegate.showPermissionGuide() }
    @objc private func copyMCP() {
        Task {
            await appDelegate.coordinator.pause(reason: "settings_copy")
            let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cliprill-mcp").path
            let value: [String: Any] = ["mcpServers": ["cliprill": ["command": path, "args": []]]]
            do {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try appDelegate.coordinator.write(String(decoding: data, as: UTF8.self)); feedback.stringValue = L("copied.config")
            } catch { feedback.stringValue = error.localizedDescription }
        }
    }
    @objc private func clearHistory() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = L("clear.history"); alert.informativeText = L("clear.history.detail")
        alert.addButton(withTitle: L("clear")); alert.addButton(withTitle: L("cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { do { _ = try await self.appDelegate.perform("history_clear"); self.feedback.stringValue = L("cleared") } catch { self.feedback.stringValue = error.localizedDescription } }
        }
    }
}
