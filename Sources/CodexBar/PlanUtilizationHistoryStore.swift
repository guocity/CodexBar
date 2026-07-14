import CodexBarCore
import Foundation

struct PlanUtilizationSeriesName: RawRepresentable, Hashable, Codable, ExpressibleByStringLiteral, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    static let session: Self = "session"
    static let weekly: Self = "weekly"
    static let opus: Self = "opus"

    func canonicalWindowMinutes(_ windowMinutes: Int) -> Int {
        switch self {
        case .session where (295...305).contains(windowMinutes):
            300
        case .weekly where (10070...10090).contains(windowMinutes):
            10080
        default:
            windowMinutes
        }
    }
}

struct PlanUtilizationHistoryEntry: Codable, Equatable, Hashable, Sendable {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
}

struct PlanUtilizationSeriesHistory: Codable, Equatable, Sendable {
    let name: PlanUtilizationSeriesName
    let windowMinutes: Int
    let entries: [PlanUtilizationHistoryEntry]

    init(name: PlanUtilizationSeriesName, windowMinutes: Int, entries: [PlanUtilizationHistoryEntry]) {
        self.name = name
        self.windowMinutes = windowMinutes
        self.entries = entries.sorted { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            if lhs.usedPercent != rhs.usedPercent {
                return lhs.usedPercent < rhs.usedPercent
            }
            let lhsReset = lhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
            let rhsReset = rhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
            return lhsReset < rhsReset
        }
    }

    var latestCapturedAt: Date? {
        self.entries.last?.capturedAt
    }
}

struct PlanUtilizationHistoryBuckets: Equatable, Sendable {
    var preferredAccountKey: String?
    var unscoped: [PlanUtilizationSeriesHistory] = []
    var accounts: [String: [PlanUtilizationSeriesHistory]] = [:]
    /// Human-readable name for each account key (email/login → displayName → key).
    /// Persisted alongside history so each account can be identified without
    /// reversing the opaque account-key hash.
    var accountLabels: [String: String] = [:]

    func histories(for accountKey: String?) -> [PlanUtilizationSeriesHistory] {
        guard let accountKey, !accountKey.isEmpty else { return self.unscoped }
        return self.accounts[accountKey] ?? []
    }

    func label(for accountKey: String?) -> String? {
        guard let accountKey, !accountKey.isEmpty else { return nil }
        return self.accountLabels[accountKey]
    }

    mutating func setHistories(_ histories: [PlanUtilizationSeriesHistory], for accountKey: String?) {
        let sorted = Self.sortedHistories(histories)
        guard let accountKey, !accountKey.isEmpty else {
            self.unscoped = sorted
            return
        }
        if sorted.isEmpty {
            self.accounts.removeValue(forKey: accountKey)
            self.accountLabels.removeValue(forKey: accountKey)
        } else {
            self.accounts[accountKey] = sorted
        }
    }

    mutating func setLabel(_ label: String?, for accountKey: String?) {
        guard let accountKey, !accountKey.isEmpty else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return }
        // Only retain labels for keys that actually hold history.
        guard self.accounts[accountKey] != nil else { return }
        self.accountLabels[accountKey] = trimmed
    }

    var isEmpty: Bool {
        self.unscoped.isEmpty && self.accounts.values.allSatisfy(\.isEmpty)
    }

    private static func sortedHistories(_ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory] {
        histories.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }
}

private struct ProviderHistoryFile: Codable, Sendable {
    let preferredAccountKey: String?
    let unscoped: [PlanUtilizationSeriesHistory]
    let accounts: [String: [PlanUtilizationSeriesHistory]]
    let accountLabels: [String: String]
}

private struct ProviderHistoryDocument: Codable, Sendable {
    let version: Int
    let preferredAccountKey: String?
    let unscoped: [PlanUtilizationSeriesHistory]
    let accounts: [String: [PlanUtilizationSeriesHistory]]
    let accountLabels: [String: String]
}

struct PlanUtilizationHistoryStore: Sendable {
    /// v1: history-only. v2: adds per-account human-readable `accountLabels`.
    fileprivate static let providerSchemaVersion = 2
    fileprivate static let supportedSchemaVersions: Set<Int> = [1, 2]

    let directoryURL: URL?

    init(directoryURL: URL? = Self.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    static func defaultAppSupport() -> Self {
        Self()
    }

    func load() -> [UsageProvider: PlanUtilizationHistoryBuckets] {
        self.loadProviderFiles()
    }

    /// Loads the persisted histories on a utility-priority detached task.
    ///
    /// The on-disk decode is synchronous I/O + JSON parsing that can take
    /// ~150 ms for mature two-year histories and must not run on the app
    /// startup main thread. The returned dictionary is safe to apply on the
    /// main actor once decoding completes.
    func loadAsync() async -> [UsageProvider: PlanUtilizationHistoryBuckets] {
        await Task.detached(priority: .utility) { self.load() }.value
    }

    func save(_ providers: [UsageProvider: PlanUtilizationHistoryBuckets]) {
        guard let directoryURL = self.directoryURL else { return }
        // Hard prohibition: a test process must never write to a real history folder. The default
        // store already resolves to nil under tests, but this also blocks any store explicitly
        // constructed with a non-temporary path, so a stray test can never overwrite the user's
        // real plan-utilization history. The assertion makes such a mistake fail loudly in DEBUG.
        if Self.isRunningTests, !Self.isWithinTemporaryDirectory(directoryURL) {
            assertionFailure("Refusing to write plan-utilization history to a real folder during tests: \(directoryURL.path)")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]

            for provider in UsageProvider.allCases {
                let fileURL = self.providerFileURL(for: provider)
                let buckets = providers[provider] ?? PlanUtilizationHistoryBuckets()
                let unscoped = Self.sortedHistories(buckets.unscoped)
                let accounts = Self.sortedAccounts(buckets.accounts)
                guard !unscoped.isEmpty || !accounts.isEmpty else {
                    try? FileManager.default.removeItem(at: fileURL)
                    continue
                }

                let accountLabels = buckets.accountLabels.filter { key, _ in accounts[key] != nil }
                let payload = ProviderHistoryDocument(
                    version: Self.providerSchemaVersion,
                    preferredAccountKey: buckets.preferredAccountKey,
                    unscoped: unscoped,
                    accounts: accounts,
                    accountLabels: accountLabels)
                let data = try encoder.encode(payload)
                try data.write(to: fileURL, options: Data.WritingOptions.atomic)
            }
        } catch {
            // Best-effort persistence only.
        }
    }

    private func loadProviderFiles() -> [UsageProvider: PlanUtilizationHistoryBuckets] {
        guard self.directoryURL != nil else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var output: [UsageProvider: PlanUtilizationHistoryBuckets] = [:]

        for provider in UsageProvider.allCases {
            let fileURL = self.providerFileURL(for: provider)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? decoder.decode(ProviderHistoryDocument.self, from: data)
            else {
                continue
            }

            let history = ProviderHistoryFile(
                preferredAccountKey: decoded.preferredAccountKey,
                unscoped: decoded.unscoped,
                accounts: decoded.accounts,
                accountLabels: decoded.accountLabels)
            output[provider] = Self.decodeProvider(history)
        }

        return output
    }

    private static func decodeProviders(
        _ providers: [String: ProviderHistoryFile]) -> [UsageProvider: PlanUtilizationHistoryBuckets]
    {
        var output: [UsageProvider: PlanUtilizationHistoryBuckets] = [:]
        for (rawProvider, providerHistory) in providers {
            guard let provider = UsageProvider(rawValue: rawProvider) else { continue }
            output[provider] = Self.decodeProvider(providerHistory)
        }
        return output
    }

    private static func decodeProvider(_ providerHistory: ProviderHistoryFile) -> PlanUtilizationHistoryBuckets {
        let accounts: [String: [PlanUtilizationSeriesHistory]] = Dictionary(
            uniqueKeysWithValues: providerHistory.accounts.compactMap { accountKey, histories in
                let sorted = Self.sortedHistories(histories)
                guard !sorted.isEmpty else { return nil }
                return (accountKey, sorted)
            })
        let accountLabels = providerHistory.accountLabels.filter { key, _ in accounts[key] != nil }
        return PlanUtilizationHistoryBuckets(
            preferredAccountKey: providerHistory.preferredAccountKey,
            unscoped: self.sortedHistories(providerHistory.unscoped),
            accounts: accounts,
            accountLabels: accountLabels)
    }

    private static func sortedAccounts(
        _ accounts: [String: [PlanUtilizationSeriesHistory]]) -> [String: [PlanUtilizationSeriesHistory]]
    {
        Dictionary(
            uniqueKeysWithValues: accounts.compactMap { accountKey, histories in
                let sorted = Self.sortedHistories(histories)
                guard !sorted.isEmpty else { return nil }
                return (accountKey, sorted)
            })
    }

    private static func sortedHistories(_ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory] {
        self.sanitizedHistories(histories).sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    private static func sanitizedHistories(_ histories: [PlanUtilizationSeriesHistory])
    -> [PlanUtilizationSeriesHistory] {
        histories.filter { history in
            history.windowMinutes > 0 && !history.entries.isEmpty
        }
    }

    private static func defaultDirectoryURL() -> URL? {
        // Never resolve the real history folder inside a test process. A UsageStore built with the
        // default store would otherwise load and (on the next recorded sample) overwrite the user's
        // real plan-utilization history — leaking synthetic test entries into ~/Library. Tests that
        // genuinely exercise persistence pass an explicit temporary directory instead.
        if Self.isRunningTests { return nil }
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return dir.appendingPathComponent("history", isDirectory: true)
    }

    /// Mirrors `SettingsStore.isRunningTests` but stays nonisolated so the default directory can be
    /// resolved off the main actor. Kept in sync deliberately — both guard real files from tests.
    private nonisolated static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["TESTING_LIBRARY_VERSION"] != nil { return true }
        if env["SWIFT_TESTING"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }()

    /// Whether `url` lives under the system temporary directory — the only place a test is allowed
    /// to persist history. Uses standardized (symlink-resolved) paths so `/var` vs `/private/var`
    /// can't slip a real path past the guard.
    private nonisolated static func isWithinTemporaryDirectory(_ url: URL) -> Bool {
        let tempPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == tempPath || candidate.hasPrefix(tempPath + "/")
    }

    private func providerFileURL(for provider: UsageProvider) -> URL {
        let directoryURL = self.directoryURL ?? URL(fileURLWithPath: "/dev/null", isDirectory: true)
        return directoryURL.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
    }
}

extension ProviderHistoryDocument {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard PlanUtilizationHistoryStore.supportedSchemaVersions.contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported provider history schema version \(version)")
        }
        self.version = version
        self.preferredAccountKey = try container.decodeIfPresent(String.self, forKey: .preferredAccountKey)
        self.unscoped = try container.decode([PlanUtilizationSeriesHistory].self, forKey: .unscoped)
        self.accounts = try container.decode([String: [PlanUtilizationSeriesHistory]].self, forKey: .accounts)
        self.accountLabels = try container
            .decodeIfPresent([String: String].self, forKey: .accountLabels) ?? [:]
    }
}

/// One-shot synchronization primitive used by `UsageStore.init` to defer the
/// utility-priority plan-utilization history load until a test chooses to
/// release it. The default `nil` gate is open and the load proceeds immediately.
///
/// Used to verify that `UsageStore.init` returns before disk I/O completes and
/// that the history is applied exactly once after the gate opens.
final class PlanUtilizationHistoryLoadGate: @unchecked Sendable {
    private enum State {
        case closed
        case open
        case cancelled
    }

    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private var state: State = .closed

    init() {}

    var isOpen: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.state == .open
    }

    var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.state == .cancelled
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            switch self.state {
            case .open:
                self.lock.unlock()
                continuation.resume(returning: true)
            case .cancelled:
                self.lock.unlock()
                continuation.resume(returning: false)
            case .closed:
                self.continuations.append(continuation)
                self.lock.unlock()
            }
        }
    }

    func open() {
        self.lock.lock()
        guard self.state == .closed else {
            self.lock.unlock()
            return
        }
        self.state = .open
        let pending = self.continuations
        self.continuations.removeAll()
        self.lock.unlock()
        for continuation in pending {
            continuation.resume(returning: true)
        }
    }

    /// Cancels this one-shot gate and resumes pending or future waiters with
    /// `false`. Cancellation is sticky so it cannot race ahead of `wait()` and
    /// lose the wakeup that drains the load task.
    func cancel() {
        self.lock.lock()
        guard self.state == .closed else {
            self.lock.unlock()
            return
        }
        self.state = .cancelled
        let pending = self.continuations
        self.continuations.removeAll()
        self.lock.unlock()
        for continuation in pending {
            continuation.resume(returning: false)
        }
    }
}
