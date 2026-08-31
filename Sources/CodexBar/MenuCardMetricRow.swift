import SwiftUI

struct MetricRow: View {
    let metric: UsageMenuCardView.Model.Metric
    let layoutMetric: UsageMenuCardView.Model.Metric
    let title: String
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        let presentation = self.metric.linePresentation(title: self.title)
        let layoutPresentation = self.layoutMetric.linePresentation(title: self.title)
        VStack(alignment: .leading, spacing: 6) {
            if let statusText = self.metric.statusText {
                Text(self.title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            } else {
                MetricRowHeader(
                    title: presentation.titleText,
                    layoutTitle: layoutPresentation.titleText,
                    resetText: presentation.resetText,
                    layoutResetText: layoutPresentation.resetText,
                    resetHelpText: self.metric.resetHelpText,
                    isHighlighted: self.isHighlighted)
                VStack(alignment: .leading, spacing: 3) {
                    UsageProgressBar(
                        percent: self.metric.percent,
                        tint: self.progressColor,
                        accessibilityLabel: self.metric.percentStyle.accessibilityLabel,
                        pacePercent: self.metric.pacePercent,
                        paceOnTop: self.metric.paceOnTop,
                        warningMarkerPercents: self.metric.warningMarkerPercents,
                        workdayMarkerPercents: self.metric.workdayMarkerPercents,
                        workdayTickAppearance: self.metric.workdayTickAppearance)
                    if let timeline = self.metric.resetTimeline {
                        ResetTimelineBar(
                            resetsAt: timeline.resetsAt,
                            windowSeconds: timeline.windowSeconds,
                            accessibilityLabel: L("Time until reset"))
                    }
                }
                if let layoutMetaText = layoutPresentation.metaText {
                    self.layoutPreservingText(
                        presentation.metaText,
                        layoutText: layoutMetaText,
                        lineLimit: 2)
                }
                if let layoutDetailText = self.layoutMetric.detailText {
                    self.layoutPreservingText(
                        self.metric.detailText,
                        layoutText: layoutDetailText,
                        lineLimit: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(self.metric.cardStyle ? 10 : 0)
        .background(self.metric.cardStyle ? Color.secondary.opacity(self.isHighlighted ? 0.2 : 0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: self.metric.cardStyle ? 10 : 0))
    }

    private func layoutPreservingText(
        _ text: String?,
        layoutText: String,
        lineLimit: Int) -> some View
    {
        Text(layoutText)
            .font(.footnote)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .overlay(alignment: .topLeading) {
                if let text, !text.isEmpty {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(lineLimit)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .clipped()
    }
}
