import AppKit
import CoreGraphics
import Observation
import SwiftUI

enum CursorInputHotkeyAction: Equatable {
    case none
    case start
    case stop
}

enum CursorInputHotkeyPolicy {
    static func action(
        state: CursorInputController.State,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> CursorInputHotkeyAction {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if state == .armed, keyCode == 1, flags == [.command, .shift] { return .start }
        if state == .transcribing, keyCode == 53 { return .stop }
        return .none
    }
}

struct CursorInputTarget {
    let processIdentifier: pid_t
}

enum CursorInputWriter {
    struct KeyboardEdit: Equatable {
        let deleteCount: Int
        let text: String
    }

    static func keyboardEdit(previous: String, current: String) -> KeyboardEdit {
        let prefix = previous.commonPrefix(with: current)
        return KeyboardEdit(
            deleteCount: previous.dropFirst(prefix.count).count,
            text: String(current.dropFirst(prefix.count))
        )
    }

    static func focusedTarget() -> CursorInputTarget? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else { return nil }

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        let axRange = unsafeBitCast(rangeValue, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &range) else { return nil }
        guard range.location >= 0 else { return nil }
        return CursorInputTarget(processIdentifier: processIdentifier)
    }

    static func replaceGeneratedText(
        previous: String,
        current: String
    ) -> Bool {
        let edit = keyboardEdit(previous: previous, current: current)
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        for _ in 0..<edit.deleteCount {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else {
                return false
            }
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.001)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.001)
        }

        // Deliver one visible character at a time with a very short interval.
        // This follows the target app's normal keyboard path and gives it time
        // to apply each edit before a later streaming revision is calculated.
        if !edit.text.isEmpty { Thread.sleep(forTimeInterval: 0.005) }
        for character in edit.text {
            var codeUnits = Array(String(character).utf16)[...]
            while !codeUnits.isEmpty {
                let count = min(20, codeUnits.count)
                let chunk = Array(codeUnits.prefix(count))
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    return false
                }
                chunk.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(
                        stringLength: buffer.count,
                        unicodeString: buffer.baseAddress
                    )
                    up.keyboardSetUnicodeString(
                        stringLength: buffer.count,
                        unicodeString: buffer.baseAddress
                    )
                }
                down.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.002)
                up.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.002)
                codeUnits = codeUnits.dropFirst(count)
            }
        }
        return true
    }
}

private final class CursorGlobalKeyMonitor {
    enum Mode {
        case armed
        case transcribing
        case finishing
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var action: ((CursorInputHotkeyAction) -> Void)?
    var mode: Mode = .armed

    var isInstalled: Bool { eventTap != nil }

    @discardableResult
    func start(action: @escaping (CursorInputHotkeyAction) -> Void) -> Bool {
        stop()
        self.action = action
        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, eventType, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CursorGlobalKeyMonitor>
                    .fromOpaque(userInfo).takeUnretainedValue()
                if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return monitor.handle(event: event)
                    ? nil
                    : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.action = nil
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            self.action = nil
            return false
        }
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func handle(event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        if mode == .finishing {
            let exactCommandShift = modifiers.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
            return (keyCode == 1 && exactCommandShift) || keyCode == 53
        }
        let controllerState: CursorInputController.State = mode == .armed ? .armed : .transcribing
        let hotkeyAction = CursorInputHotkeyPolicy.action(
            state: controllerState,
            keyCode: keyCode,
            modifiers: modifiers
        )
        guard hotkeyAction != .none else { return false }
        action?(hotkeyAction)
        return true
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        action = nil
    }

    deinit { stop() }
}

@MainActor
@Observable
final class CursorInputController {
    enum State: Equatable {
        case idle
        case armed
        case transcribing
        case finishing

        var message: String {
            switch self {
            case .idle: ""
            case .armed: L10n.text("将光标移到输入位置，按 Command-Shift-S 开始转录")
            case .transcribing: L10n.text("正在转录，按 Esc 或 Command-Shift-S 退出")
            case .finishing: L10n.text("正在完成最后一句…")
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    private var panel: NSPanel?
    private let keyMonitor = CursorGlobalKeyMonitor()
    private var mouseMonitor: Any?
    private var followTimer: Timer?
    private var insertedText = ""
    private var pendingTranscript = ""
    private var syncTask: Task<Void, Never>?
    private var target: CursorInputTarget?
    private var startAction: (() -> Void)?
    private var stopAction: (() -> Void)?

    var isArmed: Bool { state != .idle }
    var isTranscribing: Bool { state == .transcribing }
    var hasActiveResources: Bool {
        panel != nil || keyMonitor.isInstalled || mouseMonitor != nil || followTimer != nil
    }

    @discardableResult
    func arm(start: @escaping () -> Void, stop: @escaping () -> Void) -> Bool {
        guard AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary) else {
            errorMessage = L10n.text("请先在“系统设置 > 隐私与安全性 > 辅助功能”中允许声迹控制键盘。")
            return false
        }
        disarm()
        errorMessage = nil
        insertedText = ""
        pendingTranscript = ""
        startAction = start
        stopAction = stop
        state = .armed
        showPanel()
        guard installMonitors() else {
            disarm()
            errorMessage = L10n.text("无法注册光标输入快捷键，请关闭占用 Command-Shift-S 的应用后重试。")
            return false
        }
        return true
    }

    func sync(transcript: String) {
        guard state == .transcribing || state == .finishing else { return }
        pendingTranscript = transcript
        scheduleSyncIfNeeded()
    }

    private func scheduleSyncIfNeeded() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.syncTask = nil
            self.writePendingTranscript(stopOnFailure: true)
            if self.pendingTranscript != self.insertedText {
                self.scheduleSyncIfNeeded()
            }
        }
    }

    func flushAndFinish() {
        syncTask?.cancel()
        syncTask = nil
        writePendingTranscript(stopOnFailure: false)
        disarm()
    }

    private func writePendingTranscript(stopOnFailure: Bool) {
        let transcript = pendingTranscript
        guard transcript != insertedText else { return }
        guard let target,
              NSRunningApplication(processIdentifier: target.processIdentifier) != nil else {
            handleWriteFailure(L10n.text("目标 App 已关闭，光标输入已停止。"), stopSession: stopOnFailure)
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            handleWriteFailure(L10n.text("目标 App 已失去焦点，光标输入已停止。"), stopSession: stopOnFailure)
            return
        }
        guard CursorInputWriter.replaceGeneratedText(
            previous: insertedText,
            current: transcript
        ) else {
            handleWriteFailure(L10n.text("目标位置不接受文本输入，光标输入已停止。"), stopSession: stopOnFailure)
            return
        }
        insertedText = transcript
    }

    func finish() {
        disarm()
    }

    func clearError() {
        errorMessage = nil
    }

    func disarm() {
        syncTask?.cancel()
        syncTask = nil
        keyMonitor.stop()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        panel = nil
        startAction = nil
        stopAction = nil
        target = nil
        pendingTranscript = ""
        state = .idle
    }

    @discardableResult
    private func installMonitors() -> Bool {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.movePanel() }
        }
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.movePanel() }
        }
        keyMonitor.mode = .armed
        return keyMonitor.start { [weak self] action in
            Task { @MainActor in
                switch action {
                case .start: self?.startFromHotkey()
                case .stop: self?.stopFromHotkey()
                case .none: break
                }
            }
        }
    }

    private func startFromHotkey() {
        guard state == .armed else { return }
        guard let target = CursorInputWriter.focusedTarget(),
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            errorMessage = L10n.text("请先将文本光标放到另一个 App 的输入位置，再按 Command-Shift-S。")
            refreshPanel()
            return
        }
        self.target = target
        insertedText = ""
        pendingTranscript = ""
        state = .transcribing
        keyMonitor.mode = .transcribing
        refreshPanel()
        startAction?()
    }

    private func stopFromHotkey() {
        guard state == .transcribing else { return }
        state = .finishing
        keyMonitor.mode = .finishing
        refreshPanel()
        stopAction?()
    }

    private func showPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 50),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        self.panel = panel
        refreshPanel()
        movePanel()
        panel.orderFrontRegardless()
    }

    private func refreshPanel() {
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: CursorInputOverlay(message: state.message, active: state == .transcribing))
    }

    private func movePanel() {
        guard let panel else { return }
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let size = panel.frame.size
        var origin = NSPoint(x: cursor.x + 18, y: cursor.y - size.height - 18)
        if origin.x + size.width > visible.maxX { origin.x = cursor.x - size.width - 18 }
        if origin.y < visible.minY { origin.y = cursor.y + 18 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    private func handleWriteFailure(_ message: String, stopSession: Bool) {
        let action = stopAction
        disarm()
        errorMessage = message
        if stopSession { action?() }
    }
}

private struct CursorInputOverlay: View {
    let message: String
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: active ? "waveform" : "cursorarrow.motionlines")
                .symbolEffect(.variableColor.iterative, isActive: active)
                .foregroundStyle(active ? Color.red : Color.accentColor)
            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.12))
        }
    }
}

private extension String {
    func commonPrefix(with other: String) -> String {
        var left = startIndex
        var right = other.startIndex
        while left < endIndex, right < other.endIndex, self[left] == other[right] {
            formIndex(after: &left)
            other.formIndex(after: &right)
        }
        return String(self[..<left])
    }
}
