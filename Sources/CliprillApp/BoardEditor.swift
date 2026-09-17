// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import CliprillCore

extension BoardColor {
    var tint: NSColor {
        switch self {
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .rose: return .systemPink
        case .orange: return .systemOrange
        case .graphite: return .secondaryLabelColor
        }
    }
    var swatch: NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            self.tint.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill(); return true
        }
    }
}

/// Native sheet shared by board properties and individual saved snippets.
@MainActor
final class BoardEditor: NSWindowController {
    private let name = NSTextField()
    private let text = NSTextView()
    private let color = NSPopUpButton()
    private let sensitive = NSButton(checkboxWithTitle: L("board.sensitive"), target: nil, action: nil)
    private let error = NSTextField(wrappingLabelWithString: "")
    private var submit: ActionButton!
    private let save: (String, String, BoardColor, Bool) async throws -> Void
    init(board: Pinboard?, item: PinnedItem? = nil, editingItem: Bool = false,
         save: @escaping (String, String, BoardColor, Bool) async throws -> Void) {
        self.save = save
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: editingItem ? 400 : 190), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L(editingItem ? "board.item.edit" : "board.properties")
        window.titlebarAppearsTransparent = true; window.backgroundColor = CliprillAppearance.windowBackground
        super.init(window: window)
        let root = SurfaceView(); window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)])
        name.placeholderString = L(editingItem ? "board.item.label" : "board.name")
        name.stringValue = editingItem ? (item?.label ?? "") : (board?.title ?? "")
        name.setAccessibilityLabel(name.placeholderString ?? "")
        stack.addArrangedSubview(name)
        for value in BoardColor.allCases {
            color.addItem(withTitle: L("color." + value.rawValue)); color.lastItem?.image = value.swatch
        }
        color.selectItem(at: BoardColor.allCases.firstIndex(of: board?.color ?? .teal) ?? 0)
        if editingItem {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
            text.isRichText = false; text.font = CliprillAppearance.font(14)
            text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
            text.backgroundColor = CliprillAppearance.input; text.textColor = CliprillAppearance.ink
            text.textContainerInset = NSSize(width: 12, height: 12); text.autoresizingMask = [.width]
            text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
            text.string = item?.image == nil ? (item?.text ?? "") : L("board.image.preserved")
            text.isEditable = item?.image == nil; text.setAccessibilityLabel(L("board.item.content"))
            scroll.documentView = text; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
            stack.addArrangedSubview(scroll)
            sensitive.state = item?.sensitive == true ? .on : .off; stack.addArrangedSubview(sensitive)
            let hint = NSTextField(wrappingLabelWithString: L("board.sensitive.hint")); hint.font = CliprillAppearance.font(11); hint.textColor = CliprillAppearance.secondary
            stack.addArrangedSubview(hint)
        } else { stack.addArrangedSubview(horizontalRow([bodyLabel(L("board.color")), NSView(), color])) }
        error.textColor = .systemRed; error.font = CliprillAppearance.font(11); stack.addArrangedSubview(error)
        let cancel = ActionButton(title: L("cancel")) { [weak self] in self?.dismiss() }; cancel.keyEquivalent = "\u{1b}"
        submit = ActionButton(title: L("save"), style: .prominent) { [weak self] in self?.commit() }
        submit.keyEquivalent = "\r"; submit.keyEquivalentModifierMask = [.command]
        stack.addArrangedSubview(horizontalRow([NSView(), cancel, submit]))
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.initialFirstResponder = name
    }
    required init?(coder: NSCoder) { fatalError() }
    private func dismiss() { if let window { window.sheetParent?.endSheet(window) } }
    private func commit() {
        submit.isEnabled = false
        Task {
            do { try await save(name.stringValue, text.string, BoardColor.allCases[color.indexOfSelectedItem], sensitive.state == .on); dismiss() }
            catch { self.error.stringValue = error.localizedDescription; submit.isEnabled = true }
        }
    }
}
