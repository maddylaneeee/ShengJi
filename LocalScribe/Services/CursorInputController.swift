import AppKit
import Carbon
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

struct CursorAccessibilityTarget {
    let element: AXUIElement
    let processIdentifier: pid_t
    let insertionLocation: CFIndex
    let initialSelectionLength: CFIndex
}

enum CursorAccessibilityWriter {
    static func replacementRange(
        previous: String,
        insertionLocation: CFIndex,
        initialSelectionLength: CFIndex
    ) -> CFRange {
        CFRange(
            location: insertionLocation,
            length: previous.isEmpty ? initialSelectionLength : previous.utf16.count
        )
    }

    static func focusedTarget() -> CursorAccessibilityTarget? {
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
        return CursorAccessibilityTarget(
            element: element,
            processIdentifier: processIdentifier,
            insertionLocation: range.location,
            initialSelectionLength: range.length
        )
    }

    static func replaceGeneratedText(
        previous: String,
        current: String,
        target: CursorAccessibilityTarget,
        beforePaste: () -> Void
    ) -> Bool {
        var replacementRange = replacementRange(
            previous: previous,
            insertionLocation: target.insertionLocation,
            initialSelectionLength: target.initialSelectionLength
        )
        guard let rangeValue = AXValueCreate(.cfRange, &replacementRange),
              AXUIElementSetAttributeValue(
                target.element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success else { return false }
        // Editors such as Notes can report a successful AX selected-text write
        // without changing their document. Always perform the actual edit through
        // the keyboard paste path after using AX only to select our prior output.
        beforePaste()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(current, forType: .string),
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

private struct CursorPasteboardSnapshot: Sendable {
    let items: [[String: Data]]

    static func capture() -> CursorPasteboardSnapshot {
        let captured = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
        return CursorPasteboardSnapshot(items: captured)
    }

    @MainActor
    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restored = items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in stored {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

private final class CursorGlobalHotkey {
    private static let signature: OSType = 0x534A4349 // "SJCI"
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var registeredID: UInt32?
    private var action: (() -> Void)?

    var isRegistered: Bool { hotKey != nil }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let registration = Unmanaged<CursorGlobalHotkey>
                    .fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.signature == CursorGlobalHotkey.signature,
                      hotKeyID.id == registration.registeredID else {
                    return OSStatus(eventNotHandledErr)
                }
                registration.action?()
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            unregister()
            return false
        }
        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registrationStatus == noErr else {
            unregister()
            return false
        }
        registeredID = id
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        registeredID = nil
        action = nil
    }

    deinit { unregister() }
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
    private let commandHotkey = CursorGlobalHotkey()
    private let escapeHotkey = CursorGlobalHotkey()
    private var mouseMonitor: Any?
    private var followTimer: Timer?
    private var insertedText = ""
    private var pendingTranscript = ""
    private var syncTask: Task<Void, Never>?
    private var target: CursorAccessibilityTarget?
    private var pasteboardSnapshot: CursorPasteboardSnapshot?
    private var startAction: (() -> Void)?
    private var stopAction: (() -> Void)?

    var isArmed: Bool { state != .idle }
    var isTranscribing: Bool { state == .transcribing }
    var hasActiveResources: Bool {
        panel != nil || commandHotkey.isRegistered || escapeHotkey.isRegistered || mouseMonitor != nil || followTimer != nil
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
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.writePendingTranscript(stopOnFailure: true)
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
        guard CursorAccessibilityWriter.replaceGeneratedText(
            previous: insertedText,
            current: transcript,
            target: target,
            beforePaste: { [weak self] in
                guard let self, self.pasteboardSnapshot == nil else { return }
                self.pasteboardSnapshot = .capture()
            }
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
        commandHotkey.unregister()
        escapeHotkey.unregister()
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
        if let snapshot = pasteboardSnapshot {
            pasteboardSnapshot = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                snapshot.restore()
            }
        }
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
        return commandHotkey.register(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(cmdKey | shiftKey),
            id: 1
        ) { [weak self] in
            Task { @MainActor in self?.startFromHotkey() }
        }
    }

    private func startFromHotkey() {
        guard state == .armed else { return }
        guard let target = CursorAccessibilityWriter.focusedTarget(),
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            errorMessage = L10n.text("请先将文本光标放到另一个 App 的输入位置，再按 Command-Shift-S。")
            refreshPanel()
            return
        }
        self.target = target
        insertedText = ""
        pendingTranscript = ""
        state = .transcribing
        refreshPanel()
        let commandRegistered = commandHotkey.register(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(cmdKey | shiftKey),
            id: 2
        ) { [weak self] in
            Task { @MainActor in self?.stopFromHotkey() }
        }
        let escapeRegistered = escapeHotkey.register(
            keyCode: UInt32(kVK_Escape),
            modifiers: 0,
            id: 3
        ) { [weak self] in
            Task { @MainActor in self?.stopFromHotkey() }
        }
        guard commandRegistered, escapeRegistered else {
            handleWriteFailure(
                L10n.text("无法注册光标输入退出快捷键，流程已停止。"),
                stopSession: true
            )
            return
        }
        startAction?()
    }

    private func stopFromHotkey() {
        guard state == .transcribing else { return }
        commandHotkey.unregister()
        escapeHotkey.unregister()
        state = .finishing
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
