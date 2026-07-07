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
}
