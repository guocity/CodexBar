import AppKit
import Foundation
import Testing
@testable import CodexBar

struct StatsProviderSortTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a provider whose session (~5h) and/or weekly (~7d) window resets at the given
    /// offsets from `now`. A `nil` offset omits that window entirely.
    private func provider(
        id: String,
        sessionResetIn: TimeInterval?,
        weeklyResetIn: TimeInterval? = nil) -> StatsProvider
    {
        var windows: [StatsWindow] = []
        if let sessionResetIn {
            windows.append(self.window(name: "primary", windowMinutes: 300, resetIn: sessionResetIn))
        }
        if let weeklyResetIn {
            windows.append(self.window(name: "secondary", windowMinutes: 10080, resetIn: weeklyResetIn))
        }
        return StatsProvider(id: id, name: id, baseColor: .red, windows: windows)
    }

    private func window(name: String, windowMinutes: Int, resetIn: TimeInterval) -> StatsWindow {
        StatsWindow(
            name: name,
            displayName: name,
            windowMinutes: windowMinutes,
            entries: [StatsEntry(
                capturedAt: self.now.addingTimeInterval(-60),
                usedPercent: 10,
                resetsAt: self.now.addingTimeInterval(resetIn))])
    }

    @Test
    func `default order preserves the incoming sequence`() {
        let providers = [
            self.provider(id: "a", sessionResetIn: 3 * 3600),
            self.provider(id: "b", sessionResetIn: 1 * 3600),
            self.provider(id: "c", sessionResetIn: 2 * 3600),
        ]
        let sorted = statsSortedProviders(providers, mode: .defaultOrder, now: self.now)
        #expect(sorted.map(\.id) == ["a", "b", "c"])
    }

    @Test
    func `session reset sort orders by soonest upcoming reset`() {
        let providers = [
            self.provider(id: "a", sessionResetIn: 3 * 3600),
            self.provider(id: "b", sessionResetIn: 1 * 3600),
            self.provider(id: "c", sessionResetIn: 2 * 3600),
        ]
        let sorted = statsSortedProviders(providers, mode: .sessionReset, now: self.now)
        #expect(sorted.map(\.id) == ["b", "c", "a"])
    }

    @Test
    func `providers without a matching reset sort to the end, keeping their order`() {
        let providers = [
            self.provider(id: "noReset1", sessionResetIn: nil),
            self.provider(id: "soon", sessionResetIn: 1 * 3600),
            self.provider(id: "noReset2", sessionResetIn: nil),
        ]
        let sorted = statsSortedProviders(providers, mode: .sessionReset, now: self.now)
        #expect(sorted.map(\.id) == ["soon", "noReset1", "noReset2"])
    }

    @Test
    func `weekly reset sort ignores the session window`() {
        let providers = [
            // Earliest session but latest weekly — weekly sort must rank it last.
            self.provider(id: "a", sessionResetIn: 1 * 3600, weeklyResetIn: 6 * 86400),
            self.provider(id: "b", sessionResetIn: 3 * 3600, weeklyResetIn: 2 * 86400),
        ]
        let sorted = statsSortedProviders(providers, mode: .weeklyReset, now: self.now)
        #expect(sorted.map(\.id) == ["b", "a"])
    }

    @Test
    func `zero usage window has no recorded usage`() {
        let window = StatsWindow(
            name: "primary",
            displayName: "Session",
            windowMinutes: 300,
            entries: [
                StatsEntry(capturedAt: self.now.addingTimeInterval(-3600), usedPercent: 0, resetsAt: self.now.addingTimeInterval(-1800)),
                StatsEntry(capturedAt: self.now.addingTimeInterval(-60), usedPercent: 0, resetsAt: self.now.addingTimeInterval(3600)),
            ])
        #expect(!statsWindowHasRecordedUsage(window))
    }

    @Test
    func `unused provider does not emit phantom historical reset lines`() {
        let pastResets = (1...5).map { offset in
            self.now.addingTimeInterval(TimeInterval(-offset * 3600))
        }
        let entries = pastResets.enumerated().map { index, reset in
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(TimeInterval(-(5 - index) * 3600)),
                usedPercent: 0,
                resetsAt: reset)
        } + [StatsEntry(
            capturedAt: self.now.addingTimeInterval(-60),
            usedPercent: 0,
            resetsAt: self.now.addingTimeInterval(3600))]
        let provider = StatsProvider(
            id: "codex",
            name: "Codex",
            baseColor: .systemGreen,
            windows: [StatsWindow(
                name: "primary",
                displayName: "Session",
                windowMinutes: 300,
                entries: entries)])
        let historical = statsHistoricalResets([provider], before: self.now)
        #expect(historical.isEmpty)
    }

    @Test
    func `used provider still emits historical reset lines`() {
        let provider = StatsProvider(
            id: "codex",
            name: "Codex",
            baseColor: .systemGreen,
            windows: [StatsWindow(
                name: "primary",
                displayName: "Session",
                windowMinutes: 300,
                entries: [
                    StatsEntry(
                        capturedAt: self.now.addingTimeInterval(-7200),
                        usedPercent: 40,
                        resetsAt: self.now.addingTimeInterval(-3600)),
                    StatsEntry(
                        capturedAt: self.now.addingTimeInterval(-60),
                        usedPercent: 10,
                        resetsAt: self.now.addingTimeInterval(3600)),
                ])])
        let historical = statsHistoricalResets([provider], before: self.now)
        #expect(historical.count == 1)
        #expect(historical[0].date == self.now.addingTimeInterval(-3600))
    }

    @Test
    func `session window emits at most one historical reset within five hours`() {
        let pastResets = (1...4).map { hour in
            self.now.addingTimeInterval(TimeInterval(-hour * 3600))
        }
        let entries = pastResets.enumerated().map { index, reset in
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(TimeInterval(-(4 - index) * 3600)),
                usedPercent: 10,
                resetsAt: reset)
        } + [StatsEntry(
            capturedAt: self.now.addingTimeInterval(-60),
            usedPercent: 10,
            resetsAt: self.now.addingTimeInterval(3600))]
        let provider = StatsProvider(
            id: "codex",
            name: "Codex",
            baseColor: .systemGreen,
            windows: [StatsWindow(
                name: "primary",
                displayName: "Session",
                windowMinutes: 300,
                entries: entries)])
        let historical = statsHistoricalResets([provider], before: self.now)
        #expect(historical.count == 1)
        #expect(historical[0].date == pastResets[0])
    }

    @Test
    func `session window keeps separate historical resets five hours apart`() {
        let entries = [
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-11 * 3600),
                usedPercent: 20,
                resetsAt: self.now.addingTimeInterval(-10 * 3600)),
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-6 * 3600),
                usedPercent: 15,
                resetsAt: self.now.addingTimeInterval(-5 * 3600)),
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-60),
                usedPercent: 10,
                resetsAt: self.now.addingTimeInterval(3600)),
        ]
        let provider = StatsProvider(
            id: "codex",
            name: "Codex",
            baseColor: .systemGreen,
            windows: [StatsWindow(
                name: "primary",
                displayName: "Session",
                windowMinutes: 300,
                entries: entries)])
        let historical = statsHistoricalResets([provider], before: self.now)
        #expect(historical.count == 2)
        #expect(historical.map(\.date) == [
            self.now.addingTimeInterval(-10 * 3600),
            self.now.addingTimeInterval(-5 * 3600),
        ])
    }

    @Test
    func `coalescing helper collapses drift samples inside one window span`() {
        let fiveHours = TimeInterval(300 * 60)
        let base = self.now.addingTimeInterval(-fiveHours)
        let drifted = (0..<6).map { offset in
            base.addingTimeInterval(TimeInterval(offset * 600))
        }
        let coalesced = statsCoalescedResetDates(drifted, windowMinutes: 300)
        #expect(coalesced == [base])
    }

    @Test
    func `stats history freezes past reset drift at zero usage but keeps upcoming`() {
        let frozen = Date(timeIntervalSince1970: 1_700_010_000)
        let pastDrift = Date(timeIntervalSince1970: 1_700_010_500)
        let future = Date(timeIntervalSince1970: 1_700_020_000)
        let prior = [
            StatsEntry(capturedAt: self.now.addingTimeInterval(-120), usedPercent: 0, resetsAt: frozen),
        ]
        #expect(statsRecordedResetBoundary(
            usedPercent: 0,
            liveReset: pastDrift,
            priorEntries: prior,
            capturedAt: self.now) == frozen)
        #expect(statsRecordedResetBoundary(
            usedPercent: 0,
            liveReset: future,
            priorEntries: prior,
            capturedAt: self.now) == future)
    }

    @Test
    func `upcoming reset stays visible at zero usage when window is still active`() {
        let window = StatsWindow(
            name: "secondary",
            displayName: "Weekly",
            windowMinutes: 10080,
            entries: [
                StatsEntry(
                    capturedAt: self.now.addingTimeInterval(-3600),
                    usedPercent: 0,
                    resetsAt: self.now.addingTimeInterval(6 * 86400)),
            ])
        #expect(statsUpcomingReset(window, from: self.now) == self.now.addingTimeInterval(6 * 86400))
    }

    @Test
    func `unused antigravity quota pools do not emit phantom historical reset lines`() {
        let pastResets = (1...4).map { offset in
            self.now.addingTimeInterval(TimeInterval(-offset * 3600))
        }
        func zeroPool(id: String, displayName: String, windowMinutes: Int) -> StatsWindow {
            let entries = pastResets.enumerated().map { index, reset in
                StatsEntry(
                    capturedAt: self.now.addingTimeInterval(TimeInterval(-(4 - index) * 3600)),
                    usedPercent: 0,
                    resetsAt: reset)
            } + [StatsEntry(
                capturedAt: self.now.addingTimeInterval(-60),
                usedPercent: 0,
                resetsAt: self.now.addingTimeInterval(3600))]
            return StatsWindow(
                name: id,
                displayName: displayName,
                windowMinutes: windowMinutes,
                entries: entries)
        }
        let provider = StatsProvider(
            id: "antigravity",
            name: "Antigravity",
            baseColor: .systemPurple,
            windows: [
                zeroPool(id: "antigravity-quota-summary-gemini-5h", displayName: "Gemini 5-hour", windowMinutes: 300),
                zeroPool(id: "antigravity-quota-summary-gemini-weekly", displayName: "Gemini weekly", windowMinutes: 10080),
                zeroPool(id: "antigravity-quota-summary-3p-5h", displayName: "Claude/GPT 5-hour", windowMinutes: 300),
                zeroPool(id: "antigravity-quota-summary-3p-weekly", displayName: "Claude/GPT weekly", windowMinutes: 10080),
            ])
        let historical = statsHistoricalResets([provider], before: self.now)
        #expect(historical.isEmpty)
    }

    @Test
    func `antigravity quota pool history names match recorder slugs`() {
        #expect(StatsUsage.antigravityHistoryNameForTests(
            title: "Gemini 5-hour",
            id: "antigravity-quota-summary-gemini-5h") == "gemini-5-hour")
        #expect(StatsUsage.antigravityHistoryNameForTests(
            title: "Claude/GPT weekly",
            id: "antigravity-quota-summary-3p-weekly") == "claude-gpt-weekly")
    }
}
