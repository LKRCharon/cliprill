// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import KeyboardShortcuts
import CliprillCore

enum CliprillResources {
static let bundle: Bundle = {
    if let resources = Bundle.main.resourceURL,
       let bundle = Bundle(url: resources.appendingPathComponent("Cliprill_CliprillApp.bundle")) { return bundle }
    return .module
}()
}
func L(_ key: String) -> String { NSLocalizedString(key, bundle: CliprillResources.bundle, comment: "") }
extension KeyboardShortcuts.Name {
    static let toggleCliprill = Self("toggleCliprill", default: .init(.v, modifiers: [.command, .shift]))
}

@main
enum CliprillMain {
    @MainActor static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--data-dir"), i + 1 < CommandLine.arguments.count {
            setenv("CLIPRILL_DATA_DIR", CommandLine.arguments[i + 1], 1)
        }
        let app = NSApplication.shared
        if let i = CommandLine.arguments.firstIndex(of: "--appearance"), i + 1 < CommandLine.arguments.count {
            app.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var core: QueueCore!
    var coordinator: PasteCoordinator!
    var panel: PanelController!
    var settings: SettingsController?
    var permissionGuide: AccessibilityController?
    var status: NSStatusItem!
    private var instance: InstanceLock?
    private var server: IPCServer?
    var state = CoreState()
    var target: NSRunningApplication?
    private var refreshGeneration = 0
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["captureEnabled": true, "historyCapacity": 500, "retentionDays": 30])
        do {
            instance = try InstanceLock(directory: CliprillPaths.dataDirectory)
            core = try QueueCore(directory: CliprillPaths.dataDirectory)
            coordinator = PasteCoordinator(core: core, noCapture: CommandLine.arguments.contains("--no-capture") || ProcessInfo.processInfo.environment["CLIPRILL_NO_CAPTURE"] == "1")
            panel = PanelController(appDelegate: self)
            coordinator.isPanelKey = { NSApp.keyWindow != nil }
            coordinator.onChange = { [weak self] in await self?.refresh() }
            coordinator.onMessage = { [weak self] message in self?.panel.showMessage(message) }
            status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status.button?.image = ClipIcon.clipboard.image(size: 18)
            status.button?.target = self; status.button?.action = #selector(statusClicked)
            status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            status.button?.toolTip = "Cliprill"
            installMenu()
            // Upgrade the original default without replacing customized shortcuts.
            if !UserDefaults.standard.bool(forKey: "shiftCommandVShortcutMigrated") {
                if KeyboardShortcuts.getShortcut(for: .toggleCliprill) == .init(.v, modifiers: [.control, .option]) {
                    KeyboardShortcuts.setShortcut(.init(.v, modifiers: [.command, .shift]), for: .toggleCliprill)
                }
                UserDefaults.standard.set(true, forKey: "shiftCommandVShortcutMigrated")
            }
            KeyboardShortcuts.onKeyUp(for: .toggleCliprill) { [weak self] in self?.togglePanel() }
            server = try IPCServer(directory: CliprillPaths.dataDirectory)
            server?.start { [weak self] request in
                guard let self else { return IPCResponse(error: CoreError("app_unavailable", "Cliprill is closing.")) }
                return await self.handleIPC(request)
            }
            coordinator.start()
            signal(SIGTERM, SIG_IGN)
            signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            signalSource?.setEventHandler { NSApp.terminate(nil) }; signalSource?.resume()
            Task {
                try? await core.pruneHistory(capacity: UserDefaults.standard.integer(forKey: "historyCapacity"), retentionDays: UserDefaults.standard.integer(forKey: "retentionDays"))
                await refresh()
                if !CommandLine.arguments.contains("--background") { togglePanel() }
            }
        } catch {
            if (error as? CoreError)?.code == "already_running" {
                Task.detached { _ = try? IPCClient.send(IPCRequest(method: "app_show")); await MainActor.run { NSApp.terminate(nil) } }
            } else {
                let alert = NSAlert(); alert.messageText = "Cliprill"; alert.informativeText = error.localizedDescription; alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { coordinator?.stop(); server?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { togglePanel() }; return true }

    func refresh() async {
        refreshGeneration += 1; let generation = refreshGeneration
        let value = await core.snapshot()
        guard generation == refreshGeneration else { return }
        state = value; coordinator.update(value); panel.reload(value)
        status.button?.title = value.activeQueue.map { " \($0.remaining)" } ?? ""
        status.button?.contentTintColor = value.activeQueue == nil ? nil : .systemTeal
        status.button?.toolTip = value.activeQueue.map { "Cliprill · \($0.title) · \($0.remaining)" } ?? "Cliprill"
    }
    func perform(_ method: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let request = IPCRequest(method: method, arguments: arguments)
        if method == "queue_activate" {
            if let saved = try await core.cachedResponse(request) { return saved }
            try coordinator.ensureTap()
        }
        let result = try await core.handle(request)
        await refresh(); return result
    }
    func handleIPC(_ request: IPCRequest) async -> IPCResponse {
        do {
            switch request.method {
            case "app_show": if panel.window?.isVisible != true { togglePanel() }; return IPCResponse(result: .object(["visible": .bool(true)]))
            case "app_hide": panel.window?.orderOut(nil); return IPCResponse(result: .object(["visible": .bool(false)]))
            case "app_status": return IPCResponse(result: .object(["version": .string("0.3.0"), "accessibility": .bool(coordinator.hasPermission), "panel_visible": .bool(panel.window?.isVisible ?? false), "capture_enabled": .bool(!coordinator.noCapture && UserDefaults.standard.bool(forKey: "captureEnabled")), "events": coordinator.diagnostics]))
            default: return IPCResponse(result: try await perform(request.method, request.arguments))
            }
        } catch { return IPCResponse(error: error) }
    }
    @objc func togglePanel() {
        if panel.window?.isVisible == true { panel.window?.orderOut(nil) }
        else {
            if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { target = front }
            panel.showNearPointer()
            Task { await refresh() }
        }
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: L("open.cliprill"), action: #selector(togglePanel), keyEquivalent: "")
            menu.addItem(withTitle: L("settings"), action: #selector(showSettings), keyEquivalent: "")
            menu.addItem(withTitle: L("pause"), action: #selector(pauseQueue), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L("quit"), action: #selector(quit), keyEquivalent: "")
            for item in menu.items { item.target = self }
            status.menu = menu; status.button?.performClick(nil); status.menu = nil
        } else { togglePanel() }
    }
    @objc func pauseQueue() { Task { await coordinator.pause(reason: "user") } }
    @objc func showSettings() {
        panel.window?.orderOut(nil)
        if settings == nil { settings = SettingsController(appDelegate: self) }
        settings?.showWindow(nil); settings?.window?.center(); settings?.refreshPermission()
        NSApp.activate(ignoringOtherApps: true)
    }
    func showPermissionGuide(onReady: (() -> Void)? = nil) {
        if permissionGuide == nil { permissionGuide = AccessibilityController(appDelegate: self) }
        permissionGuide?.present(onReady: onReady)
    }
    @objc func quit() { NSApp.terminate(nil) }
    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: L("open.cliprill"), action: #selector(togglePanel), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("settings"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: L("quit"), action: #selector(quit), keyEquivalent: "q").target = self
        menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(editItem); NSApp.mainMenu = menu
    }
}
