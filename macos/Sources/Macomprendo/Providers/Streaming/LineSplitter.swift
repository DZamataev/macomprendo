import Foundation

/// Frames a byte stream into lines, tolerating arbitrary chunk boundaries.
///
/// The only component in the app that knows a network chunk may end mid-line or
/// mid-UTF-8-sequence. Terminators (`\n` and `\r\n`) are stripped; empty lines are
/// preserved because SSE uses them as event delimiters.
struct LineSplitter {
    private var buffer = Data()

    /// Appends `data` and returns every complete line it now contains.
    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: Self.newline) {
            let lineBytes = buffer[buffer.startIndex..<newlineIndex]
            lines.append(Self.decode(lineBytes))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }

    /// Returns any trailing bytes not terminated by a newline, and clears the buffer.
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let line = Self.decode(buffer[buffer.startIndex...])
        buffer.removeAll(keepingCapacity: true)
        return line
    }

    private static let newline: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    private static func decode(_ bytes: Data.SubSequence) -> String {
        var slice = bytes
        if slice.last == carriageReturn { slice = slice.dropLast() }
        return String(decoding: slice, as: UTF8.self)
    }
}
