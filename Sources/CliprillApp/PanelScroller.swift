// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

/// Restyle only the native scroller's parts, retaining its hit area and tracking.
final class PanelScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var isOpaque: Bool { false }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        guard isEnabled, knobProportion < 1 else { return }
        var thumb = rect(for: .knob)
        guard !thumb.isEmpty else { return }
        let dragging = hitPart == .knob
        let width = min(thumb.width, CliprillAppearance.highContrast || dragging ? 8 : 6)
        thumb.origin.x += (thumb.width - width) / 2
        thumb.size.width = width
        (dragging ? CliprillAppearance.scrollerActive : CliprillAppearance.scroller).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
