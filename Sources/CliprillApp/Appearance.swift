// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

enum CliprillAppearance {
    static let lightBackground = NSColor.white
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static let windowBackground = NSColor(name: "CliprillWindowBackground") { appearance in
        isDark(appearance) ? .windowBackgroundColor : lightBackground
    }
}

final class PanelSurfaceView: NSView {
    private let darkMaterial = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        darkMaterial.frame = bounds
        darkMaterial.autoresizingMask = [.width, .height]
        darkMaterial.material = .popover
        darkMaterial.blendingMode = .behindWindow
        darkMaterial.state = .active
        addSubview(darkMaterial)
        updateSurface()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSurface()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }
    private func updateSurface() {
        let dark = CliprillAppearance.isDark(effectiveAppearance)
        darkMaterial.isHidden = !dark
        // An opaque light surface stays white regardless of the window behind it.
        layer?.backgroundColor = dark ? nil : CliprillAppearance.lightBackground.cgColor
    }
}
