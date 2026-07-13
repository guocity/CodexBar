import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsTests {
    @Test
    func `builder differentiates subscriptions and sums only known totals`() throws {
        let payload = try #require(ShareStatsBuilder.make(
            providers: [
                ShareStatsProviderSource(
                    providerName: "Codex",
                    tokenSnapshot: Self.codexSnapshot,
                    usageSnapshot: Self.usage(usedPercent: 64)),
                ShareStatsProviderSource(
                    providerName: "Claude",
                    tokenSnapshot: Self.claudeSnapshot,
                    usageSnapshot: Self.usage(usedPercent: 38)),
                ShareStatsProviderSource(
                    providerName: "Cursor",
                    tokenSnapshot: nil,
                    usageSnapshot: Self.usage(usedPercent: 82)),
                ShareStatsProviderSource(
                    providerName: "OpenCode",
                    tokenSnapshot: nil,
                    usageSnapshot: nil),
            ],
            calendar: Self.calendar))

        #expect(payload.days == 30)
        #expect(payload.totalTokens == 5_500_000_000)
        #expect(payload.estimatedCostUSD == 4250)
        #expect(payload.providers.map(\.providerName) == ["Codex", "Claude", "Cursor", "OpenCode"])
        #expect(payload.providers[3].totalTokens == nil)
        #expect(payload.tokenProviderCount == 2)
        #expect(payload.pricedProviderCount == 2)
        #expect(payload.topModels.map(\.modelName) == ["gpt-5.5", "claude-sonnet-5"])
    }

    @Test
    func `text formatter preserves provider differentiation and provenance`() throws {
        let payload = try #require(ShareStatsBuilder.make(
            providers: [
                ShareStatsProviderSource(
                    providerName: "Codex",
                    tokenSnapshot: Self.codexSnapshot,
                    usageSnapshot: nil),
                ShareStatsProviderSource(
                    providerName: "Cursor",
                    tokenSnapshot: nil,
                    usageSnapshot: Self.usage(usedPercent: 82)),
            ],
            calendar: Self.calendar))
        let text = ShareStatsFormatting.text(payload)

        #expect(text.contains("Codex: 4.77B tokens"))
        #expect(text.contains("Cursor: connected"))
        #expect(text.contains("estimated across priced providers"))
        #expect(text.contains("gpt-5.5 (Codex)"))
        #expect(text.contains("Generated locally by CodexBar"))
        #expect(!text.contains("secret-project"))
    }

    @MainActor
    @Test
    func `renderer produces a valid differentiated social card png`() throws {
        let payload = try #require(ShareStatsBuilder.make(
            providers: [
                ShareStatsProviderSource(
                    providerName: "Codex",
                    tokenSnapshot: Self.codexSnapshot,
                    usageSnapshot: nil),
                ShareStatsProviderSource(
                    providerName: "Cursor",
                    tokenSnapshot: nil,
                    usageSnapshot: Self.usage(usedPercent: 82)),
            ],
            calendar: Self.calendar))
        let data = try #require(ShareStatsRenderer.pngData(for: payload))
        let representation = try #require(NSBitmapImageRep(data: data))

        #expect(representation.pixelsWide == 1200)
        #expect(representation.pixelsHigh == 630)
    }

    private static let codexSnapshot = Self.snapshot(
        tokens: 4_768_000_000,
        cost: 3750,
        modelName: "gpt-5.5",
        projectName: "secret-project")
    private static let claudeSnapshot = Self.snapshot(
        tokens: 732_000_000,
        cost: 500,
        modelName: "claude-sonnet-5",
        projectName: "other-secret")

    private static func snapshot(
        tokens: Int,
        cost: Double,
        modelName: String,
        projectName: String) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            historyDays: 30,
            daily: [self.entry(day: "2026-07-07", tokens: tokens, cost: cost, modelName: modelName)],
            projects: [
                CostUsageProjectBreakdown(
                    name: projectName,
                    path: "/Users/example/\(projectName)",
                    totalTokens: 10,
                    totalCostUSD: 1,
                    daily: [],
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_783_382_400))
    }

    private static func usage(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_783_382_400))
    }

    private static func entry(
        day: String,
        tokens: Int,
        cost: Double,
        modelName: String) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: [modelName],
            modelBreakdowns: [.init(modelName: modelName, costUSD: cost, totalTokens: tokens)])
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
