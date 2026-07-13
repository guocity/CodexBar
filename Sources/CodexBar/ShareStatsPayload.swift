import CodexBarCore
import Foundation

struct ShareStatsProviderSource: Sendable {
    let providerName: String
    let tokenSnapshot: CostUsageTokenSnapshot?
    let usageSnapshot: UsageSnapshot?
}

struct ShareStatsProviderPayload: Sendable, Equatable, Identifiable {
    let providerName: String
    let totalTokens: Int?
    let estimatedCostUSD: Double?
    let activeDays: Int?

    var id: String {
        self.providerName
    }
}

struct ShareStatsModelPayload: Sendable, Equatable, Identifiable {
    let providerName: String
    let modelName: String
    let totalTokens: Int?
    let estimatedCostUSD: Double?

    var id: String {
        "\(self.providerName):\(self.modelName)"
    }
}

struct ShareStatsPayload: Sendable, Equatable {
    let days: Int
    let periodEnd: Date
    let providers: [ShareStatsProviderPayload]
    let topModels: [ShareStatsModelPayload]
    let totalTokens: Int?
    let estimatedCostUSD: Double?
    let dailyTokens: [Int]

    var pricedProviderCount: Int {
        self.providers.count { $0.estimatedCostUSD != nil }
    }

    var tokenProviderCount: Int {
        self.providers.count { $0.totalTokens != nil }
    }

    var hasShareableData: Bool {
        !self.providers.isEmpty && self.providers.contains { provider in
            provider.totalTokens != nil || provider.estimatedCostUSD != nil
        }
    }
}

enum ShareStatsBuilder {
    static func make(
        providers sources: [ShareStatsProviderSource],
        days requestedDays: Int = 30,
        calendar: Calendar = .current) -> ShareStatsPayload?
    {
        let days = max(1, requestedDays)
        let periodEnd = sources.compactMap { source in
            source.tokenSnapshot?.updatedAt ?? source.usageSnapshot?.updatedAt
        }.max() ?? Date()
        var combinedDailyTokens = Array(repeating: 0, count: days)
        let topModels = self.modelPayloads(
            sources: sources,
            days: days,
            periodEnd: periodEnd,
            calendar: calendar)
        let providers = sources.map { source -> ShareStatsProviderPayload in
            let summary = source.tokenSnapshot?.summary(forLastDays: days, calendar: calendar)
            let dailyTokens = source.tokenSnapshot.map {
                self.dailyTokens(snapshot: $0, days: days, periodEnd: periodEnd, calendar: calendar)
            }
            if let dailyTokens {
                for index in combinedDailyTokens.indices {
                    combinedDailyTokens[index] += dailyTokens[index]
                }
            }
            let activeDays = dailyTokens.map { $0.count(where: { $0 > 0 }) }
            return ShareStatsProviderPayload(
                providerName: source.providerName,
                totalTokens: summary?.totalTokens,
                estimatedCostUSD: summary?.totalCostUSD,
                activeDays: activeDays)
        }
        let tokenValues = providers.compactMap(\.totalTokens)
        let costValues = providers.compactMap(\.estimatedCostUSD).filter(\.isFinite)
        let payload = ShareStatsPayload(
            days: days,
            periodEnd: periodEnd,
            providers: providers,
            topModels: topModels,
            totalTokens: tokenValues.isEmpty ? nil : tokenValues.reduce(0, +),
            estimatedCostUSD: costValues.isEmpty ? nil : costValues.reduce(0, +),
            dailyTokens: combinedDailyTokens)
        return payload.hasShareableData ? payload : nil
    }

    private struct ModelKey: Hashable {
        let providerName: String
        let modelName: String
    }

    private struct ModelAggregate {
        var totalTokens = 0
        var estimatedCostUSD = 0.0
        var sawTokens = false
        var sawCost = false
    }

    private static func modelPayloads(
        sources: [ShareStatsProviderSource],
        days: Int,
        periodEnd: Date,
        calendar: Calendar) -> [ShareStatsModelPayload]
    {
        let end = calendar.startOfDay(for: periodEnd)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        var aggregates: [ModelKey: ModelAggregate] = [:]
        for source in sources {
            guard let snapshot = source.tokenSnapshot else { continue }
            for offset in 0..<days {
                guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                      let entry = CostUsageTokenSnapshot.entry(
                          in: snapshot.daily,
                          forLocalDayContaining: day,
                          calendar: calendar)
                else { continue }
                for breakdown in entry.modelBreakdowns ?? [] {
                    let modelName = breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !modelName.isEmpty,
                          breakdown.totalTokens != nil || breakdown.costUSD != nil
                    else { continue }
                    let key = ModelKey(providerName: source.providerName, modelName: modelName)
                    var aggregate = aggregates[key] ?? ModelAggregate()
                    if let tokens = breakdown.totalTokens {
                        aggregate.totalTokens += tokens
                        aggregate.sawTokens = true
                    }
                    if let costUSD = breakdown.costUSD, costUSD.isFinite {
                        aggregate.estimatedCostUSD += costUSD
                        aggregate.sawCost = true
                    }
                    aggregates[key] = aggregate
                }
            }
        }
        return aggregates.map { key, aggregate in
            ShareStatsModelPayload(
                providerName: key.providerName,
                modelName: key.modelName,
                totalTokens: aggregate.sawTokens ? aggregate.totalTokens : nil,
                estimatedCostUSD: aggregate.sawCost ? aggregate.estimatedCostUSD : nil)
        }
        .sorted { lhs, rhs in
            switch (lhs.estimatedCostUSD, rhs.estimatedCostUSD) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftTokens = lhs.totalTokens ?? -1
                let rightTokens = rhs.totalTokens ?? -1
                if leftTokens != rightTokens { return leftTokens > rightTokens }
                if lhs.providerName != rhs.providerName { return lhs.providerName < rhs.providerName }
                return lhs.modelName < rhs.modelName
            }
        }
    }

    private static func dailyTokens(
        snapshot: CostUsageTokenSnapshot,
        days: Int,
        periodEnd: Date,
        calendar: Calendar) -> [Int]
    {
        let end = calendar.startOfDay(for: periodEnd)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        return (0..<days).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return 0 }
            let entry = CostUsageTokenSnapshot.entry(
                in: snapshot.daily,
                forLocalDayContaining: date,
                calendar: calendar)
            return max(0, entry?.totalTokens ?? 0)
        }
    }
}

enum ShareStatsFormatting {
    static func compactCount(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        let divisor: Double
        let suffix: String
        switch magnitude {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1000...:
            divisor = 1000
            suffix = "K"
        default:
            return value.formatted(.number.grouping(.automatic))
        }
        let scaled = Double(value) / divisor
        let digits = magnitude >= divisor * 100 ? 0 : magnitude >= divisor * 10 ? 1 : 2
        return scaled.formatted(.number.precision(.fractionLength(0...digits))) + suffix
    }

    static func currencyUSD(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func dataThrough(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter.string(from: date)
    }

    static func text(_ payload: ShareStatsPayload) -> String {
        var lines = ["My AI subscriptions · last \(payload.days) days"]
        var totals: [String] = []
        if let tokens = payload.totalTokens {
            totals.append("\(self.compactCount(tokens)) tracked tokens")
        }
        if let cost = payload.estimatedCostUSD, cost.isFinite {
            totals.append("~\(self.currencyUSD(cost)) estimated across priced providers")
        }
        if !totals.isEmpty {
            lines.append(totals.joined(separator: " · "))
        }
        lines.append(contentsOf: payload.providers.map { provider in
            var metrics: [String] = []
            if let tokens = provider.totalTokens {
                metrics.append("\(self.compactCount(tokens)) tokens")
            }
            if let cost = provider.estimatedCostUSD, cost.isFinite {
                metrics.append("~\(self.currencyUSD(cost)) est")
            }
            return "\(provider.providerName): \(metrics.isEmpty ? "connected" : metrics.joined(separator: " · "))"
        })
        if !payload.topModels.isEmpty {
            lines.append("Top models:")
            lines.append(contentsOf: payload.topModels.prefix(5).map { model in
                var metrics: [String] = []
                if let tokens = model.totalTokens {
                    metrics.append("\(self.compactCount(tokens)) tokens")
                }
                if let cost = model.estimatedCostUSD, cost.isFinite {
                    metrics.append("~\(self.currencyUSD(cost)) est")
                }
                return "\(model.modelName) (\(model.providerName)): \(metrics.joined(separator: " · "))"
            })
        }
        lines.append("Generated locally by CodexBar · Data through \(self.dataThrough(payload.periodEnd))")
        return lines.joined(separator: "\n")
    }
}
