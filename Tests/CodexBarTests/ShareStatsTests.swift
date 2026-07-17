import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsTests {
    @Test
    func `builder preserves native currencies and unavailable spend`() throws {
        let payload = try #require(ShareStatsBuilder.make(
            model: Self.dashboard,
            subscriptionNames: ["codex:one": "pro", "cursor": "Cursor Pro", "claude": "Max"]))

        #expect(payload.days == 30)
        #expect(payload.totalTokens == nil)
        #expect(payload.currencies == [
            ShareStatsCurrencyPayload(currencyCode: "GBP", estimatedCost: 12, coveredDayCount: 10),
            ShareStatsCurrencyPayload(currencyCode: "USD", estimatedCost: nil, coveredDayCount: 0),
        ])
        #expect(payload.providers.map(\.providerName) == ["Claude", "Codex · #1", "Cursor"])
        #expect(payload.providers.map(\.subscriptionName) == ["Max", "Pro 20x", "Cursor Pro"])
        #expect(payload.providers.last?.estimatedCost == nil)
        #expect(payload.topModels.map(\.modelName).prefix(2) == ["claude-sonnet-4", "gpt-5.4"])

        let text = ShareStatsFormatting.text(payload)
        #expect(text.contains("GBP: £12.00 estimated · coverage 10/30 days"))
        #expect(text.contains("Claude · Max: 300 tokens · ~£12.00 est · 10/30 days"))
        #expect(text.contains("USD: Spend unavailable estimated · coverage 0/30 days"))
        #expect(text.contains("Cursor · Cursor Pro: Spend unavailable"))
        #expect(!text.contains("£12.00 +"))
    }

    @Test
    func `payload sanitizer excludes emails identifiers paths and prompts`() throws {
        let model = Self.dashboard(models: [
            "gpt-5.4",
            "person@example.com",
            "/Users/peter/private/model",
            "550e8400-e29b-41d4-a716-446655440000",
            "summarize my secret project",
            "abcdefabcdefabcdefabcdef",
        ])
        let payload = try #require(ShareStatsBuilder.make(
            model: model,
            subscriptionNames: [
                "codex:one": "person@example.com",
                "cursor": "/Users/peter/plan",
                "claude": "Max",
            ]))
        let text = ShareStatsFormatting.text(payload)

        #expect(payload.topModels.map(\.modelName) == ["claude-sonnet-4", "gpt-5.4"])
        #expect(payload.providers.map(\.subscriptionName) == ["Max", nil, nil])
        #expect(!text.contains("person@example.com"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("550e8400"))
        #expect(!text.contains("secret project"))
        #expect(!text.contains("abcdefabcdef"))
    }

    @Test
    func `subscription labels require a plan tier provider contract`() {
        #expect(ShareStatsSubscriptionName.sanitized(provider: .codex, rawName: "pro") == "Pro 20x")
        #expect(ShareStatsSubscriptionName.sanitized(provider: .cursor, rawName: "Cursor Pro") == "Cursor Pro")
        #expect(ShareStatsSubscriptionName.sanitized(provider: .openrouter, rawName: "Team") == nil)
        #expect(ShareStatsSubscriptionName.sanitized(provider: .claude, rawName: "name@example.com") == nil)
    }

    @Test
    func `empty dashboard has no share payload`() {
        #expect(ShareStatsBuilder.make(model: SpendDashboardModel(requestedDays: 30, groups: [])) == nil)
    }

    @Test
    func `non-finite spend becomes unavailable`() throws {
        let model = SpendDashboardModel(requestedDays: 7, groups: [
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "USD",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "codex",
                        rank: 1,
                        provider: .codex,
                        displayName: "Codex",
                        totalTokens: 10,
                        totalCost: .nan,
                        coveredDayCount: 7),
                ],
                models: [
                    SpendDashboardModel.ModelRow(
                        rank: 1,
                        provider: .codex,
                        providerName: "Codex",
                        modelName: "gpt-5.4",
                        totalTokens: 10,
                        totalCost: .infinity),
                ],
                dailyPoints: [],
                totalTokens: 10,
                totalCost: -.infinity,
                coveredDayCount: 7,
                chartDomain: Self.date...Self.date,
                modelHistoryCompleteness: .complete),
        ])
        let payload = try #require(ShareStatsBuilder.make(model: model))

        #expect(payload.providers.first?.estimatedCost == nil)
        #expect(payload.topModels.first?.estimatedCost == nil)
        #expect(payload.currencies.first?.estimatedCost == nil)
        #expect(!ShareStatsFormatting.text(payload).lowercased().contains("nan"))
        #expect(!ShareStatsFormatting.text(payload).lowercased().contains("inf"))
    }

    @Test @MainActor
    func `renderer creates social card PNG`() throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard))
        let data = try #require(ShareStatsRenderer.pngData(for: payload))

        #expect(ShareStatsCardView.size == CGSize(width: 1200, height: 630))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    private static let date = Date(timeIntervalSince1970: 1_783_382_400)

    private static var dashboard: SpendDashboardModel {
        self.dashboard(models: ["gpt-5.4"])
    }

    private static func dashboard(models: [String]) -> SpendDashboardModel {
        SpendDashboardModel(requestedDays: 30, groups: [
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "GBP",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "claude",
                        rank: 1,
                        provider: .claude,
                        displayName: "Claude",
                        totalTokens: 300,
                        totalCost: 12,
                        coveredDayCount: 10),
                ],
                models: [
                    SpendDashboardModel.ModelRow(
                        rank: 1,
                        provider: .claude,
                        providerName: "Claude",
                        modelName: "claude-sonnet-4",
                        totalTokens: 1000,
                        totalCost: 1),
                ],
                dailyPoints: [],
                totalTokens: 300,
                totalCost: 12,
                coveredDayCount: 10,
                chartDomain: self.date...self.date,
                modelHistoryCompleteness: .complete),
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "USD",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "codex:one",
                        rank: 1,
                        provider: .codex,
                        displayName: "Codex · #1",
                        totalTokens: 200,
                        totalCost: 4,
                        coveredDayCount: 30),
                    SpendDashboardModel.ProviderRow(
                        id: "cursor",
                        rank: 2,
                        provider: .cursor,
                        displayName: "Cursor",
                        totalTokens: nil,
                        totalCost: nil,
                        coveredDayCount: 0),
                ],
                models: models.enumerated().map { index, name in
                    SpendDashboardModel.ModelRow(
                        rank: index + 1,
                        provider: .codex,
                        providerName: "Codex",
                        modelName: name,
                        totalTokens: 200,
                        totalCost: 4)
                },
                dailyPoints: [],
                totalTokens: nil,
                totalCost: nil,
                coveredDayCount: 0,
                chartDomain: self.date...self.date,
                modelHistoryCompleteness: .complete),
        ])
    }
}
