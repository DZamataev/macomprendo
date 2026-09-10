import Foundation

/// The bundle holding `Resources/Icons` and `Resources/Licenses`.
enum ResourceBundle {
    static var current: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
}
