import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Covers extending plan-utilization history to every provider (not just Codex
/// and Claude) and persisting a human-readable account name for each bucket.
struct UsageStorePlanUtilizationAllProvidersTests {
    @MainActor
    @Test
    func `non codex provider records history scoped to identity account`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .cursor,
                accountEmail: "dev@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        await store.recordPlanUtilizationHistorySample(
            provider: .cursor,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let accountKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(provider: .cursor, snapshot: snapshot))
        let buckets = try #require(store.planUtilizationHistory[.cursor])
        let histories = try #require(buckets.accounts[accountKey])

        // The generic provider path now captures both the session and weekly windows.
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 10)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 25)
        // History menu surfaces once the provider has accumulated data.
        #expect(store.supportsPlanUtilizationHistory(for: .cursor))
    }

    @MainActor
    @Test
    func `account label prefers email then display name then key`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .cursor,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        await store.recordPlanUtilizationHistorySample(
            provider: .cursor,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let accountKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(provider: .cursor, snapshot: snapshot))
        let buckets = try #require(store.planUtilizationHistory[.cursor])
        #expect(buckets.label(for: accountKey) == "person@example.com")
    }

    @MainActor
    @Test
    func `provider without percent windows records nothing`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .cursor,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        await store.recordPlanUtilizationHistorySample(
            provider: .cursor,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(store.planUtilizationHistory[.cursor]?.isEmpty ?? true)
        #expect(!store.supportsPlanUtilizationHistory(for: .cursor))
    }

    @Test
    func `store round trips account labels`() throws {
        let suiteName = "PlanUtilizationAllProviders-\(UUID().uuidString)"
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName)
        let accountKey = "account-key-1"
        var buckets = PlanUtilizationHistoryBuckets(accounts: [
            accountKey: [planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 40),
            ])],
        ])
        buckets.setLabel("dev@example.com", for: accountKey)

        historyStore.save([.cursor: buckets])
        let loaded = try #require(historyStore.load()[.cursor])

        #expect(loaded.label(for: accountKey) == "dev@example.com")
        #expect(findSeries(loaded.accounts[accountKey] ?? [], name: .weekly, windowMinutes: 10080) != nil)
    }

    @Test
    func `labels for keys without history are dropped on save`() throws {
        let suiteName = "PlanUtilizationAllProviders-\(UUID().uuidString)"
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName)
        let liveKey = "live-key"
        var buckets = PlanUtilizationHistoryBuckets(accounts: [
            liveKey: [planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 40),
            ])],
        ])
        buckets.setLabel("live@example.com", for: liveKey)
        // Inject a dangling label directly to simulate post-migration state.
        buckets.accountLabels["stale-key"] = "stale@example.com"

        historyStore.save([.cursor: buckets])
        let loaded = try #require(historyStore.load()[.cursor])

        #expect(loaded.label(for: liveKey) == "live@example.com")
        #expect(loaded.accountLabels["stale-key"] == nil)
    }
}
