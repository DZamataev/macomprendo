import Foundation

/// The bundle holding `Resources/Icons`.
enum ResourceBundle {
    static var current: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
}
