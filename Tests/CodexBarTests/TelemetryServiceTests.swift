import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct TelemetryServiceTests {
    private func makeService() -> TelemetryService {
        TelemetryService {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TelemetryStubURLProtocol.self]
            return URLSession(configuration: configuration)
        }
    }

    private func enableTelemetry(serverURL: String = "https://telemetry.test") -> TelemetryService {
        UserDefaults.standard.set(true, forKey: TelemetryConstants.DefaultsKey.enabled)
        UserDefaults.standard.set(serverURL, forKey: TelemetryConstants.DefaultsKey.serverURL)
        let service = self.makeService()
        service.storeToken("tlm_test_token")
        return service
    }

    @Test
    func `send posts to configured ingest endpoint`() async throws {
        TelemetryStubURLProtocol.reset()
        TelemetryStubURLProtocol.handler = { request in
            TelemetryStubURLProtocol.requests.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (Data(), response)
        }
        defer { TelemetryStubURLProtocol.reset() }

        let service = self.enableTelemetry()
        try await service.sendThrowing(["provider": "codex"], metric: "plan_utilization")

        #expect(TelemetryStubURLProtocol.requests.count == 1)
        let request = try #require(TelemetryStubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://telemetry.test/api/telemetry")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tlm_test_token")
        #expect(request.value(forHTTPHeaderField: "Connection") == "close")
    }

    @Test
    func `send retries transient connection loss`() async throws {
        TelemetryStubURLProtocol.reset()
        TelemetryStubURLProtocol.handler = { request in
            TelemetryStubURLProtocol.requests.append(request)
            if TelemetryStubURLProtocol.requests.count == 1 {
                throw URLError(.networkConnectionLost)
            }
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (Data(), response)
        }
        defer { TelemetryStubURLProtocol.reset() }

        let service = self.enableTelemetry()
        try await service.sendThrowing(["provider": "codex"], metric: "plan_utilization")

        #expect(TelemetryStubURLProtocol.requests.count == 2)
    }

    @Test
    func `send surfaces HTTP failures without retrying`() async throws {
        TelemetryStubURLProtocol.reset()
        TelemetryStubURLProtocol.handler = { request in
            TelemetryStubURLProtocol.requests.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(#"{"error":"Unauthorized"}"#.utf8), response)
        }
        defer { TelemetryStubURLProtocol.reset() }

        let service = self.enableTelemetry()

        await #expect(throws: TelemetryError.self) {
            try await service.sendThrowing(["provider": "codex"], metric: "plan_utilization")
        }
        #expect(TelemetryStubURLProtocol.requests.count == 1)
    }
}

final class TelemetryStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, URLResponse))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        self.handler = nil
        self.requests = []
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }

        do {
            let (data, response) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
