// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

/// Keep native text editing while laying out the search accessories separately.
final class SearchFieldView: SurfaceView {
    let field = NSSearchField()
    var onClear: (() -> Void)?
    private let icon = NSImageView(image: ClipIcon.search.image())
    private let clearButton = ActionButton(icon: .close, help: L("search.clear"), handler: {})

    init() {
        super.init(radius: 10)
        surfaceColor = CliprillAppearance.input
        field.font = CliprillAppearance.font(14)
        field.textColor = CliprillAppearance.ink
        field.placeholderAttributedString = NSAttributedString(string: L("search.placeholder"), attributes: [
            .font: CliprillAppearance.font(14), .foregroundColor: CliprillAppearance.secondary
        ])
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel(L("search.placeholder"))
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        icon.contentTintColor = CliprillAppearance.secondary
        icon.setAccessibilityElement(false)
        clearButton.handler = { [weak self] in self?.onClear?() }
        clearButton.isHidden = true
        for view in [icon, field, clearButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor), field.heightAnchor.constraint(equalToConstant: 24),
            field.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        // Reserve the clear button's space even when empty, so the text never shifts.
        clearButton.isHidden = field.stringValue.isEmpty
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target === icon ? self : target
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let focused = window?.isKeyWindow == true && field.currentEditor() != nil && window?.firstResponder === field.currentEditor()
        let width: CGFloat = CliprillAppearance.highContrast ? 2 : 1
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: 10, yRadius: 10)
        (focused ? NSColor.controlAccentColor : CliprillAppearance.separator).setStroke()
        outline.lineWidth = width
        outline.stroke()
    }
}
