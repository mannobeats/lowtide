import ServiceManagement

/// Open at Login, through `SMAppService.mainApp` (not a launch agent:
/// launchd pins an agent to the signature that registered it, and the next
/// update is then killed at login).
public enum LoginItem {
    public static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    public static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    public static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

import AppKit
