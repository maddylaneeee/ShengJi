import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Speech

enum AppPermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var title: String {
        switch self {
        case .notDetermined: L10n.text("尚未请求")
        case .authorized: L10n.text("已允许")
        case .denied: L10n.text("未允许")
        case .restricted: L10n.text("受系统限制")
        }
    }

    var symbol: String {
        switch self {
        case .notDetermined: "questionmark.circle"
        case .authorized: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .restricted: "exclamationmark.triangle.fill"
        }
    }

    var canRequest: Bool { self == .notDetermined }
    var shouldOpenSettings: Bool { self == .denied || self == .restricted }
}

enum ManagedPermission: Sendable {
    case microphone
    case speechRecognition
    case screenRecording
    case accessibility

    var settingsAnchor: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
    }
}

@MainActor
@Observable
final class PermissionCenter {
    private static let screenPermissionRequestedKey = "ScreenCapturePermissionRequested"

    private(set) var microphone: AppPermissionState = .notDetermined
    private(set) var speechRecognition: AppPermissionState = .notDetermined
    private(set) var screenRecording: AppPermissionState = .notDetermined
    private(set) var accessibility: AppPermissionState = .notDetermined

    init() {
        refresh()
    }

    func refresh() {
        microphone = Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
        speechRecognition = Self.state(for: SFSpeechRecognizer.authorizationStatus())
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .authorized
        } else if UserDefaults.standard.bool(forKey: Self.screenPermissionRequestedKey) {
            screenRecording = .denied
        } else {
            screenRecording = .notDetermined
        }
        accessibility = AXIsProcessTrusted() ? .authorized : .denied
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    func requestSpeechRecognition() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
        refresh()
    }

    func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: Self.screenPermissionRequestedKey)
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        refresh()
    }

    func openSystemSettings(for permission: ManagedPermission) {
        let primary = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)")
        let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        if let primary, NSWorkspace.shared.open(primary) { return }
        if let fallback { NSWorkspace.shared.open(fallback) }
    }

    static func state(for status: AVAuthorizationStatus) -> AppPermissionState {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    static func state(for status: SFSpeechRecognizerAuthorizationStatus) -> AppPermissionState {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}
