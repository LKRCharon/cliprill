// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
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
final class SettingsController: NSWindowController {
    unowned let appDelegate: AppDelegate
    private let permission = NSTextField(labelWithString: "")
    private let capture = NSButton(checkboxWithTitle: L("capture.history"), target: nil, action: nil)
    private let capacity = NSPopUpButton()
    private let retention = NSPopUpButton()
    private let excluded = NSTextView()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 536, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cliprill · " + L("settings"); window.isReleasedWhenClosed = false
        window.backgroundColor = CliprillAppearance.windowBackground
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        window.contentView = scroll
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 536, height: 740))
        root.autoresizingMask = [.width]; scroll.documentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20)])

        let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleCliprill)
        stack.addArrangedSubview(section(L("settings.general"), icon: .keyboard, views: [row(L("open.shortcut"), recorder)]))
        capture.state = UserDefaults.standard.bool(forKey: "captureEnabled") ? .on : .off; capture.target = self; capture.action = #selector(savePreferences)
        capture.font = CliprillAppearance.font(13)
        for n in [100, 500, 1000, 2000] { capacity.addItem(withTitle: String(n)); capacity.lastItem?.tag = n }
        capacity.selectItem(withTag: UserDefaults.standard.integer(forKey: "historyCapacity")); capacity.target = self; capacity.action = #selector(savePreferences)
        for n in [1, 7, 30, 90] { retention.addItem(withTitle: "\(n) " + L("days")); retention.lastItem?.tag = n }
        retention.selectItem(withTag: UserDefaults.standard.integer(forKey: "retentionDays")); retention.target = self; retention.action = #selector(savePreferences)
        let excludedLabel = bodyLabel(L("excluded.apps"), size: 12, secondary: true)
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
        stack.addArrangedSubview(section(L("history"), icon: .clipboard, views: [
            capture, row(L("history.limit"), capacity), row(L("history.retention"), retention),
            HairlineView(), excludedLabel, excludedScroll, horizontalRow([clear, NSView(), save])
        ]))
        permission.font = CliprillAppearance.font(13); permission.lineBreakMode = .byTruncatingTail
        let grant = ActionButton(title: L("permission.manage")) { [weak self] in self?.openPermission() }
        stack.addArrangedSubview(section(L("permission.title"), icon: .permission, views: [horizontalRow([permission, NSView(), grant])]))
        let mcp = ActionButton(title: L("copy.mcp.config"), icon: .clipboard) { [weak self] in self?.copyMCP() }
        stack.addArrangedSubview(section(L("settings.integration"), icon: .settings, views: [row(L("settings.mcp"), mcp)]))
        let version = bodyLabel("Cliprill 0.1.0 · AGPL-3.0-only", size: 12, secondary: true)
        stack.addArrangedSubview(version)
        feedback.font = CliprillAppearance.font(12); feedback.textColor = CliprillAppearance.secondary; stack.addArrangedSubview(feedback)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(NSSize(width: root.frame.width, height: max(740, stack.fittingSize.height + 44)))
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in if self?.window?.isVisible == true { self?.refreshPermission() } } }
        refreshPermission()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func section(_ title: String, icon: ClipIcon, views: [NSView]) -> NSView {
        let group = NSStackView(); group.orientation = .vertical; group.alignment = .leading; group.spacing = 8
        let image = NSImageView(image: icon.image()); image.contentTintColor = CliprillAppearance.secondary
        let heading = bodyLabel(title, size: 12, secondary: true); heading.font = CliprillAppearance.font(12, weight: .medium)
        group.addArrangedSubview(horizontalRow([image, heading]))
        let card = SurfaceView(radius: 10); card.showsBorder = true
        let content = NSStackView(views: views); content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14), content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)])
        for view in views { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        group.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        horizontalRow([bodyLabel(title), NSView(), control])
    }
    func refreshPermission() {
        permission.stringValue = appDelegate.coordinator.hasPermission ? L("permission.ready") : L("permission.missing")
        permission.textColor = CliprillAppearance.secondary
    }
    @objc private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(capture.state == .on, forKey: "captureEnabled"); defaults.set(capacity.selectedTag(), forKey: "historyCapacity"); defaults.set(retention.selectedTag(), forKey: "retentionDays"); defaults.set(excluded.string, forKey: "excludedApps")
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
