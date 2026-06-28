import AppKit
import Foundation
import Testing
@testable import CodexBar

struct StatsHistoricalResetTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `historical reset markers collapse unchanged usage readings to the latest past reset`() {
        let entries = [
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-4 * 3600),
                usedPercent: 0,
                resetsAt: self.now.addingTimeInterval(-3 * 3600)),
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-3 * 3600),
                usedPercent: 0,
                resetsAt: self.now.addingTimeInterval(-2 * 3600)),
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-2 * 3600),
                usedPercent: 0,
                resetsAt: self.now.addingTimeInterval(-1 * 3600)),
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-1 * 3600),
                usedPercent: 0,
                resetsAt: self.now.addingTimeInterval(-30 * 60)),
        ]
        let window = StatsWindow(
            name: "primary",
            displayName: "Session",
            windowMinutes: 300,
            entries: entries)
        let provider = StatsProvider(id: "codex", name: "Codex", baseColor: .red, windows: [window])

        let resets = statsHistoricalResets([provider], before: self.now)
        #expect(resets.count == 1)
        #expect(resets[0].date == self.now.addingTimeInterval(-30 * 60))
    }

    @Test
    func `historical reset markers keep separate markers when usage changes`() {
        let zeroSegmentReset = self.now.addingTimeInterval(-3.5 * 3600)
        let usageSegmentReset = self.now.addingTimeInterval(-1 * 3600)
        let entries = [
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-5 * 3600),
                usedPercent: 0,
                resetsAt: self.now.addingTimeInterval(-4 * 3600)),
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-4 * 3600),
                usedPercent: 0,
                resetsAt: zeroSegmentReset),
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-3 * 3600),
                usedPercent: 12,
                resetsAt: self.now.addingTimeInterval(-2 * 3600)),
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-2 * 3600),
                usedPercent: 12,
                resetsAt: usageSegmentReset),
        ]
        let window = StatsWindow(
            name: "primary",
            displayName: "Session",
            windowMinutes: 300,
            entries: entries)
        let provider = StatsProvider(id: "claude", name: "Claude", baseColor: .orange, windows: [window])

        let resets = statsHistoricalResets([provider], before: self.now).map(\.date).sorted()
        #expect(resets == [zeroSegmentReset, usageSegmentReset].sorted())
    }

    @Test
    func `historical reset markers ignore future reset dates`() {
        let entries = [
            StatsEntry(
                capturedAt: self.now.addingTimeInterval(-3600),
                usedPercent: 0,
                resetsAt: self.now.addingTimeInterval(3600)),
        ]
        let window = StatsWindow(
            name: "primary",
            displayName: "Session",
            windowMinutes: 300,
            entries: entries)
        let provider = StatsProvider(id: "codex", name: "Codex", baseColor: .red, windows: [window])

        #expect(statsHistoricalResets([provider], before: self.now).isEmpty)
    }
}
