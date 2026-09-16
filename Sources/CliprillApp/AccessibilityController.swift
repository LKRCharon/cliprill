// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import ApplicationServices

/// Contextual permission help using public macOS APIs, with no TCC database access.
@MainActor
final class AccessibilityController: NSWindowController, NSWindowDelegate {
    unowned let appDelegate: AppDelegate
    private let status = bodyLabel("", size: 12, secondary: true)
    private let statusIcon = NSImageView()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var primary: ActionButton!
    private var timer: Timer?
    private var onReady: (() -> Void)?
    private var requested = false

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("permission.title"); window.titlebarAppearsTransparent = true
        window.backgroundColor = CliprillAppearance.windowBackground
        window.isReleasedWhenClosed = false; window.level = .floating
        super.init(window: window); window.delegate = self
        let root = SurfaceView(); window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)])

        let title = bodyLabel(L("permission.heading"), size: 21); title.font = CliprillAppearance.font(21, weight: .medium)
        stack.addArrangedSubview(title)
        let reason = paragraph(L("permission.reason")); stack.addArrangedSubview(reason)

        let card = SurfaceView(radius: 10); card.surfaceColor = CliprillAppearance.input; card.showsBorder = true
        let appIcon = NSImageView(image: NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path))
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let appName = bodyLabel("Cliprill", size: 14); appName.font = CliprillAppearance.font(14, weight: .medium)
        let labels = NSStackView(views: [appName, status]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        statusIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let cardRow = horizontalRow([appIcon, labels, NSView(), statusIcon], spacing: 12)
        cardRow.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(cardRow)
        NSLayoutConstraint.activate([cardRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), cardRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14), cardRow.topAnchor.constraint(equalTo: card.topAnchor, constant: 12), cardRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)])
        stack.addArrangedSubview(card)
        stack.addArrangedSubview(paragraph(L("permission.steps")))
        let reveal = ActionButton(title: L("permission.finder"), icon: .folder) {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        let fallback = NSStackView(views: [paragraph(L("permission.finder.hint"), size: 12), reveal])
        fallback.orientation = .vertical; fallback.alignment = .leading; fallback.spacing = 6
        stack.addArrangedSubview(fallback)
        stack.addArrangedSubview(HairlineView())
        feedback.font = CliprillAppearance.font(12); feedback.textColor = CliprillAppearance.secondary
        feedback.maximumNumberOfLines = 2
        feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primary = ActionButton(title: L("open.system.settings"), style: .prominent) { [weak self] in self?.proceed() }
        primary.keyEquivalent = "\r"
        stack.addArrangedSubview(horizontalRow([feedback, NSView(), primary]))
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        // Wrapping labels use an explicit width for fitting without a live UI measurement pass.
        reason.preferredMaxLayoutWidth = 412
        refresh()
        root.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 460, height: max(440, stack.fittingSize.height + 40)))
    }
    required init?(coder: NSCoder) { fatalError() }
    private func paragraph(_ text: String, size: CGFloat = 13) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = CliprillAppearance.font(size); label.textColor = CliprillAppearance.secondary
        label.preferredMaxLayoutWidth = 412
        return label
    }
    func present(onReady: (() -> Void)?) {
        self.onReady = onReady
        refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    private func refresh() {
        let ready = appDelegate.coordinator.hasPermission
        status.stringValue = L(ready ? "permission.ready" : "permission.missing")
        statusIcon.image = (ready ? ClipIcon.check : ClipIcon.permission).image(size: 18)
        statusIcon.contentTintColor = ready ? .controlAccentColor : CliprillAppearance.secondary
        feedback.stringValue = L(ready ? "permission.success" : (requested ? "permission.waiting" : "permission.optional"))
        primary.title = L(ready ? "continue" : "open.system.settings")
        primary.setAccessibilityLabel(primary.title); primary.invalidateIntrinsicContentSize()
    }
    private func proceed() {
        if appDelegate.coordinator.hasPermission {
            let continuation = onReady; onReady = nil
            close(); appDelegate.settings?.refreshPermission()
            // Permission completion never sends a paste to the newly focused Settings app.
            continuation?()
            return
        }
        requested = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(url) { feedback.stringValue = L("permission.settings.fallback") }
        else { refresh() }
    }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; onReady = nil }
    override func cancelOperation(_ sender: Any?) { close() }
}
