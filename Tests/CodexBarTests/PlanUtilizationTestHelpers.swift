import CodexBarCore
import Foundation
@testable import CodexBar

func planEntry(at capturedAt: Date, usedPercent: Double, resetsAt: Date? = nil) -> PlanUtilizationHistoryEntry {
    PlanUtilizationHistoryEntry(capturedAt: capturedAt, usedPercent: usedPercent, resetsAt: resetsAt)
}

func planSeries(
    name: PlanUtilizationSeriesName,
    windowMinutes: Int,
    entries: [PlanUtilizationHistoryEntry]) -> PlanUtilizationSeriesHistory
{
    PlanUtilizationSeriesHistory(name: name, windowMinutes: windowMinutes, entries: entries)
}

func findSeries(
    _ histories: [PlanUtilizationSeriesHistory],
    name: PlanUtilizationSeriesName,
    windowMinutes: Int) -> PlanUtilizationSeriesHistory?
{
    histories.first { $0.name == name && $0.windowMinutes == windowMinutes }
}

func formattedBoundary(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}
