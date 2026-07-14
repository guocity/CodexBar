import CodexBarCore
import Foundation
import Security

// MARK: - Constants & configuration keys
//
// This whole feature is intentionally self-contained in `Sources/CodexBar/Telemetry/`
// so it survives upstream merges without touching shared files. The only edit outside
// this folder is a single link added to `AboutPane` (see PreferencesAboutPane.swift).
//
// Telemetry is reported to a self-hosted pipeline:
//   https://github.com/guocity/cloudflare_tunnel_mqtt_server
// The HTTP ingest endpoint accepts `POST /api/telemetry` with a `Bearer` token and any
// JSON object as the body. `service_id` / `service_type` are fixed to "codexbar" and are
// not user-editable (hidden in the UI).
//
// ─────────────────────────────────────────────────────────────────────────────
//  WIRE FORMAT
// ─────────────────────────────────────────────────────────────────────────────
//
//  Transport ── a single HTTPS request per event:
//
//      POST <serverURL>/api/telemetry            e.g. https://m2-telemetry.lgnat.com/api/telemetry
//      Content-Type:  application/json
//      Authorization: Bearer <token>             the keychain-stored auth token
//
//  Body ── one flat JSON object. Every send layers these three keys on top
//  (caller-supplied keys with the same name are overwritten):
//
//      service_id    "codexbar"            — fixed; identifies this client
//      service_type  "codexbar"            — fixed; selects the destination hypertable
//      metric        e.g. "plan_utilization" — label for the kind of record
//
//  The server stores the whole object as a `jsonb` payload (one row per POST).
//
//  What we actually send ── plan-utilization usage, the same data persisted to
//  the per-provider history files (~/Library/Application Support/
//  com.steipete.codexbar/history/<provider>.json). Each history data point becomes
//  one telemetry row: the provider, the account it belongs to (opaque hash only —
//  see privacy note), the usage series, and the captured percentage. Fields mirror
//  `PlanUtilizationHistoryEntry` + its series:
//
//      {
//        "service_id":    "codexbar",
//        "service_type":  "codexbar",
//        "metric":        "plan_utilization",
//        "provider":      "codex",            // UsageProvider.rawValue
//        "account_key":   "9f3c…",            // SHA-256 account hash, or omitted if unscoped
//        "series":        "weekly",           // session | weekly | opus | window-<N>m
//        "window_minutes": 10080,             // the rate window the percent covers
//        "used_percent":  42.5,               // PlanUtilizationHistoryEntry.usedPercent
//        "captured_at":   "2026-06-16T20:00:00Z", // .capturedAt (ISO-8601 UTC)
//        "resets_at":     "2026-06-23T00:00:00Z"  // .resetsAt, omitted when nil
//      }
//
//  Privacy ── the request is HTTPS only (ATS blocks plaintext http), so the body
//  and Bearer token are TLS-encrypted in transit. The human-readable account label
//  (email/login) stored in the local history JSON is deliberately NOT sent; only
//  the opaque SHA-256 `account_key` leaves the device, so no PII reaches the server.
//
//  A Claude account with session + weekly + opus windows therefore emits three
//  rows per capture; Codex emits one row per plan-utilization lane; other providers
//  emit one row per percent-bearing rate window. Rows are produced at the same
//  cadence the history files are written (one new sample per ~hour bucket).
//
//  Success is any 2xx; the response body is ignored. Non-2xx, transport failures,
//  a disabled toggle, or a missing token cause the send to be skipped/logged
//  (and surfaced to the settings page via `TelemetryError`).

enum TelemetryConstants {
    /// Fixed service identity. Hidden from the UI on purpose.
    static let serviceID = "codexbar"
    static let serviceType = "codexbar"

    /// Default ingest host (Cloudflare Tunnel → ingest service). User-editable.
    static let defaultServerURL = "https://m2-telemetry.lgnat.com"

    /// HTTP ingest path appended to the configured server URL.
    static let ingestPath = "/api/telemetry"

    enum DefaultsKey {
        static let enabled = "telemetryEnabled"
        static let serverURL = "telemetryServerURL"
    }
}

// MARK: - Errors

enum TelemetryError: LocalizedError {
    case disabled
    case missingToken
    case invalidServerURL
    case requestFailed(status: Int, body: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Telemetry is turned off."
        case .missingToken:
            "No auth token is configured."
        case .invalidServerURL:
            "The server URL is not valid."
        case let .requestFailed(status, body):
            body.isEmpty ? "Server returned HTTP \(status)." : "Server returned HTTP \(status): \(body)"
        case let .transport(message):
            message
        }
    }
}

// MARK: - Usage sample

/// One plan-utilization data point flattened for the wire. Mirrors a
/// `PlanUtilizationHistoryEntry` plus the provider/account/series it belongs to.
///
/// Note: only the opaque `accountKey` (a SHA-256 hash) is sent — never the
/// human-readable account label/email. The hash still uniquely separates
/// accounts in dashboards without putting PII on the wire or in the server DB.
struct TelemetryUsageSample {
    let provider: String
    let accountKey: String?
    let series: String
    let windowMinutes: Int
    let usedPercent: Double
    let capturedAt: Date
    let resetsAt: Date?

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The JSON body fields for this sample (service identity is added by the sender).
    var payload: [String: Any] {
        var fields: [String: Any] = [
            "provider": self.provider,
            "series": self.series,
            "window_minutes": self.windowMinutes,
            "used_percent": self.usedPercent,
            "captured_at": Self.iso(self.capturedAt),
        ]
        if let accountKey { fields["account_key"] = accountKey }
        if let resetsAt { fields["resets_at"] = Self.iso(resetsAt) }
        return fields
    }
}

// MARK: - Keychain-backed token store

/// Stores the telemetry auth token in the login keychain, mirroring the pattern used by
/// `KeychainZaiTokenStore`. The token doubles as the HTTP Bearer token on the server.
struct KeychainTelemetryTokenStore {
    private let service = "com.steipete.CodexBar"
    private let account = "telemetry-auth-token"

    func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }

    func storeToken(_ token: String?) {
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned, !cleaned.isEmpty else {
            self.deleteToken()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(cleaned.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (key, value) in attributes { addQuery[key] = value }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Service

/// Shared entry point for reporting telemetry. Call `TelemetryService.shared.send(...)`
/// from anywhere; it no-ops when telemetry is disabled or unconfigured.
@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    private let tokenStore = KeychainTelemetryTokenStore()
    private let log = CodexBarLog.logger("telemetry")
    private let sessionFactory: @Sendable () -> URLSession

    init(sessionFactory: @escaping @Sendable () -> URLSession = TelemetryService.makeSession) {
        self.sessionFactory = sessionFactory
    }

    // MARK: Configuration accessors (single source of truth: UserDefaults + keychain)

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: TelemetryConstants.DefaultsKey.enabled)
    }

    var serverURLString: String {
        let stored = UserDefaults.standard.string(forKey: TelemetryConstants.DefaultsKey.serverURL)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? TelemetryConstants.defaultServerURL : trimmed
    }

    func loadToken() -> String? {
        self.tokenStore.loadToken()
    }

    func storeToken(_ token: String?) {
        self.tokenStore.storeToken(token)
    }

    // MARK: Sending

    /// Fire-and-forget send. Silently no-ops when disabled/unconfigured and logs failures.
    @discardableResult
    func send(_ fields: [String: Any], metric: String = "event") async -> Bool {
        do {
            try await self.sendThrowing(fields, metric: metric)
            return true
        } catch TelemetryError.disabled, TelemetryError.missingToken {
            return false
        } catch {
            self.log.error("Telemetry send failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Usage reporting

    /// Mirrors freshly recorded plan-utilization samples to the telemetry server.
    /// Called from the history-recording path so the server sees the same data
    /// points that land in the per-provider history JSON. No-ops when disabled.
    @discardableResult
    func send(usageSamples samples: [TelemetryUsageSample]) async -> Int {
        guard self.isEnabled else { return 0 }
        var sent = 0
        for sample in samples where await self.send(sample.payload, metric: "plan_utilization") {
            sent += 1
        }
        return sent
    }

    /// Reads the persisted plan-utilization history and sends the latest data point
    /// of every series (per provider/account). Backs the "Send latest usage" button;
    /// throws so the settings page can show why nothing was sent.
    @discardableResult
    func sendLatestUsage() async throws -> Int {
        guard self.isEnabled else { throw TelemetryError.disabled }
        guard let token = self.loadToken(), !token.isEmpty else { throw TelemetryError.missingToken }

        let samples = Self.latestUsageSamples()
        guard !samples.isEmpty else { return 0 }

        var sent = 0
        for sample in samples {
            try await self.sendThrowing(sample.payload, metric: "plan_utilization")
            sent += 1
        }
        return sent
    }

    /// The most recent entry of every series in the on-disk history, flattened into
    /// telemetry samples (opaque account key only — labels are intentionally dropped).
    static func latestUsageSamples() -> [TelemetryUsageSample] {
        let buckets = PlanUtilizationHistoryStore().load()
        var result: [TelemetryUsageSample] = []
        for (provider, providerBuckets) in buckets {
            Self.appendLatest(from: providerBuckets.unscoped, provider: provider, accountKey: nil, into: &result)
            for (accountKey, histories) in providerBuckets.accounts {
                Self.appendLatest(from: histories, provider: provider, accountKey: accountKey, into: &result)
            }
        }
        return result
    }

    private static func appendLatest(
        from histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        accountKey: String?,
        into result: inout [TelemetryUsageSample])
    {
        for history in histories {
            guard let entry = history.entries.last else { continue }
            result.append(TelemetryUsageSample(
                provider: provider.rawValue,
                accountKey: accountKey,
                series: history.name.rawValue,
                windowMinutes: history.windowMinutes,
                usedPercent: entry.usedPercent,
                capturedAt: entry.capturedAt,
                resetsAt: entry.resetsAt))
        }
    }

    /// Throwing send used where callers want to surface the outcome (e.g. the test button).
    func sendThrowing(_ fields: [String: Any], metric: String = "event") async throws {
        guard self.isEnabled else { throw TelemetryError.disabled }
        guard let token = self.loadToken(), !token.isEmpty else { throw TelemetryError.missingToken }

        let base = self.serverURLString.hasSuffix("/")
            ? String(self.serverURLString.dropLast())
            : self.serverURLString
        guard let url = URL(string: base + TelemetryConstants.ingestPath) else {
            throw TelemetryError.invalidServerURL
        }

        var payload = fields
        payload["service_id"] = TelemetryConstants.serviceID
        payload["service_type"] = TelemetryConstants.serviceType
        payload["metric"] = metric

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        request.timeoutInterval = 30

        try await self.performTransportRequest(request, metric: metric)
    }

    // MARK: Transport

    /// Fresh ephemeral sessions avoid stale HTTP/2 connections through Cloudflare tunnels.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .notConnectedToInternet,
    ]

    private static let maxTransportRetries = 2

    private func performTransportRequest(_ request: URLRequest, metric: String) async throws {
        var lastTransportError: Error?
        for attempt in 0 ... Self.maxTransportRetries {
            if attempt > 0 {
                let delay = 0.5 * pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            let session = self.sessionFactory()
            defer { session.finishTasksAndInvalidate() }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw TelemetryError.transport("No HTTP response.")
                }
                guard (200 ... 299).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    throw TelemetryError.requestFailed(status: http.statusCode, body: String(body.prefix(200)))
                }
                self.log.debug("Telemetry \(metric) sent (\(http.statusCode))")
                return
            } catch let error as TelemetryError {
                throw error
            } catch {
                guard attempt < Self.maxTransportRetries,
                      Self.isTransientTransportError(error)
                else {
                    throw TelemetryError.transport(error.localizedDescription)
                }
                lastTransportError = error
                self.log.warning(
                    "Telemetry transport failed (attempt \(attempt + 1)/\(Self.maxTransportRetries + 1)): "
                        + error.localizedDescription)
            }
        }

        throw TelemetryError.transport(lastTransportError?.localizedDescription ?? "Transport failed.")
    }

    private static func isTransientTransportError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return self.transientURLErrorCodes.contains(urlError.code)
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return self.transientURLErrorCodes.contains(URLError.Code(rawValue: nsError.code))
    }
}
