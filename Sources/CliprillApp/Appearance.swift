// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

enum CliprillAppearance {
    static let panelWidth: CGFloat = 420
    static let rowHeight: CGFloat = 52
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    private static func color(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: name) { appearance in
            let rgb = isDark(appearance) ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
    static let windowBackground = color("CliprillSurface", light: 0xFFFFFF, dark: 0x202123)
    static let ink = color("CliprillInk", light: 0x1A1C1F, dark: 0xECEDEF)
    static let secondary = color("CliprillSecondary", light: 0x606163, dark: 0xA8AAAE)
    static let input = color("CliprillInput", light: 0xF8F8F8, dark: 0x292A2D)
    static var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var separator: NSColor { ink.withAlphaComponent(highContrast ? 0.3 : 0.08) }
    static var hover: NSColor { ink.withAlphaComponent(highContrast ? 0.10 : 0.04) }
    static var selection: NSColor { ink.withAlphaComponent(highContrast ? 0.15 : 0.07) }
    static var scroller: NSColor { ink.withAlphaComponent(highContrast ? 0.65 : 0.23) }
    static var scrollerActive: NSColor { ink.withAlphaComponent(highContrast ? 0.8 : 0.42) }
    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

/// Opaque in both appearances, including when Reduce Transparency is enabled.
class SurfaceView: NSView {
    var surfaceColor: NSColor = CliprillAppearance.windowBackground { didSet { updateSurface() } }
    var showsBorder = false { didSet { updateSurface() } }
    private var preferenceObserver: NSObjectProtocol?
    init(radius: CGFloat = 0) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        preferenceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateSurface(); self?.needsDisplay = true }
        updateSurface()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let preferenceObserver { NSWorkspace.shared.notificationCenter.removeObserver(preferenceObserver) } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateSurface() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateSurface() }
    private func updateSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = surfaceColor.cgColor
            layer?.borderColor = CliprillAppearance.separator.cgColor
            layer?.borderWidth = showsBorder ? 1 : 0
        }
    }
}

final class PanelSurfaceView: SurfaceView {
    init() { super.init(radius: 16); showsBorder = true }
    required init?(coder: NSCoder) { fatalError() }
}

final class HairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) { CliprillAppearance.separator.setFill(); bounds.fill() }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum ClipIcon: String, CaseIterable {
    case clipboard = "clipboard-list", search, close = "x", plus, more = "ellipsis"
    case chevronDown = "chevron-down", up = "arrow-up", down = "arrow-down"
    case undo = "undo-2", trash = "trash-2", text, preview = "eye", pause, play
    case link
    case settings = "settings-2", check, external = "external-link", keyboard
    case permission = "shield-check", folder

    func image(size: CGFloat = 16) -> NSImage {
        guard let url = CliprillResources.bundle.url(forResource: "lucide-" + rawValue, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            assertionFailure("Missing bundled Lucide icon: \(rawValue)")
            return NSImage(size: NSSize(width: size, height: size))
        }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

private final class ActionButtonCell: NSButtonCell {
    static let contentInset: CGFloat = 10
    static let imageTitleSpacing: CGFloat = 6

    var imageAndTitleSize: NSSize? {
        guard let image, !title.isEmpty, imagePosition == .imageLeading else { return nil }
        let text = attributedTitle.size()
        return NSSize(width: image.size.width + Self.imageTitleSpacing + ceil(text.width),
                      height: max(image.size.height, ceil(text.height)))
    }

    override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
        guard let image, let contentSize = imageAndTitleSize else {
            super.drawInterior(withFrame: frame, in: controlView)
            return
        }
        let textHeight = ceil(attributedTitle.size().height)
        let contentWidth = min(contentSize.width, max(0, frame.width - 2 * Self.contentInset))
        let textWidth = max(0, contentWidth - image.size.width - Self.imageTitleSpacing)
        let leading = frame.midX - contentWidth / 2
        let rightToLeft = controlView.userInterfaceLayoutDirection == .rightToLeft
        let imageX = rightToLeft ? leading + textWidth + Self.imageTitleSpacing : leading
        let textX = rightToLeft ? leading : leading + image.size.width + Self.imageTitleSpacing
        let imageFrame = NSRect(x: imageX, y: frame.midY - image.size.height / 2,
                                width: image.size.width, height: image.size.height)
        let textFrame = NSRect(x: textX, y: frame.midY - textHeight / 2,
                              width: textWidth, height: textHeight)
        // Keep native image tinting and text rendering while centering the combined content.
        drawImage(image, withFrame: imageFrame, in: controlView)
        _ = drawTitle(attributedTitle, withFrame: textFrame, in: controlView)
    }
}

final class ActionButton: NSButton {
    enum Style { case plain, prominent }
    var handler: (() -> Void)?
    var style: Style = .plain { didSet { needsDisplay = true } }
    private var hovering = false
    private var tracking: NSTrackingArea?
    init(title: String = "", icon: ClipIcon? = nil, help: String? = nil, style: Style = .plain,
         handler: @escaping () -> Void) {
        super.init(frame: .zero)
        cell = ActionButtonCell(textCell: title)
        self.title = title; self.style = style; self.handler = handler
        if let icon { image = icon.image() }
        imagePosition = title.isEmpty ? .imageOnly : (icon == nil ? .noImage : .imageLeading)
        isBordered = false; bezelStyle = .regularSquare; setButtonType(.momentaryPushIn)
        font = CliprillAppearance.font(13, weight: .medium)
        toolTip = help ?? title; setAccessibilityLabel(help ?? title)
        target = self; action = #selector(run); focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        if title.isEmpty { widthAnchor.constraint(equalToConstant: 28).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        if let content = (cell as? ActionButtonCell)?.imageAndTitleSize {
            return NSSize(width: content.width + 2 * ActionButtonCell.contentInset, height: 28)
        }
        let size = super.intrinsicContentSize
        return NSSize(width: title.isEmpty ? 28 : max(28, size.width + 18), height: 28)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let prominent = style == .prominent
        let fill: NSColor = prominent ? CliprillAppearance.ink :
            (isHighlighted || state == .on ? CliprillAppearance.selection : (hovering && isEnabled ? CliprillAppearance.hover : .clear))
        let opacity: CGFloat = isEnabled ? (prominent && isHighlighted ? 0.8 : 1) : 0.35
        fill.withAlphaComponent(fill.alphaComponent * opacity).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let foreground = (prominent ? CliprillAppearance.windowBackground : CliprillAppearance.ink)
            .withAlphaComponent(isEnabled ? 1 : 0.35)
        if contentTintColor != foreground { contentTintColor = foreground }
        let styledTitle = NSAttributedString(string: title, attributes: [.font: font!, .foregroundColor: foreground])
        if !attributedTitle.isEqual(to: styledTitle) { attributedTitle = styledTitle }
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            path.lineWidth = 2; path.stroke()
        }
    }
    @objc private func run() { handler?() }
}

func horizontalRow(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let row = NSStackView(views: views); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = spacing
    return row
}

func bodyLabel(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = CliprillAppearance.font(size)
    label.textColor = secondary ? CliprillAppearance.secondary : CliprillAppearance.ink
    return label
}
