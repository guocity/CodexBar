import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NotionPluginTests {
    private static let now = Date(timeIntervalSince1970: 1_785_600_000)
    private static let spaces = #"{"user":{"notion_user":{"user":{"value":{"value":{"id":"user","email":"fixture@example.test"}}}},"space":{"free":{"value":{"id":"00000000-0000-0000-0000-000000000000","name":"Personal","subscription_tier":"free"}},"paid":{"value":{"id":"11111111-2222-3333-4444-555555555555","name":"Fixture team","subscription_tier":"business"}}}}}"#

    #if os(macOS)
    @Test(arguments: BundledPluginTestSupport.engines)
    func `automatic import reaches Edge after Chrome and maps its Notion session`(
        engine: ProviderPluginEngineKind) async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await KeychainCacheStore.withServiceOverrideForTesting("notion-edge-\(UUID().uuidString)") {
            try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(directory) {
                let runtime = try Self.runtime(engine: engine, usage: """
                {"window":{"window":"6h","used":25,"limit":100},"resetsInSeconds":3600,
                "billingPeriodWindow":{"used":18,"limit":100,"periodEndMs":1788000000000}}
                """)
                let visited = Calls()
                let broker = ProviderPluginCookieBroker(
                    provider: .notion,
                    domains: runtime.manifest.cookieDomains,
                    settings: .init(cookieSource: .auto),
                    batches: { _, _ in Issue.record("Notion must import opaque cookie jars"); return nil },
                    jarImporter: {
                        try BrowserCookieImportSupport.collectSessions(
                            from: BrowserCookieImportSupport.importOrder(for: .notion),
                            missingError: nil,
                            logger: { _ in },
                            load: { browser in
                                visited.append(browser.rawValue)
                                guard browser == .edge else { return [] }
                                let cookie = try #require(HTTPCookie(properties: [
                                    .domain: "notion.so", .path: "/", .name: "token_v2",
                                    .value: "synthetic", .secure: "TRUE",
                                ]))
                                return [.init(
                                    header: "", source: "Microsoft Edge Profile 2", origin: "",
                                    records: [ProviderPluginCookieRecord(cookie: cookie)])]
                            })
                    },
                    policy: runtime.manifest.cookiePolicy,
                    sessionFileURL: directory.appendingPathComponent("notion-session.json"))
                // Engine callbacks do not retain the task-local test cache scope.
                let session = try #require(try broker.nextSession(domain: "app.notion.com"))
                let usage = try await runtime.fetchUsage(
                    now: Self.now,
                    cookieSessionResolver: { _, _ in session },
                    cookieSessionValidator: { _, id in #expect(id == session.id) })
                #expect(visited.values == ["chrome", "edge"])
                #expect(usage.primary?.usedPercent == 25)
                #expect(usage.primary?.resetsAt == Self.now.addingTimeInterval(3600))
                #expect(usage.secondary?.usedPercent == 18)
                #expect(usage.identity?.accountOrganization == "Fixture team")
            }
        }
    }

    @Test
    func `Notion browser order retains the background no prompt gate`() {
        let browsers = BrowserCookieImportSupport.importOrder(for: .notion)
        #expect(browsers == [.chrome, .edge])
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            ProviderInteractionContext.$current.withValue(.background) {
                KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                    .interactionRequired
                } operation: {
                    #expect(browsers.allSatisfy { !BrowserCookieAccessGate.shouldAttempt($0) })
                }
                KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                    .allowed
                } operation: {
                    #expect(browsers.allSatisfy { BrowserCookieAccessGate.shouldAttempt($0) })
                }
            }
        }
    }
    #endif

    @Test(arguments: BundledPluginTestSupport.engines)
    func `workspace selection identity and overage match native snapshots`(
        engine: ProviderPluginEngineKind) async throws
    {
        for preferred in ["", "11111111222233334444555555555555", "unknown"] {
            let runtime = try Self.runtime(
                engine: engine,
                usage: #"{"window":{"window":"6h","used":60,"limit":50},"resetsInSeconds":0,"billingPeriodWindow":{"used":18,"limit":100,"periodEndMs":1788000000000}}"#)
            let usage = try await runtime.fetchUsage(
                settings: ["WORKSPACE_ID": preferred],
                now: Self.now,
                cookieSource: .manual,
                cookieSessionResolver: Self.session)
            #expect(usage.primary?.usedPercent == 120)
            #expect(usage.primary?.resetsAt == Self.now)
            #expect(usage.primary?.windowMinutes == 360)
            #expect(usage.secondary?.usedPercent == 18)
            #expect(usage.secondary?.windowMinutes == 43200)
            #expect(usage.secondary?.resetsAt == Date(timeIntervalSince1970: 1_788_000_000))
            #expect(usage.identity?.providerID == .notion)
            #expect(usage.identity?.accountEmail == "fixture@example.test")
            #expect(usage.identity?.accountOrganization == "Fixture team")
            #expect(usage.identity?.accountID == "user")
            #expect(usage.identity?.loginMethod == "Business")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unmeasurable windows and monthly sentinel collisions stay omitted`(
        engine: ProviderPluginEngineKind) async throws
    {
        for token in ["30d", "720h", "43200m", "nonsense"] {
            let runtime = try Self.runtime(engine: engine, usage: """
            {"window":{"window":"\(token)","used":-3,"limit":100},"resetsInSeconds":-1,
            "billingPeriodWindow":{"used":25,"limit":0}}
            """)
            let usage = try await runtime.fetchUsage(cookieSource: .manual, cookieSessionResolver: Self.session)
            #expect(usage.primary?.usedPercent == 0)
            #expect(usage.primary?.windowMinutes == nil)
            #expect(usage.primary?.resetsAt == nil)
            #expect(usage.secondary == nil)
        }
        let runtime = try Self.runtime(engine: engine, usage: #"{"window":{"used":25},"billingPeriodWindow":{}}"#)
        let usage = try await runtime.fetchUsage(cookieSource: .manual, cookieSessionResolver: Self.session)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `ambiguous identity invalid payloads and unsupported workspaces fail`(
        engine: ProviderPluginEngineKind) async throws
    {
        for payload in [
            "{}",
            "[]",
            "not-json",
            #"{"window":{"used":"25","limit":100}}"#,
            #"{"status":"not_applicable"}"#,
        ] {
            let runtime = try Self.runtime(engine: engine, usage: payload)
            await #expect(throws: (any Error).self) {
                try await runtime.fetchUsage(cookieSource: .manual, cookieSessionResolver: Self.session)
            }
        }
        let runtime = try Self.runtime(engine: engine, usage: "{}", spaces: #"{"first":{},"second":{}}"#)
        await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(cookieSource: .manual, cookieSessionResolver: Self.session)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a successful usage response validates the session and a fresh rejected profile stops`(
        engine: ProviderPluginEngineKind) async throws
    {
        let validated = Calls()
        let runtime = try Self.runtime(engine: engine, usage: #"{"window":{"used":1,"limit":100}}"#)
        _ = try await runtime.fetchUsage(
            cookieSessionResolver: Self.session,
            cookieSessionValidator: { domain, id in validated.append("\(domain):\(id)") })
        #expect(validated.values == ["app.notion.com:synthetic-session"])
        let failing = try Self.runtime(engine: engine, usage: "{}", status: 401)
        let rejected = Calls()
        await #expect(throws: (any Error).self) {
            try await failing.fetchUsage(
                cookieSessionResolver: Self.session,
                cookieSessionInvalidator: { _, id in rejected.append(id) },
                cookieSessionValidator: { _, _ in
                    Issue.record("A rejected session cannot be persisted")
                })
        }
        #expect(rejected.values == ["synthetic-session"])
    }

    private static let session: ProviderPluginRuntime.CookieSessionResolver = { _, _ in
        .init(
            header: "token_v2=synthetic",
            source: "Fixture",
            origin: "https://app.notion.com",
            id: "synthetic-session")
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        usage: String,
        spaces: String = Self.spaces,
        status: Int = 200) throws
        -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime(
            "notion",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.host == "app.notion.com")
                #expect(request.value(forHTTPHeaderField: "Cookie") == "token_v2=synthetic")
                if request.url?.lastPathComponent == "getCreditRateLimitStatus" {
                    let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
                    #expect(body["spaceId"] == "11111111-2222-3333-4444-555555555555")
                }
                let data = request.url?.lastPathComponent == "getSpaces" ? spaces : usage
                let url = try #require(request.url)
                return try (Data(data.utf8), #require(HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil)))
            })
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] {
            self.lock.withLock { self.storage }
        }

        func append(_ value: String) { self.lock.withLock { self.storage.append(value) } }
    }
}
