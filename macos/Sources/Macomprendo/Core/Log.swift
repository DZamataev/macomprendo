import OSLog

/// Shared `os.Logger` categories.
///
/// Never log transcript or LLM text at the default level. If you need it while
/// debugging, use `Log.providers.debug("… \(text, privacy: .private)")`.
enum Log {
    static let subsystem = "com.dzamataev.macomprendo"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let providers = Logger(subsystem: subsystem, category: "providers")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
