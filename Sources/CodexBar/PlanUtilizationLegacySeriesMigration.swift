import CodexBarCore
import Foundation

/// Rescues plan-utilization history recorded under an older series-naming scheme.
///
/// When the recorder's series names change across app versions — e.g. Cursor's
/// single window-duration series (`window-44640m`) splitting into per-lane
/// `total`/`auto`/`api`, or Antigravity's representative `weekly` series
/// splitting into per-pool `gemini-weekly`/`claude-gpt-weekly` — previously
/// accumulated samples would otherwise be stranded under a name nothing displays,
/// looking to the user as though the old history was deleted.
///
/// This folds each orphaned legacy series into the current lane it continues,
/// matched by window length plus value/reset continuity, so no historical
/// records are lost. When a confident mapping can't be made the legacy series is
/// kept untouched — preserving data always wins over guessing.
enum PlanUtilizationLegacySeriesMigration {
    /// A series the current recorder produces this refresh, used as the migration
    /// target for an orphaned legacy series of the same window length.
    struct CanonicalLane {
        let name: PlanUtilizationSeriesName
        let windowMinutes: Int
        let usedPercent: Double
        let resetsAt: Date?
    }

    /// Two reset boundaries within this many seconds are treated as the same
    /// window instance (clocks/rounding drift between refreshes).
    private static let resetEquivalenceToleranceSeconds: TimeInterval = 2 * 60
    /// A value-only match must be within this many percentage points to be trusted.
    private static let valueMatchTolerance = 5.0
    /// The closest candidate must beat the runner-up by at least this margin,
    /// otherwise the match is too ambiguous to risk misattributing data.
    private static let valueAmbiguityMargin = 0.5

    /// Returns `histories` with any orphaned legacy series merged into the current
    /// lane they continue, along with whether anything changed.
    static func migrate(
        provider: UsageProvider,
        histories: [PlanUtilizationSeriesHistory],
        canonicalLanes: [CanonicalLane]) -> (histories: [PlanUtilizationSeriesHistory], didChange: Bool)
    {
        let legacySeries = histories.filter { Self.isLegacySeries(provider: provider, name: $0.name) }
        guard !legacySeries.isEmpty else { return (histories, false) }

        struct Key: Hashable {
            let name: String
            let windowMinutes: Int
        }
        func key(_ name: PlanUtilizationSeriesName, _ windowMinutes: Int) -> Key {
            Key(name: name.rawValue, windowMinutes: windowMinutes)
        }

        var byKey: [Key: PlanUtilizationSeriesHistory] = [:]
        for history in histories where !Self.isLegacySeries(provider: provider, name: history.name) {
            byKey[key(history.name, history.windowMinutes)] = history
        }

        var didChange = false
        for legacy in legacySeries {
            guard let target = Self.bestTarget(for: legacy, canonicalLanes: canonicalLanes) else {
                // No confident mapping — keep the legacy series so its data is never dropped.
                byKey[key(legacy.name, legacy.windowMinutes)] = legacy
                continue
            }
            let targetKey = key(target.name, target.windowMinutes)
            let existingEntries = byKey[targetKey]?.entries ?? []
            byKey[targetKey] = PlanUtilizationSeriesHistory(
                name: target.name,
                windowMinutes: target.windowMinutes,
                entries: Self.mergedEntries(existingEntries + legacy.entries))
            didChange = true
        }

        return (Array(byKey.values), didChange)
    }

    /// Whether `name` is a series the current recorder no longer produces for this
    /// provider (so any data under it is stranded history rather than live data).
    private static func isLegacySeries(provider: UsageProvider, name: PlanUtilizationSeriesName) -> Bool {
        switch provider {
        case .cursor:
            // Cursor now names lanes total/auto/api; the old generic window-duration
            // name (`window-<minutes>m`) is the collapsed legacy series.
            Self.isGenericWindowName(name.rawValue)
        case .antigravity:
            // Antigravity now records per-pool series; the bare `weekly` series is the
            // old representative-weekly bucket.
            name == .weekly
        default:
            false
        }
    }

    private static func isGenericWindowName(_ raw: String) -> Bool {
        guard raw.hasPrefix("window-"), raw.hasSuffix("m") else { return false }
        let digits = raw.dropFirst("window-".count).dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// Picks the current lane an orphaned legacy series continues, or `nil` when no
    /// confident match exists. Prefers a uniquely reset-matching lane; otherwise
    /// disambiguates by closeness in usage value, demanding a clear winner.
    private static func bestTarget(
        for legacy: PlanUtilizationSeriesHistory,
        canonicalLanes: [CanonicalLane]) -> CanonicalLane?
    {
        guard let last = legacy.entries.last else { return nil }
        let candidates = canonicalLanes.filter { $0.windowMinutes == legacy.windowMinutes }
        guard !candidates.isEmpty else { return nil }

        // Strongest signal: exactly one lane shares the legacy series' reset boundary.
        let resetMatches = candidates.filter { Self.resetsEquivalent($0.resetsAt, last.resetsAt) }
        if resetMatches.count == 1 { return resetMatches[0] }

        // Otherwise disambiguate by usage value, requiring an unambiguous closest lane.
        let pool = resetMatches.count > 1 ? resetMatches : candidates
        let sorted = pool.sorted {
            abs($0.usedPercent - last.usedPercent) < abs($1.usedPercent - last.usedPercent)
        }
        guard let best = sorted.first else { return nil }
        let bestDiff = abs(best.usedPercent - last.usedPercent)
        guard bestDiff <= Self.valueMatchTolerance else { return nil }
        if sorted.count > 1 {
            let secondDiff = abs(sorted[1].usedPercent - last.usedPercent)
            guard secondDiff - bestDiff >= Self.valueAmbiguityMargin else { return nil }
        }
        return best
    }

    private static func resetsEquivalent(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < Self.resetEquivalenceToleranceSeconds
    }

    private static func mergedEntries(
        _ entries: [PlanUtilizationHistoryEntry]) -> [PlanUtilizationHistoryEntry]
    {
        entries.reduce(into: []) { result, entry in
            guard !result.contains(entry) else { return }
            result.append(entry)
        }
    }
}
