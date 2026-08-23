import Foundation
import ServiceManagement
import os

/// Launch-at-login, backed by `SMAppService`.
///
/// The registration lives in the system's login item database, not in this
/// app's defaults, so the checkbox reads back from the service rather than from
/// a stored flag. Turning it on the first time makes macOS show a notification
/// that a new login item was added; that is the system's doing, not a bug.
enum LoginItem {
    private static let logger = Logger(subsystem: "dev.kadran", category: "loginitem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns whether the change took effect.
    ///
    /// Fails when the app runs outside a bundle — `swift run` during
    /// development — because there is nothing for the system to register.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            logger.error("login item \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
