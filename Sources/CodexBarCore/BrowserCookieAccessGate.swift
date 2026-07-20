import Foundation

#if os(macOS)
import os.lock
import SweetCookieKit

enum BrowserCookieStoreAccessDecision: Equatable {
    case allowed
    case suppressed
}

struct BrowserCookieStoreAccessSuppressedError: LocalizedError {
    var errorDescription: String? {
        "Browser cookie store access is suppressed for this process."
    }
}

public enum BrowserCookieAccessGate {
    private struct State {
        var loaded = false
        var deniedUntilByBrowser: [String: Date] = [:]
        var chromiumFamilyDeniedUntil: Date?
    }

    private final class ExplicitRetryScope: @unchecked Sendable {
        private struct State {
            var selectedBrowser: Browser?
            var cookieReadClaimed = false
        }

        private let lock = OSAllocatedUnfairLock<State>(initialState: State())

        func allows(_ browser: Browser) -> Bool {
            self.lock.withLock { state in
                if let selectedBrowser = state.selectedBrowser {
                    return selectedBrowser == browser && !state.cookieReadClaimed
                }
                state.selectedBrowser = browser
                return true
            }
        }

        func contains(_ browser: Browser) -> Bool {
            self.lock.withLock { $0.selectedBrowser == browser }
        }

        func claimCookieRead(for browser: Browser) -> Bool {
            self.lock.withLock { state in
                guard state.selectedBrowser == browser, !state.cookieReadClaimed else { return false }
                state.cookieReadClaimed = true
                return true
            }
        }
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let defaultsKey = "browserCookieAccessDeniedUntil"
    private static let chromiumFamilyDefaultsKey = "__chromiumFamily__"
    private static let cooldownInterval: TimeInterval = 60 * 60 * 6
    private static let log = CodexBarLog.logger(LogCategories.browserCookieGate)
    @TaskLocal private static var explicitRetryScope: ExplicitRetryScope?
    @TaskLocal private static var deniedBrowsersForTesting: [Browser]?

    static let allowTestCookieAccessEnvironmentKey = "CODEXBAR_ALLOW_TEST_BROWSER_COOKIE_ACCESS"

    public static func requiresKeychainPromptAcknowledgement(for browsers: [Browser]) -> Bool {
        browsers.contains(where: \.usesKeychainForCookieDecryption)
    }

    static func cookieStoreAccessDecision(
        homeDirectories: [URL],
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> BrowserCookieStoreAccessDecision
    {
        guard KeychainTestSafety.isRunningUnderTests(processName: processName, environment: environment),
              environment[self.allowTestCookieAccessEnvironmentKey] != "1"
        else {
            return .allowed
        }

        let defaultHomes = Set(BrowserCookieClient.defaultHomeDirectories().map(Self.normalizedPath))
        let usesDefaultHome = homeDirectories.contains { defaultHomes.contains(Self.normalizedPath($0)) }
        return usesDefaultHome ? .suppressed : .allowed
    }

    public static func shouldAttempt(_ browser: Browser, now: Date = Date()) -> Bool {
        guard browser.usesKeychainForCookieDecryption else { return true }
        guard !KeychainAccessGate.isDisabled else { return false }
        if self.deniedBrowsersForTesting?.contains(browser) == true {
            return self.isExplicitRetryAllowed(for: browser)
        }
        let shouldCheckKeychain = self.lock.withLock { state in
            self.loadIfNeeded(&state)
            if let blockedUntil = state.deniedUntilByBrowser[browser.rawValue] {
                if blockedUntil > now {
                    if self.isExplicitRetryAllowed(for: browser) {
                        self.log.info(
                            "Explicit browser cookie retry allowed",
                            metadata: ["browser": browser.displayName])
                        return true
                    }
                    self.log.debug(
                        "Cookie access blocked",
                        metadata: ["browser": browser.displayName, "until": "\(blockedUntil.timeIntervalSince1970)"])
                    return false
                }
                state.deniedUntilByBrowser.removeValue(forKey: browser.rawValue)
                self.persist(state)
            }
            if let blockedUntil = state.chromiumFamilyDeniedUntil {
                if blockedUntil > now {
                    if self.isExplicitRetryAllowed(for: browser) {
                        self.log.info(
                            "Explicit Chromium-family cookie retry allowed",
                            metadata: ["browser": browser.displayName])
                        return true
                    }
                    self.log.debug(
                        "Chromium-family cookie access blocked",
                        metadata: ["browser": browser.displayName, "until": "\(blockedUntil.timeIntervalSince1970)"])
                    return false
                }
                state.chromiumFamilyDeniedUntil = nil
                self.persist(state)
            }
            return true
        }
        guard shouldCheckKeychain else { return false }

        let requiresInteraction = self.chromiumKeychainRequiresInteraction(for: browser)
        if requiresInteraction {
            // Never open a Safe Storage prompt from background refresh — that spams Keychain ACL
            // entries when the user keeps pressing Refresh after a misleading error.
            guard ProviderInteractionContext.current == .userInitiated else {
                self.log.info(
                    "Skipping background Chromium cookie import; Keychain prompt would be required",
                    metadata: ["browser": browser.displayName])
                return false
            }
            self.recordDenied(for: browser, now: now)
            if self.isExplicitRetryAllowed(for: browser) {
                self.log.info(
                    "Browser cookie interaction allowed for explicit retry",
                    metadata: ["browser": browser.displayName])
                return true
            }
            self.log.info(
                "Cookie access requires keychain interaction; suppressing Chromium family",
                metadata: ["browser": browser.displayName])
            return false
        }
        self.log.debug("Cookie access allowed", metadata: ["browser": browser.displayName])
        return true
    }

    public static func withExplicitRetry<T>(_ operation: () throws -> T) rethrows -> T {
        try self.$explicitRetryScope.withValue(ExplicitRetryScope()) {
            try operation()
        }
    }

    public static func withExplicitRetry<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$explicitRetryScope.withValue(ExplicitRetryScope()) {
            try await operation()
        }
    }

    static func withDeniedBrowsersForTesting<T>(
        _ browsers: [Browser],
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$deniedBrowsersForTesting.withValue(browsers) {
            try await operation()
        }
    }

    static func operationPreservingAccessContext<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T) -> @Sendable () throws -> T
    {
        let interaction = ProviderInteractionContext.current
        let retryScope = self.explicitRetryScope
        return {
            try ProviderInteractionContext.$current.withValue(interaction) {
                try self.$explicitRetryScope.withValue(retryScope) {
                    try operation()
                }
            }
        }
    }

    public static func recordIfNeeded(_ error: Error, now: Date = Date()) {
        guard let error = error as? BrowserCookieError else { return }
        guard case .accessDenied = error else { return }
        self.recordDenied(for: error.browser, now: now)
    }

    public static func recordDenied(for browser: Browser, now: Date = Date()) {
        guard browser.usesKeychainForCookieDecryption else { return }
        let blockedUntil = now.addingTimeInterval(self.cooldownInterval)
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            state.deniedUntilByBrowser[browser.rawValue] = blockedUntil
            state.chromiumFamilyDeniedUntil = blockedUntil
            self.persist(state)
        }
        self.log
            .info(
                "Browser cookie access denied; suppressing Chromium family",
                metadata: [
                    "browser": browser.displayName,
                    "until": "\(blockedUntil.timeIntervalSince1970)",
                ])
    }

    public static func hasActiveDenial(for browser: Browser, now: Date = Date()) -> Bool {
        guard browser.usesKeychainForCookieDecryption else { return false }
        return self.lock.withLock { state in
            self.loadIfNeeded(&state)
            guard let blockedUntil = state.deniedUntilByBrowser[browser.rawValue] else { return false }
            guard blockedUntil <= now else { return true }
            state.deniedUntilByBrowser.removeValue(forKey: browser.rawValue)
            state.chromiumFamilyDeniedUntil = state.deniedUntilByBrowser.values.max()
            self.persist(state)
            return false
        }
    }

    static func recordAllowed(for browser: Browser) {
        guard browser.usesKeychainForCookieDecryption,
              ProviderInteractionContext.current == .userInitiated,
              self.explicitRetryScope?.contains(browser) == true
        else { return }
        let clearedCooldown = self.lock.withLock { state in
            self.loadIfNeeded(&state)
            guard state.deniedUntilByBrowser[browser.rawValue] != nil,
                  state.chromiumFamilyDeniedUntil != nil
            else { return false }
            state.deniedUntilByBrowser.removeValue(forKey: browser.rawValue)
            state.chromiumFamilyDeniedUntil = state.deniedUntilByBrowser.values.max()
            self.persist(state)
            return true
        }
        guard clearedCooldown else { return }
        self.log.info(
            "Explicit browser cookie retry succeeded",
            metadata: ["browser": browser.displayName])
    }

    static func claimExplicitRetryCookieReadIfNeeded(for browser: Browser) -> Bool {
        guard browser.usesKeychainForCookieDecryption,
              ProviderInteractionContext.current == .userInitiated,
              let retryScope = self.explicitRetryScope,
              retryScope.contains(browser)
        else { return true }
        let hasActiveBrowserCooldown = self.lock.withLock { state in
            self.loadIfNeeded(&state)
            return state.deniedUntilByBrowser[browser.rawValue] != nil
        }
        guard hasActiveBrowserCooldown else { return true }
        return retryScope.claimCookieRead(for: browser)
    }

    public static func resetForTesting() {
        self.lock.withLock { state in
            state.loaded = true
            state.deniedUntilByBrowser.removeAll()
            state.chromiumFamilyDeniedUntil = nil
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }

    private static func isExplicitRetryAllowed(for browser: Browser) -> Bool {
        ProviderInteractionContext.current == .userInitiated && self.explicitRetryScope?.allows(browser) == true
    }

    private static func chromiumKeychainRequiresInteraction(for browser: Browser) -> Bool {
        let labels = browser.safeStorageLabels.isEmpty ? self.safeStorageLabels : browser.safeStorageLabels
        for label in labels {
            switch KeychainAccessPreflight.checkGenericPassword(service: label.service, account: label.account) {
            case .allowed:
                return false
            case .interactionRequired:
                return true
            case .notFound, .failure:
                continue
            }
        }
        return false
    }

    private static let safeStorageLabels: [(service: String, account: String)] = Browser.safeStorageLabels

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard let raw = UserDefaults.standard.dictionary(forKey: self.defaultsKey) as? [String: Double] else {
            return
        }
        state.chromiumFamilyDeniedUntil = raw[self.chromiumFamilyDefaultsKey].map(Date.init(timeIntervalSince1970:))
        state.deniedUntilByBrowser = raw
            .filter { $0.key != self.chromiumFamilyDefaultsKey }
            .mapValues { Date(timeIntervalSince1970: $0) }
        if state.chromiumFamilyDeniedUntil == nil {
            // Existing per-browser cooldowns become family-wide on upgrade.
            state.chromiumFamilyDeniedUntil = state.deniedUntilByBrowser.values.max()
        }
    }

    private static func persist(_ state: State) {
        var raw = state.deniedUntilByBrowser.mapValues { $0.timeIntervalSince1970 }
        raw[self.chromiumFamilyDefaultsKey] = state.chromiumFamilyDeniedUntil?.timeIntervalSince1970
        UserDefaults.standard.set(raw, forKey: self.defaultsKey)
    }
}

extension BrowserCookieClient {
    public func codexBarStores(for browser: Browser) throws -> [BrowserCookieStore] {
        guard BrowserCookieAccessGate.cookieStoreAccessDecision(
            homeDirectories: self.configuration.homeDirectories) == .allowed
        else {
            throw BrowserCookieStoreAccessSuppressedError()
        }
        guard BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }
        return self.resolvedChromiumAwareStores(for: browser)
    }

    public func codexBarRecords(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        logger: ((String) -> Void)? = nil) throws -> [BrowserCookieStoreRecords]
    {
        guard BrowserCookieAccessGate.cookieStoreAccessDecision(
            homeDirectories: self.configuration.homeDirectories) == .allowed
        else {
            throw BrowserCookieStoreAccessSuppressedError()
        }
        guard BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }
        guard BrowserCookieAccessGate.claimExplicitRetryCookieReadIfNeeded(for: browser) else { return [] }
        do {
            let discovered = self.stores(for: browser)
            let stores = discovered.isEmpty
                ? self.knownChromiumCookieStores(for: browser)
                : discovered
            guard !stores.isEmpty else {
                throw BrowserCookieError.notFound(
                    browser: browser,
                    details: "\(browser.displayName) cookie store not found.")
            }
            if discovered.isEmpty {
                logger?(
                    "\(browser.displayName): using direct cookie DB paths (profile root listing unavailable)")
            }
            let records = try stores.compactMap { store -> BrowserCookieStoreRecords? in
                let loaded = try self.records(matching: query, in: store, logger: logger)
                guard !loaded.isEmpty else { return nil }
                return BrowserCookieStoreRecords(store: store, records: loaded)
            }
            BrowserCookieAccessGate.recordAllowed(for: browser)
            return records
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            throw error
        }
    }

    private func resolvedChromiumAwareStores(for browser: Browser) -> [BrowserCookieStore] {
        let discovered = self.stores(for: browser)
        if !discovered.isEmpty {
            return discovered
        }
        // SweetCookieKit discovers Chromium profiles by listing the profile root. On some
        // macOS setups that listing is blocked while Default/Cookies remains readable —
        // probe known paths so Chrome Safe Storage is used instead of falling through to
        // unrelated browsers (Comet/Atlas) and prompting the wrong Keychain item.
        return self.knownChromiumCookieStores(for: browser)
    }

    private func knownChromiumCookieStores(for browser: Browser) -> [BrowserCookieStore] {
        guard browser.usesChromiumProfileStore,
              let relativePath = browser.chromiumProfileRelativePath
        else {
            return []
        }

        let profileNames = ["Default"] + (1 ... 10).map { "Profile \($0)" }
        var stores: [BrowserCookieStore] = []
        for home in self.configuration.homeDirectories {
            let root = home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: true)
            for profileName in profileNames {
                let profileDir = root.appendingPathComponent(profileName, isDirectory: true)
                let legacyDB = profileDir.appendingPathComponent("Cookies")
                let networkDB = profileDir
                    .appendingPathComponent("Network", isDirectory: true)
                    .appendingPathComponent("Cookies")
                let candidates: [(BrowserCookieStoreKind, URL)] = [
                    (.primary, legacyDB),
                    (.network, networkDB),
                ]
                for (kind, databaseURL) in candidates {
                    guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }
                    let labelSuffix = kind == .network ? " (Network)" : ""
                    stores.append(BrowserCookieStore(
                        browser: browser,
                        profile: BrowserProfile(id: profileDir.path, name: profileName),
                        kind: kind,
                        label: "\(browser.displayName) \(profileName)\(labelSuffix)",
                        databaseURL: databaseURL))
                }
            }
        }
        return stores
    }
}
#else
public enum BrowserCookieAccessGate {
    public static func requiresKeychainPromptAcknowledgement(for browsers: [Browser]) -> Bool {
        false
    }

    public static func shouldAttempt(_ browser: Browser, now: Date = Date()) -> Bool {
        true
    }

    public static func withExplicitRetry<T>(_ operation: () throws -> T) rethrows -> T {
        try operation()
    }

    public static func withExplicitRetry<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await operation()
    }

    static func withDeniedBrowsersForTesting<T>(
        _: [Browser],
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await operation()
    }

    public static func recordIfNeeded(_ error: Error, now: Date = Date()) {}
    public static func recordDenied(for browser: Browser, now: Date = Date()) {}
    public static func hasActiveDenial(for browser: Browser, now: Date = Date()) -> Bool {
        false
    }

    public static func resetForTesting() {}
}
#endif
