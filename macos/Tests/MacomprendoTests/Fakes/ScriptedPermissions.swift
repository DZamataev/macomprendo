import Foundation
@testable import Macomprendo

struct ScriptedPermissions: PermissionsChecking {
    var current: PermissionStatus = .granted
    var afterRequest: PermissionStatus = .granted

    func status(of kind: PermissionKind) async -> PermissionStatus { current }
    func request(_ kind: PermissionKind) async -> PermissionStatus { afterRequest }
    func openSystemSettings(for kind: PermissionKind) {}
}
