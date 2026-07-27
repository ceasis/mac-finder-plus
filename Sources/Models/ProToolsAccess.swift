import Foundation

enum ProToolsAccessPolicy {
    static let enabledDefaultsKey = "proTools.enabled"
    static let requiredPermissions: [CapturePermissionRequirement] = [
        .screenRecording,
        .microphone,
    ]

    static func missingPermissions(
        screenRecording: PermissionsManager.Status,
        microphone: PermissionsManager.Status
    ) -> [CapturePermissionRequirement] {
        var missing: [CapturePermissionRequirement] = []
        if screenRecording != .granted {
            missing.append(.screenRecording)
        }
        if microphone != .granted {
            missing.append(.microphone)
        }
        return missing
    }
}

struct ProToolsPermissionPrompt: Identifiable {
    let id = UUID()
    let missing: [CapturePermissionRequirement]

    let required = ProToolsAccessPolicy.requiredPermissions
}
