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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = queue == nil ? L("new.queue") : L("append.text")
        super.init(window: window)
        let root = NSView(); window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)])
        titleField.placeholderString = L("queue.title"); titleField.stringValue = queue?.title ?? L("queue.untitled"); titleField.isEnabled = queue == nil
        stack.addArrangedSubview(titleField)
        mode.selectedSegment = 0; mode.segmentStyle = .separated; stack.addArrangedSubview(mode)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        textView.font = .systemFont(ofSize: 13); textView.isRichText = false; textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8); textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true; scroll.documentView = textView
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        stack.addArrangedSubview(scroll)
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed; stack.addArrangedSubview(errorLabel)
        let cancel = NSButton(title: L("cancel"), target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        submit = NSButton(title: L("add.queue"), target: self, action: #selector(add)); submit.bezelStyle = .rounded; submit.keyEquivalent = "\r"; submit.keyEquivalentModifierMask = [.command]
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 550), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cliprill · " + L("settings"); window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSView(); window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)])
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleCliprill)
        stack.addArrangedSubview(row(L("open.shortcut"), recorder))
        capture.state = UserDefaults.standard.bool(forKey: "captureEnabled") ? .on : .off; capture.target = self; capture.action = #selector(savePreferences)
        stack.addArrangedSubview(capture)
        for n in [100, 500, 1000, 2000] { capacity.addItem(withTitle: String(n)); capacity.lastItem?.tag = n }
        capacity.selectItem(withTag: UserDefaults.standard.integer(forKey: "historyCapacity")); capacity.target = self; capacity.action = #selector(savePreferences)
        for n in [1, 7, 30, 90] { retention.addItem(withTitle: "\(n) " + L("days")); retention.lastItem?.tag = n }
        retention.selectItem(withTag: UserDefaults.standard.integer(forKey: "retentionDays")); retention.target = self; retention.action = #selector(savePreferences)
        stack.addArrangedSubview(row(L("history.limit"), capacity)); stack.addArrangedSubview(row(L("history.retention"), retention))
        let excludedLabel = NSTextField(labelWithString: L("excluded.apps")); excludedLabel.font = .systemFont(ofSize: 12); stack.addArrangedSubview(excludedLabel)
        let excludedScroll = NSScrollView(); excludedScroll.hasVerticalScroller = true; excludedScroll.borderType = .bezelBorder
        excluded.isRichText = false; excluded.font = .monospacedSystemFont(ofSize: 11, weight: .regular); excluded.textContainerInset = NSSize(width: 8, height: 8)
        excluded.autoresizingMask = [.width]; excluded.textContainer?.widthTracksTextView = true; excluded.isVerticallyResizable = true
        excluded.string = UserDefaults.standard.string(forKey: "excludedApps") ?? "com.1password.1password\ncom.agilebits.onepassword7\ncom.apple.keychainaccess"
        excludedScroll.documentView = excluded; excludedScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true; stack.addArrangedSubview(excludedScroll)
        let save = NSButton(title: L("save.exclusions"), target: self, action: #selector(savePreferences)); save.bezelStyle = .rounded; stack.addArrangedSubview(save)
        let line = NSBox(); line.boxType = .separator; stack.addArrangedSubview(line)
        permission.font = .systemFont(ofSize: 12); permission.lineBreakMode = .byTruncatingTail
        let grant = NSButton(title: L("open.system.settings"), target: self, action: #selector(openPermission)); grant.bezelStyle = .rounded
        stack.addArrangedSubview(NSStackView(views: [permission, NSView(), grant]))
        let mcp = NSButton(title: L("copy.mcp.config"), target: self, action: #selector(copyMCP)); mcp.bezelStyle = .rounded
        let clear = NSButton(title: L("clear.history"), target: self, action: #selector(clearHistory)); clear.bezelStyle = .rounded
        stack.addArrangedSubview(NSStackView(views: [mcp, NSView(), clear]))
        let version = NSTextField(labelWithString: "Cliprill 0.1.0  ·  AGPL-3.0-only"); version.font = .systemFont(ofSize: 11); version.textColor = .secondaryLabelColor; stack.addArrangedSubview(version)
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = .secondaryLabelColor; stack.addArrangedSubview(feedback)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in if self?.window?.isVisible == true { self?.refreshPermission() } } }
        refreshPermission()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [label, NSView(), control]); row.alignment = .centerY; return row
    }
    func refreshPermission() { permission.stringValue = appDelegate.coordinator.hasPermission ? L("permission.ready") : L("permission.missing"); permission.textColor = appDelegate.coordinator.hasPermission ? .systemTeal : .secondaryLabelColor }
    @objc private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(capture.state == .on, forKey: "captureEnabled"); defaults.set(capacity.selectedTag(), forKey: "historyCapacity"); defaults.set(retention.selectedTag(), forKey: "retentionDays"); defaults.set(excluded.string, forKey: "excludedApps")
        Task {
            do { try await appDelegate.core.pruneHistory(capacity: capacity.selectedTag(), retentionDays: retention.selectedTag()); await appDelegate.refresh(); feedback.stringValue = L("saved") }
            catch { feedback.stringValue = error.localizedDescription }
        }
    }
    @objc private func openPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
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
