import SwiftUI

struct ShareStatsCardView: View {
    static let size = CGSize(width: 1200, height: 630)

    let payload: ShareStatsPayload

    private let background = Color(red: 0.055, green: 0.052, blue: 0.047)
    private let primary = Color(red: 0.94, green: 0.92, blue: 0.87)
    private let secondary = Color(red: 0.60, green: 0.57, blue: 0.52)
    private let accent = Color(red: 0.93, green: 0.54, blue: 0.28)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Rectangle()
                .fill(self.secondary.opacity(0.24))
                .frame(height: 1)
                .padding(.top, 24)
            HStack(alignment: .top, spacing: 52) {
                self.summary
                    .frame(width: 455, alignment: .leading)
                self.providerBreakdown
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.top, 30)
            .frame(maxHeight: .infinity, alignment: .top)
            self.footer
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 38)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(self.background)
        .foregroundStyle(self.primary)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 14) {
                ShareStatsMark(accent: self.accent)
                    .frame(width: 34, height: 34)
                Text("CodexBar")
                    .font(.system(size: 25, weight: .medium, design: .rounded))
            }
            Spacer()
            Text("LOCAL SNAPSHOT")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(self.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(self.accent.opacity(0.85), lineWidth: 1)
                }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MY AI SUBSCRIPTIONS · LAST \(self.payload.days) DAYS")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .tracking(1.35)
                .lineLimit(1)
            Text(self.payload.totalTokens.map(ShareStatsFormatting.compactCount) ?? "—")
                .font(.system(size: 105, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .padding(.top, 7)
            Text("TRACKED TOKENS")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .tracking(5.5)
            Rectangle()
                .fill(self.accent)
                .frame(width: 48, height: 3)
                .padding(.vertical, 16)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let cost = self.payload.estimatedCostUSD, cost.isFinite {
                    Text(ShareStatsFormatting.currencyUSD(cost))
                        .font(.system(size: 36, weight: .regular, design: .rounded))
                        .monospacedDigit()
                    Text("estimated")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(self.secondary)
                }
            }
            Text("\(self.payload.tokenProviderCount) token sources · \(self.payload.pricedProviderCount) priced")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(self.secondary)
                .padding(.top, 10)
            ShareStatsActivityChart(values: self.payload.dailyTokens, accent: self.accent)
                .frame(height: 105)
                .padding(.top, 18)
        }
    }

    private var providerBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("BY SUBSCRIPTION")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(self.secondary)
                ForEach(
                    Array(self.payload.providers.prefix(self.providerDisplayLimit).enumerated()),
                    id: \.element.id)
                { index, provider in
                    ShareStatsProviderRow(
                        provider: provider,
                        color: ShareStatsProviderRow.colors[index % ShareStatsProviderRow.colors.count])
                }
                if self.payload.providers.count > self.providerDisplayLimit {
                    Text("+\(self.payload.providers.count - self.providerDisplayLimit) more configured")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(self.secondary)
                        .padding(.leading, 18)
                }
            }

            if !self.payload.topModels.isEmpty {
                Rectangle()
                    .fill(self.secondary.opacity(0.18))
                    .frame(height: 1)
                    .padding(.vertical, 3)
                VStack(alignment: .leading, spacing: 10) {
                    Text("TOP MODELS")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(self.secondary)
                    ForEach(self.payload.topModels.prefix(4)) { model in
                        ShareStatsModelRow(
                            model: model,
                            color: self.color(forProviderNamed: model.providerName))
                    }
                }
            }
        }
    }

    private var providerDisplayLimit: Int {
        self.payload.topModels.isEmpty ? 9 : 6
    }

    private func color(forProviderNamed name: String) -> Color {
        let index = self.payload.providers.firstIndex { $0.providerName == name } ?? 0
        return ShareStatsProviderRow.colors[index % ShareStatsProviderRow.colors.count]
    }

    private var footer: some View {
        VStack(spacing: 16) {
            Rectangle()
                .fill(self.secondary.opacity(0.24))
                .frame(height: 1)
            HStack(spacing: 18) {
                Label("Generated locally by CodexBar", systemImage: "lock.shield")
                Spacer()
                Text("Only aggregate usage included")
                Circle().fill(self.secondary.opacity(0.6)).frame(width: 4, height: 4)
                Text("Data through \(ShareStatsFormatting.dataThrough(self.payload.periodEnd))")
            }
            .font(.system(size: 14, weight: .regular, design: .rounded))
            .foregroundStyle(self.secondary)
        }
    }
}

private struct ShareStatsModelRow: View {
    let model: ShareStatsModelPayload
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(self.color)
                .frame(width: 8, height: 8)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.model.modelName)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(self.model.providerName)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Color(red: 0.60, green: 0.57, blue: 0.52))
            }
            Spacer(minLength: 10)
            Text(self.detail)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.73, green: 0.70, blue: 0.65))
                .lineLimit(1)
        }
        .frame(height: 30)
    }

    private var detail: String {
        if let cost = self.model.estimatedCostUSD, cost.isFinite {
            return "~\(ShareStatsFormatting.currencyUSD(cost))"
        }
        return self.model.totalTokens.map(ShareStatsFormatting.compactCount) ?? "—"
    }
}

private struct ShareStatsProviderRow: View {
    static let colors = [
        Color(red: 0.93, green: 0.54, blue: 0.28),
        Color(red: 0.68, green: 0.48, blue: 0.92),
        Color(red: 0.27, green: 0.70, blue: 0.65),
        Color(red: 0.90, green: 0.72, blue: 0.30),
        Color(red: 0.42, green: 0.62, blue: 0.92),
        Color(red: 0.86, green: 0.42, blue: 0.51),
    ]

    let provider: ShareStatsProviderPayload
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(self.color)
                .frame(width: 4, height: 27)
            Text(self.provider.providerName)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
            Spacer(minLength: 12)
            Text(self.detail)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.73, green: 0.70, blue: 0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .frame(height: 29)
    }

    private var detail: String {
        var metrics: [String] = []
        if let tokens = self.provider.totalTokens {
            metrics.append(ShareStatsFormatting.compactCount(tokens))
        }
        if let cost = self.provider.estimatedCostUSD, cost.isFinite {
            metrics.append("~\(ShareStatsFormatting.currencyUSD(cost))")
        }
        return metrics.isEmpty ? "connected" : metrics.joined(separator: " · ")
    }
}

private struct ShareStatsMark: View {
    let accent: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array([0.38, 0.68, 1.0].enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(self.accent)
                    .frame(width: 5, height: 28 * height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct ShareStatsActivityChart: View {
    let values: [Int]
    let accent: Color

    var body: some View {
        let maximum = max(Double(self.values.max() ?? 0), 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(self.values.enumerated()), id: \.offset) { _, value in
                let fraction = Double(value) / maximum
                Capsule()
                    .fill(self.accent.opacity(value == 0 ? 0.13 : 0.80))
                    .frame(maxWidth: .infinity, minHeight: 3, maxHeight: max(3, 96 * fraction))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}
