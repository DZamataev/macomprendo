import Foundation

/// One dispatched Server-Sent Event. `data` is the joined `data:` lines.
/// The OpenAI terminator arrives as `SSEEvent(event: nil, data: "[DONE]")`.
struct SSEEvent: Equatable, Sendable {
    var event: String?
    var data: String

    init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental Server-Sent Events parser for OpenAI-compatible chat streams.
///
/// Implements the subset of the EventSource wire format that LLM APIs use:
/// `field: value` lines, comment lines starting with `:`, `data` accumulation,
/// the `event` field, and blank-line dispatch.
struct SSEParser {
    private var splitter = LineSplitter()
    private var currentEvent: String?
    private var dataLines: [String] = []

    /// Feeds raw bytes and returns every event completed by them.
    mutating func feed(_ data: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for line in splitter.feed(data) {
            if let event = consume(line) { events.append(event) }
        }
        return events
    }

    /// Call once the stream ends. Flushes a trailing unterminated line and dispatches
    /// whatever is still accumulated, so a server that omits the final blank line does
    /// not cost us the last token.
    mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if let tail = splitter.flush(), let event = consume(tail) { events.append(event) }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func consume(_ line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }                 // comment / heartbeat
        guard let colon = line.firstIndex(of: ":") else { return nil }

        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }       // exactly one space

        switch field {
        case "data": dataLines.append(value)
        case "event": currentEvent = value
        default: break                                        // id, retry, unknown
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        guard !dataLines.isEmpty else {
            currentEvent = nil
            return nil
        }
        let event = SSEEvent(event: currentEvent, data: dataLines.joined(separator: "\n"))
        dataLines.removeAll(keepingCapacity: true)
        currentEvent = nil
        return event
    }
}
