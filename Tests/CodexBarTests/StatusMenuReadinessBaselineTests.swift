import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `reopening root menu resyncs readiness baseline so reverted store data still refreshes`() {
        // Regression for the readiness-signature optimization (#1351): the baseline is no longer
        // recomputed on every store change while menus are closed, so it must be re-anchored when a
        // root menu opens. Otherwise a closed-then-reopened menu built from new data, followed by an
        // open-menu change that reverts to the *previous* baseline value, would be treated as
        // "unchanged" and skip the rebuild, leaving the visible menu showing stale content.
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()

        // Root open anchors the baseline to snapshot A. Normalize via an explicit comparison so the
        // assertion below is independent of whatever the controller's initial baseline happened to be.
        controller.menuWillOpen(menu)
        _ = controller.didMenuAdjunctReadinessChange()
        controller.menuDidClose(menu)

        // Closed store change to B: the optimization intentionally skips recomputing the baseline here.
        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)

        // Reopening the root menu rebuilds from B and must re-anchor the baseline to B.
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)

        // Reverting to A (the value the *first* baseline held) must still register as a change.
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        #expect(controller.didMenuAdjunctReadinessChange())
    }

    @Test
    func `root open during in flight refresh preserves stale content and does not resync baseline`() {
        // When `refreshMenuForOpenIfNeeded` keeps existing menu content during an in-flight provider
        // refresh, the readiness baseline must not be re-anchored to live store data. Otherwise the
        // refresh-completion store mutation would compare equal against the prematurely resynced baseline
        // and skip the rebuild, leaving stale content visible (#1351).
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        store.isRefreshing = true
        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        // Stale content was preserved: the menu is still behind the current content version.
        #expect(controller.menuNeedsRefresh(menu))

        store.isRefreshing = false
        // Refresh completion must still register as a readiness change so the open menu can rebuild.
        #expect(controller.didMenuAdjunctReadinessChange())
    }

    private func enableOnlyCodexForReadinessBaseline(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func makeReadinessBaselineTokenSnapshot(
        sessionTokens: Int,
        sessionCostUSD: Double,
        last30DaysTokens: Int,
        last30DaysCostUSD: Double,
        updatedAt: Date) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-24",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: sessionTokens,
                    costUSD: last30DaysCostUSD,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: updatedAt)
    }
}
