import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreTokenRefreshCadenceTests {
    @Test(arguments: [
        (RefreshFrequency.oneMinute, 21600.0),
        (.twoMinutes, 21600.0),
        (.fiveMinutes, 21600.0),
        (.fifteenMinutes, 21600.0),
        (.thirtyMinutes, 21600.0),
    ])
    func `fixed refresh frequencies honor the six hour token floor`(
        frequency: RefreshFrequency,
        expectedSeconds: TimeInterval)
    {
        #expect(UsageStore.tokenFetchTTL(for: frequency) == expectedSeconds)
    }

    @Test(arguments: [RefreshFrequency.adaptive, .adaptiveAgentAware])
    func `adaptive refresh frequencies honor the six hour token floor`(frequency: RefreshFrequency) {
        #expect(UsageStore.tokenFetchTTL(for: frequency) == TimeInterval(6 * 60 * 60))
    }

    @Test
    func `manual refresh disables the automatic token cadence`() {
        #expect(UsageStore.tokenFetchTTL(for: .manual) == nil)
    }

    @Test(arguments: [
        (RefreshFrequency.oneMinute, 21600.0),
        (.fiveMinutes, 21600.0),
        (.fifteenMinutes, 21600.0),
        (.thirtyMinutes, 21600.0),
    ])
    func `global low power mode preserves the six hour token floor`(
        frequency: RefreshFrequency,
        expectedSeconds: TimeInterval)
    {
        #expect(UsageStore.tokenFetchTTL(
            for: frequency,
            lowPowerModeEnabled: true) == expectedSeconds)
    }

    @Test
    func `global low power mode preserves manual token refresh`() {
        #expect(UsageStore.tokenFetchTTL(
            for: .manual,
            lowPowerModeEnabled: true) == nil)
    }

    @Test(arguments: [RefreshFrequency.oneMinute, .twoMinutes, .fiveMinutes])
    func `fast provider refreshes cannot rescan local cost within six hours`(
        frequency: RefreshFrequency) async throws
    {
        let settings = testSettingsStore(suiteName: "UsageStoreTokenRefreshCadenceTests-\(frequency.rawValue)")
        settings.refreshFrequency = frequency
        settings.costUsageEnabled = true
        settings.providerDetectionCompleted = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let now = Date()
        store._setTokenSnapshotForTesting(Self.tokenSnapshot(updatedAt: now), provider: .codex)
        store.lastTokenFetchScope[.codex] = store.tokenSnapshotScopeSignature(for: .codex)
        var scanCount = 0
        store._test_tokenUsageRefreshOverride = { _, _ in scanCount += 1 }

        store.lastTokenFetchAt[.codex] = now.addingTimeInterval(-(6 * 60 * 60 - 60))
        await store.refreshTokenUsage(.codex, force: false)
        #expect(scanCount == 0)

        store.lastTokenFetchAt[.codex] = now.addingTimeInterval(-(6 * 60 * 60 + 1))
        await store.refreshTokenUsage(.codex, force: false)
        #expect(scanCount == 1)
    }

    private static func tokenSnapshot(updatedAt: Date) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 1,
            sessionCostUSD: 0.01,
            last30DaysTokens: 1,
            last30DaysCostUSD: 0.01,
            daily: [],
            updatedAt: updatedAt)
    }
}
