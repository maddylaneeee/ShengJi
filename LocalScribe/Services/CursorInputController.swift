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

@MainActor
@Observable
final class CursorInputController {
    enum State: Equatable {
        case idle
        case armed
        case transcribing

        var message: String {
            switch self {
            case .idle: ""
            case .armed: L10n.text("将光标移到输入位置，按 Command-Shift-S 开始转录")
            case .transcribing: L10n.text("正在转录，按 Esc 退出")
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    private var panel: NSPanel?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var mouseMonitor: Any?
    private var followTimer: Timer?
    private var insertedText = ""
    private var startAction: (() -> Void)?
    private var stopAction: (() -> Void)?

    var isArmed: Bool { state != .idle }
    var isTranscribing: Bool { state == .transcribing }
    var hasActiveResources: Bool {
        panel != nil || globalKeyMonitor != nil || localKeyMonitor != nil || mouseMonitor != nil || followTimer != nil
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
        startAction = start
        stopAction = stop
        state = .armed
        showPanel()
        installMonitors()
        return true
    }

    func sync(transcript: String) {
        guard state == .transcribing, transcript != insertedText else { return }
        let prefix = transcript.commonPrefix(with: insertedText)
        let removedCount = insertedText.count - prefix.count
        if removedCount > 0 { postBackspaces(removedCount) }
        let suffix = String(transcript.dropFirst(prefix.count))
        if !suffix.isEmpty { postText(suffix) }
        insertedText = transcript
    }

    func finish() {
        disarm()
    }

    func clearError() {
        errorMessage = nil
    }

    func disarm() {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        mouseMonitor = nil
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        panel = nil
        startAction = nil
        stopAction = nil
        state = .idle
    }

    private func installMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handle(event) ? nil : event
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.movePanel() }
        }
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.movePanel() }
        }
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        switch CursorInputHotkeyPolicy.action(
            state: state,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        ) {
        case .start:
            state = .transcribing
            refreshPanel()
            startAction?()
            return true
        case .stop:
            let action = stopAction
            disarm()
            action?()
            return true
        case .none:
            return false
        }
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

    private func postBackspaces(_ count: Int) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for _ in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    private func postText(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 32, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<end])
            let utf16 = Array(chunk.utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
            index = end
        }
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
