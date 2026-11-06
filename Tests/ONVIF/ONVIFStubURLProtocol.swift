import Foundation
import os

/// In-process HTTP stand-in for an ONVIF camera, so `ONVIFClient` request and
/// response handling can be tested without any network traffic. Each test registers
/// a handler under its own made-up host name and passes `configuration()` to the
/// client; requests to an unregistered host fail like an unreachable camera.
internal final class ONVIFStubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/soap+xml; charset=utf-8"]
        var body = Data()
    }

    /// Receives the request and its body (URLSession moves the body into a stream).
    typealias Handler = @Sendable (URLRequest, Data) -> Reply

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func unregister(host: String) {
        _ = handlers.withLock { $0.removeValue(forKey: host) }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return configuration
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = handler(request, Self.body(of: request))
        guard let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Replies are delivered synchronously in startLoading; nothing to cancel.
    }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Collects request bodies seen by a stub handler (handlers run off the test thread).
internal final class CapturedBodies: Sendable {
    private let bodies = OSAllocatedUnfairLock<[Data]>(initialState: [])

    var all: [Data] { bodies.withLock { $0 } }

    func append(_ body: Data) {
        bodies.withLock { $0.append(body) }
    }
}
