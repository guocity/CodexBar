import CodexBarCore
import Foundation

struct ShareStatsProviderPayload: Sendable, Equatable {
    let providerName: String
    let subscriptionName: String?
    let currencyCode: String
    let totalTokens: Int?
    let estimatedCost: Double?
    let coveredDayCount: Int
}

struct ShareStatsModelPayload: Sendable, Equatable {
    let providerName: String
    let modelName: String
    let currencyCode: String
    let totalTokens: Int?
    let estimatedCost: Double?
}

struct ShareStatsCurrencyPayload: Sendable, Equatable, Identifiable {
    let currencyCode: String
    let estimatedCost: Double?
    let coveredDayCount: Int

    var id: String {
        self.currencyCode
    }
}

struct ShareStatsPayload: Sendable, Equatable {
    let days: Int
    let periodEnd: Date
    let providers: [ShareStatsProviderPayload]
    let topModels: [ShareStatsModelPayload]
    let currencies: [ShareStatsCurrencyPayload]
    let totalTokens: Int?

    var hasShareableData: Bool {
        !self.providers.isEmpty && self.providers.contains { provider in
            provider.totalTokens != nil || provider.estimatedCost != nil
        }
    }
}

enum ShareStatsSubscriptionName {
    /// Only providers whose login identity has a plan-tier contract may expose it on a share card.
    static func sanitized(provider: UsageProvider, rawName: String?) -> String? {
        guard let rawName else { return nil }
        let supportsPlanLabel = switch provider {
        case .codex, .claude, .cursor, .alibaba, .alibabatokenplan, .gemini, .antigravity,
             .copilot, .devin, .zai, .minimax, .augment, .elevenlabs, .windsurf, .zed,
             .perplexity, .sakana, .abacus, .synthetic, .t3chat, .sub2api:
            true
        default:
            false
        }
        guard supportsPlanLabel else { return nil }

        let name = if provider == .codex {
            CodexPlanFormatting.displayName(rawName) ?? UsageFormatter.cleanPlanName(rawName)
        } else {
            UsageFormatter.cleanPlanName(rawName)
        }
        return ShareStatsSanitizer.planName(name)
    }
}

enum ShareStatsSanitizer {
    static func planName(_ rawValue: String) -> String? {
        self.safeLabel(rawValue, maximumLength: 48, maximumWords: 4, requireModelShape: false)
    }

    static func modelName(_ rawValue: String) -> String? {
        self.safeLabel(rawValue, maximumLength: 72, maximumWords: 3, requireModelShape: true)
    }

    private static func safeLabel(
        _ rawValue: String,
        maximumLength: Int,
        maximumWords: Int,
        requireModelShape: Bool) -> String?
    {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maximumLength,
              !value.contains("@"),
              !value.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue.map { $0 < 0x20 } == true }),
              value.split(whereSeparator: { $0.isWhitespace }).count <= maximumWords,
              value
                  .range(of: #"(?i)(^|[/\\])(?:Users|home|private|Volumes)([/\\]|$)"#, options: .regularExpression) ==
                  nil,
                  value.range(of: #"(?i)^[a-z]:\\"#, options: .regularExpression) == nil,
                  value.range(
                      of: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
                      options: .regularExpression) == nil,
                  value.range(of: #"(?i)\b[0-9a-f]{24,}\b"#, options: .regularExpression) == nil,
                  value.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} ._+:/()\-]*$"#, options: .regularExpression) != nil
        else { return nil }

        if requireModelShape {
            let hasModelPunctuation = value.contains { "-_/+.".contains($0) }
            guard hasModelPunctuation || value.contains(where: \Character.isNumber) else { return nil }
        }
        return value
    }
}

enum ShareStatsBuilder {
    static func make(
        model: SpendDashboardModel,
        subscriptionNames: [String: String] = [:]) -> ShareStatsPayload?
    {
        let providers = model.groups.flatMap { group in
            group.providers.map { row in
                ShareStatsProviderPayload(
                    providerName: row.displayName,
                    subscriptionName: ShareStatsSubscriptionName.sanitized(
                        provider: row.provider,
                        rawName: subscriptionNames[row.id]),
                    currencyCode: group.currencyCode,
                    totalTokens: row.totalTokens,
                    estimatedCost: self.finiteCost(row.totalCost),
                    coveredDayCount: row.coveredDayCount)
            }
        }
        let topModels = model.groups.flatMap { group in
            group.models.compactMap { row -> ShareStatsModelPayload? in
                guard let modelName = ShareStatsSanitizer.modelName(row.modelName) else { return nil }
                return ShareStatsModelPayload(
                    providerName: row.providerName,
                    modelName: modelName,
                    currencyCode: group.currencyCode,
                    totalTokens: row.totalTokens,
                    estimatedCost: self.finiteCost(row.totalCost))
            }
        }
        .sorted { lhs, rhs in
            switch (lhs.totalTokens, rhs.totalTokens) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.providerName != rhs.providerName {
                    return lhs.providerName < rhs.providerName
                }
                return lhs.modelName < rhs.modelName
            }
        }
        let currencies = model.groups.map {
            ShareStatsCurrencyPayload(
                currencyCode: $0.currencyCode,
                estimatedCost: self.finiteCost($0.totalCost),
                coveredDayCount: $0.coveredDayCount)
        }
        let tokenTotals = model.groups.map(\.totalTokens)
        let totalTokens = tokenTotals.allSatisfy { $0 != nil }
            ? tokenTotals.compactMap(\.self).reduce(0, +)
            : nil
        let periodEnd = model.groups.map(\.chartDomain.upperBound).max() ?? Date()
        let payload = ShareStatsPayload(
            days: model.requestedDays,
            periodEnd: periodEnd,
            providers: providers,
            topModels: topModels,
            currencies: currencies,
            totalTokens: totalTokens)
        return payload.hasShareableData ? payload : nil
    }

    private static func finiteCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

enum ShareStatsFormatting {
    static func compactCount(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        let divisor: Double
        let suffix: String
        switch magnitude {
        case 1_000_000_000...: divisor = 1_000_000_000; suffix = "B"
        case 1_000_000...: divisor = 1_000_000; suffix = "M"
        case 1000...: divisor = 1000; suffix = "K"
        default: return value.formatted(.number.grouping(.automatic))
        }
        let scaled = Double(value) / divisor
        let digits = magnitude >= divisor * 100 ? 0 : magnitude >= divisor * 10 ? 1 : 2
        return scaled.formatted(.number.precision(.fractionLength(0...digits))) + suffix
    }

    static func currency(_ value: Double, code: String) -> String {
        UsageFormatter.currencyString(value, currencyCode: code)
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
        if let tokens = payload.totalTokens {
            lines.append("\(self.compactCount(tokens)) tracked tokens")
        }
        lines.append(contentsOf: payload.currencies.map { currency in
            let spend = currency.estimatedCost.map { self.currency($0, code: currency.currencyCode) }
                ?? "Spend unavailable"
            return "\(currency.currencyCode): \(spend) estimated · "
                + "coverage \(currency.coveredDayCount)/\(payload.days) days"
        })
        lines.append(contentsOf: payload.providers.map { provider in
            var metrics: [String] = []
            if let tokens = provider.totalTokens {
                metrics.append("\(self.compactCount(tokens)) tokens")
            }
            if let cost = provider.estimatedCost {
                metrics.append("~\(self.currency(cost, code: provider.currencyCode)) est")
            } else {
                metrics.append("Spend unavailable")
            }
            if provider.estimatedCost != nil, provider.coveredDayCount < payload.days {
                metrics.append("\(provider.coveredDayCount)/\(payload.days) days")
            }
            let subscription = provider.subscriptionName.map { " · \($0)" } ?? ""
            return "\(provider.providerName)\(subscription): \(metrics.joined(separator: " · "))"
        })
        if !payload.topModels.isEmpty {
            lines.append("Top models:")
            lines.append(contentsOf: payload.topModels.prefix(5).map { model in
                var metrics: [String] = []
                if let tokens = model.totalTokens {
                    metrics.append("\(self.compactCount(tokens)) tokens")
                }
                if let cost = model.estimatedCost {
                    metrics.append("~\(self.currency(cost, code: model.currencyCode)) est")
                }
                return "\(model.modelName) (\(model.providerName)): \(metrics.joined(separator: " · "))"
            })
        }
        lines.append("Generated locally by CodexBar · Data through \(self.dataThrough(payload.periodEnd))")
        return lines.joined(separator: "\n")
    }
}
