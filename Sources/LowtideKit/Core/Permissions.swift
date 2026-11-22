import AVFoundation
import ApplicationServices
import AppKit
import CoreGraphics
import IOKit.hid

/// The macOS permissions Lowtide can use, their state, and where to grant
/// each. Settings shows them all in one place; a feature asks at first use.
public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case accessibility, fullDiskAccess, microphone, inputMonitoring, screenRecording, automation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .fullDiskAccess: "Full Disk Access"
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen & System Audio Recording"
        case .automation: "Automation"
        }
    }

    /// What it's for, in one line.
    public var purpose: String {
        switch self {
        case .accessibility: "Dictation types into other apps; the menu bar manager reads and arranges icons."
        case .fullDiskAccess: "Cleanup, Leftovers and Secrets can see every app's data, and removals reach protected folders."
        case .microphone: "Dictation listens only while you hold the shortcut."
        case .inputMonitoring: "The dictation shortcut works in every app."
        case .screenRecording: "The menu bar manager can show the icons it hides."
        case .automation: "Asks Finder and System Events to empty the Trash, eject disks and manage login items."
        }
    }

    public var settingsURL: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .microphone: "Privacy_Microphone"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .screenRecording: "Privacy_ScreenCapture"
        case .automation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    public enum State: Sendable { case granted, denied, unknown }

    public var state: State {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .fullDiskAccess:
            if let allowed = TCCPreflight.state("kTCCServiceSystemPolicyAllFiles") { return allowed ? .granted : .denied }
            // Readable only with Full Disk Access (the system database: on
            // macOS 27 the user's can't be opened even with it).
            let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
            return FileManager.default.isReadableFile(atPath: probe) ? .granted : .denied
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .unknown
            default: return .denied
            }
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .unknown
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .automation:
            return .unknown
        }
    }

    /// Asks macOS (shows its prompt where there is one), else opens the pane.
    @MainActor
    public func request() {
        switch self {
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .microphone where AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .inputMonitoring:
            if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { NSWorkspace.shared.open(settingsURL) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(settingsURL) }
        default:
            NSWorkspace.shared.open(settingsURL)
        }
    }
}
