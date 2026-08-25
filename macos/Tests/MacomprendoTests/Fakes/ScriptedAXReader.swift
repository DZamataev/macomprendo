import Foundation
@testable import Macomprendo

struct ScriptedAXReader: AXReading {
    var text: String?
    func focusedSelectedText() -> String? { text }
}
