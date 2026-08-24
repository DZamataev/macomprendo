import Foundation

/// A single HTTP request, independent of the transport that executes it.
struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
    var timeout: TimeInterval

    init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 10
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// A completed, buffered HTTP response.
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup, because HTTP header names are case-insensitive
    /// and different servers/transports normalise them differently.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The single seam through which all Macomprendo network traffic flows.
///
/// - `send` buffers the whole response and throws `MacomprendoError.providerHTTP`
///   for any non-2xx status.
/// - `stream` yields raw byte chunks with **no framing guarantees**: a chunk may end
///   mid-line or mid-UTF-8-sequence. Callers must frame the bytes themselves
///   (see `LineSplitter`). It throws `MacomprendoError.providerHTTP` before yielding
///   any chunk when the status is non-2xx.
///
/// Both entry points map transport failures to `MacomprendoError.providerUnreachable`
/// and task cancellation to `MacomprendoError.cancelled`.
protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error>
}
