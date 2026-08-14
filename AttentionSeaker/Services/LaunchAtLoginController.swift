import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

@MainActor
protocol LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

@MainActor
struct LaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

