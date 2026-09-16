// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import ApplicationServices
import Carbon
import CliprillCore
import CliprillClipboard

@MainActor
final class PasteCoordinator {
    static let marker: Int64 = 0x434C495052494C4C
    private let core: QueueCore
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var timer: Timer?
    private var observedChange: Int
    private var queue: ClipQueue?
    private var pending: [(pid_t, String)] = []
    private var pumping = false
    private var suppressedV = false
    private var polling = false
    private var accepting = false
    private var headPreparation: Task<Void, Never>?
    private var preparingItemID: String?
    private var cachedImage: (id: String, content: ClipboardWrite)?
    private var pauseDepth = 0
    private var pasteEpoch = 0
    private var observedKeyEvents = 0
    private var observedPasteEvents = 0
    var noCapture = false
    var onChange: (() async -> Void)?
    var onMessage: ((String) -> Void)?
    var isPanelKey: (() -> Bool)?

    init(core: QueueCore, noCapture: Bool) {
        self.core = core; self.noCapture = noCapture
        observedChange = NSPasteboard.general.changeCount
    }
    var hasPermission: Bool { AXIsProcessTrusted() }
    var diagnostics: JSONValue {
        .object(["tap_enabled": .bool(tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false), "key_events": .integer(observedKeyEvents), "paste_events": .integer(observedPasteEvents), "accepting": .bool(accepting), "own_window_key": .bool(isPanelKey?() ?? false), "frontmost_app": .string(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")])
    }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }
    func stop() {
        timer?.invalidate(); headPreparation?.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
    }
    func ensureTap() throws {
        guard hasPermission else { throw CoreError("accessibility_required", L("permission.required")) }
        guard !IsSecureEventInputEnabled() else { throw CoreError("secure_input", L("secure.input")) }
        if let tap, CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: true); return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // This tap is installed on the main run loop only.
            return MainActor.assumeIsolated {
                Unmanaged<PasteCoordinator>.fromOpaque(context).takeUnretainedValue().receive(type: type, event: event)
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { throw CoreError("accessibility_required", L("permission.reopen")) }
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func update(_ state: CoreState) {
        let oldID = queue?.id
        queue = state.activeQueue
        accepting = queue != nil && pauseDepth == 0
        guard let q = queue, let item = q.next else {
            headPreparation?.cancel(); headPreparation = nil; preparingItemID = nil
            return
        }
        guard oldID != q.id || (preparingItemID != nil && preparingItemID != item.id) else { return }
        guard pauseDepth == 0 else { return }
        headPreparation?.cancel()
        preparingItemID = item.id
        let change = NSPasteboard.general.changeCount
        headPreparation = Task {
            do {
                let content = try await prepared(text: item.text, image: item.image)
                try Task.checkCancellation()
                guard queue?.id == q.id, queue?.next?.id == item.id else { return }
                guard NSPasteboard.general.changeCount == change else { throw CoreError("external_copy", L("copied.paused")) }
                try write(content)
                preparingItemID = nil
            } catch is CancellationError {
                // Navigation or pausing superseded this preparation.
            } catch {
                accepting = false; onMessage?(error.localizedDescription)
                await pause(reason: (error as? CoreError)?.code ?? "clipboard_unavailable", waitForPump: false)
            }
        }
    }
    private func prepared(text: String, image: ClipboardImage?) async throws -> ClipboardWrite {
        guard let image else { return .text(text) }
        if let cachedImage, cachedImage.id == image.id { return cachedImage.content }
        let png = try await core.imageData(image)
        let content = try await Task.detached(priority: .userInitiated) { try ClipboardWrite.image(png: png) }.value
        try Task.checkCancellation()
        cachedImage = (image.id, content)
        return content
    }
    func write(_ text: String) throws { try write(ClipboardWrite.text(text)) }
    private func write(_ content: ClipboardWrite) throws {
        try content.write(to: .general)
        observedChange = NSPasteboard.general.changeCount
    }
    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            accepting = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Task { await pause(reason: "event_tap_disabled") }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        observedKeyEvents += 1
        guard event.getIntegerValueField(.keyboardEventKeycode) == 9 else { return Unmanaged.passUnretained(event) }
        if type == .keyUp, suppressedV { suppressedV = false; return nil }
        let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        if type == .keyDown, mods == .maskCommand { observedPasteEvents += 1 }
        guard type == .keyDown, mods == .maskCommand, accepting, let q = queue, isPanelKey?() != true,
              let target = NSWorkspace.shared.frontmostApplication, target.processIdentifier != getpid() else { return Unmanaged.passUnretained(event) }
        suppressedV = true
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        guard pending.count < 64 else {
            accepting = false; Task { await pause(reason: "too_many_pastes") }; return nil
        }
        pending.append((target.processIdentifier, q.id))
        if !pumping { pumping = true; Task { await pump() } }
        return nil
    }
    private func pump() async {
        defer { pumping = false }
        while !pending.isEmpty {
            // A fast Cmd-V waits for image conversion instead of pasting the previous clipboard.
            if let preparation = headPreparation { await preparation.value }
            guard !pending.isEmpty else { return }
            let (pid, queueID) = pending.removeFirst()
            let epoch = pasteEpoch
            var token: UUID?
            do {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw CoreError("target_changed", L("target.changed")) }
                guard NSPasteboard.general.changeCount == observedChange else { throw CoreError("external_copy", L("copied.paused")) }
                guard hasPermission, !IsSecureEventInputEnabled() else { throw CoreError("accessibility_required", L("permission.required")) }
                let state = await core.snapshot()
                if state.activeQueue == nil, state.queues.first(where: { $0.id == queueID })?.status == .completed {
                    // Extra distinct key presses after the final item retain normal paste behavior.
                    try sendPaste(to: pid)
                } else {
                    guard accepting, state.activeID == queueID else { pending.removeAll(); return }
                    let r = try await core.reserveNext(); token = r.token
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw CoreError("target_changed", L("target.changed")) }
                    guard NSPasteboard.general.changeCount == observedChange else { throw CoreError("external_copy", L("copied.paused")) }
                    let content = try await prepared(text: r.item.text, image: r.item.image)
                    guard accepting, epoch == pasteEpoch else { throw CoreError("queue_paused", L("status.paused")) }
                    guard hasPermission, !IsSecureEventInputEnabled() else { throw CoreError("input_unavailable", L("permission.required")) }
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw CoreError("target_changed", L("target.changed")) }
                    guard NSPasteboard.general.changeCount == observedChange else { throw CoreError("external_copy", L("copied.paused")) }
                    try write(content)
                    try sendPaste(to: pid)
                    try await core.commit(r.token); token = nil
                    await onChange?()
                }
                // A dispatch rate limit, never treated as proof that the target read the clipboard.
                try await Task.sleep(nanoseconds: 160_000_000)
            } catch {
                if let token { await core.cancel(token) }
                pending.removeAll(); accepting = false
                await pause(reason: (error as? CoreError)?.code ?? "dispatch_error", waitForPump: false)
                onMessage?(error.localizedDescription)
                return
            }
        }
    }
    private func sendPaste(to pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw CoreError("dispatch", L("paste.failed")) }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.postToPid(pid)
        }
    }
    func pasteHistory(_ item: HistoryItem, target: NSRunningApplication?) async throws {
        try ensureTap()
        guard let target, !target.isTerminated, target.processIdentifier != getpid() else { throw CoreError("target_changed", L("target.changed")) }
        await pause(reason: "history_paste")
        let change = NSPasteboard.general.changeCount
        let content = try await prepared(text: item.text, image: item.image)
        guard NSPasteboard.general.changeCount == change else { throw CoreError("external_copy", L("copied.paused")) }
        try ensureTap()
        target.activate(options: [])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { throw CoreError("target_changed", L("target.changed")) }
        guard NSPasteboard.general.changeCount == change else { throw CoreError("external_copy", L("copied.paused")) }
        try write(content); try sendPaste(to: target.processIdentifier)
    }
    func pause(reason: String, waitForPump: Bool = true) async {
        pauseDepth += 1; pasteEpoch += 1
        defer { pauseDepth -= 1; accepting = queue != nil && pauseDepth == 0 }
        accepting = false; pending.removeAll()
        headPreparation?.cancel(); headPreparation = nil; preparingItemID = nil
        if waitForPump { while pumping { try? await Task.sleep(nanoseconds: 20_000_000) } }
        if let id = (await core.snapshot()).activeID {
            do { _ = try await core.handle(IPCRequest(method: "queue_pause", arguments: ["queue_id": .string(id), "reason": .string(reason)])) }
            catch { onMessage?(error.localizedDescription) }
        }
        await onChange?()
    }
    private func poll() async {
        guard !polling else { return }; polling = true; defer { polling = false }
        if accepting, !hasPermission || IsSecureEventInputEnabled() { await pause(reason: "input_unavailable") }
        let pb = NSPasteboard.general
        guard pb.changeCount != observedChange else { return }
        observedChange = pb.changeCount
        let source = NSWorkspace.shared.frontmostApplication
        let prefs = UserDefaults.standard
        let excluded = Set((prefs.string(forKey: "excludedApps") ?? "com.1password.1password\ncom.agilebits.onepassword7\ncom.apple.keychainaccess").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        let shouldCapture = !noCapture && prefs.bool(forKey: "captureEnabled") && !excluded.contains(source?.bundleIdentifier ?? "")
        let content = shouldCapture ? ClipboardReader.read(from: pb) : nil
        if queue != nil { await pause(reason: "external_copy"); onMessage?(L("copied.paused")) }
        guard let content else { return }
        do {
            switch content {
            case .text(let text):
                try await core.capture(text: text, source: source?.localizedName ?? "", capacity: prefs.integer(forKey: "historyCapacity"), retentionDays: prefs.integer(forKey: "retentionDays"))
            case .image(let data):
                let image = try await Task.detached(priority: .utility) { try PreparedClipboardImage(data: data) }.value
                // Respect a capture preference change made while a large image was decoding.
                guard !noCapture, prefs.bool(forKey: "captureEnabled") else { return }
                try await core.capture(image: image, source: source?.localizedName ?? "", capacity: prefs.integer(forKey: "historyCapacity"), retentionDays: prefs.integer(forKey: "retentionDays"))
            }
            await onChange?()
        } catch { onMessage?(error.localizedDescription) }
    }
}
