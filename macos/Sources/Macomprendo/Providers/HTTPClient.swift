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

/// Production `HTTPClient` backed by `URLSession`.
struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: Self.makeURLRequest(request))
            guard let http = response as? HTTPURLResponse else {
                throw MacomprendoError.providerStreamMalformed
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MacomprendoError.providerHTTP(
                    status: http.statusCode,
                    body: String(decoding: data, as: UTF8.self)
                )
            }
            return HTTPResponse(
                status: http.statusCode,
                headers: Self.headerDictionary(http),
                body: data
            )
        } catch let error as MacomprendoError {
            throw error
        } catch let error as URLError {
            throw Self.mapURLError(error, url: request.url)
        }
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: Self.makeURLRequest(request))
                    guard let http = response as? HTTPURLResponse else {
                        throw MacomprendoError.providerStreamMalformed
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Read a bounded prefix of the error page so the message is useful
                        // without buffering an unbounded response.
                        var errorBody = Data()
                        for try await byte in bytes {
                            errorBody.append(byte)
                            if errorBody.count >= 4096 { break }
                        }
                        throw MacomprendoError.providerHTTP(
                            status: http.statusCode,
                            body: String(decoding: errorBody, as: UTF8.self)
                        )
                    }

                    var buffer = Data()
                    buffer.reserveCapacity(Self.chunkFlushSize)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == Self.newline || buffer.count >= Self.chunkFlushSize {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch let error as MacomprendoError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: Self.mapURLError(error, url: request.url))
                } catch is CancellationError {
                    continuation.finish(throwing: MacomprendoError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private static let newline: UInt8 = 0x0A
    private static let chunkFlushSize = 4096

    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    static func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            result[key] = value
        }
        return result
    }

    static func mapURLError(_ error: URLError, url: URL) -> MacomprendoError {
        if error.code == .cancelled { return .cancelled }
        return .providerUnreachable(endpointName: url.host() ?? url.absoluteString)
    }
}
