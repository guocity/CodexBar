import AppKit
import CodexBarCore
import Combine
import SwiftUI

// MARK: - Stats settings pane

//
// A faithful AppKit port of the reference usage chart, hosted inside the SwiftUI settings window
// via `NSViewRepresentable`. AppKit is required because the chart owns gesture state that SwiftUI
// Charts cannot express: continuous pinch-to-zoom, two-finger horizontal pan, a hover tooltip for
// the nearest sample, and reset-line tooltips. This feature is confined to two new files — this
// one and `PreferencesStatsChart.swift` (the chart NSView) — so it stays easy to rebase on top of
// upstream `main`; the only edits elsewhere are the integration points (a `PreferencesTab.stats`
// case, the popup menu entry, the menu-action wiring, and the `tab_stats` localization key).
//
// The chart renders every series on ONE shared, absolute time axis. The visible portion of that
// axis is `[viewStart, viewEnd]` (unix seconds). Zoom and pan mutate that window directly and it
// survives data refreshes unchanged, so the timeline is continuous and the zoom level is stable.

// MARK: - Range presets

/// The visible-window presets for the chart. Mirrors the "5H … 1Y" toggle from the reference.
enum StatsRange: Int, CaseIterable {
    case fiveHours
    case day
    case week
    case month
    case threeMonths
    case year

    var title: String {
        switch self {
        case .fiveHours: "5H"
        case .day: "1D"
        case .week: "1W"
        case .month: "1M"
        case .threeMonths: "3M"
        case .year: "1Y"
        }
    }

    /// How far back from "now" this preset looks.
    var lookback: TimeInterval {
        switch self {
        case .fiveHours: 5 * 3600
        case .day: 86400
        case .week: 7 * 86400
        case .month: 30 * 86400
        case .threeMonths: 90 * 86400
        case .year: 365 * 86400
        }
    }

    /// A small forward extension so upcoming reset markers stay visible at the right edge.
    var lookforward: TimeInterval {
        switch self {
        case .fiveHours: 3600
        case .day: 3 * 3600
        case .week: 86400
        case .month: 3 * 86400
        case .threeMonths: 7 * 86400
        case .year: 14 * 86400
        }
    }
}

// MARK: - Provider sort

/// How the per-provider summaries (and their chart lines) are ordered. "Default" keeps the
/// store's provider order; the reset modes order by the soonest upcoming reset of the matching
/// window, so the provider that resets next floats to the top.
enum StatsSortMode: Int, CaseIterable {
    case defaultOrder
    case sessionReset
    case weeklyReset

    var title: String {
        switch self {
        case .defaultOrder: L("stats_sort_default")
        case .sessionReset: L("stats_sort_session")
        case .weeklyReset: L("stats_sort_weekly")
        }
    }

    /// The canonical window-minute range whose upcoming reset this mode sorts by, or `nil` for
    /// the default (unsorted) mode.
    var resetWindowMinutes: ClosedRange<Int>? {
        switch self {
        case .defaultOrder: nil
        case .sessionReset: 295...305
        case .weeklyReset: 10070...10090
        }
    }
}

// MARK: - Data model (adapted from the reference's AITokens_* types)

struct StatsSample {
    let value: Double
    let ts: Date
}

struct StatsWindow {
    let name: String
    let displayName: String
    let windowMinutes: Int
    let entries: [StatsEntry]

    var latest: StatsEntry? {
        self.entries.max { $0.capturedAt < $1.capturedAt }
    }
}

struct StatsEntry {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
}

struct StatsProvider {
    let id: String
    let name: String
    let baseColor: NSColor
    let windows: [StatsWindow]

    /// Lightens later windows so multiple lines from the same provider stay distinguishable.
    func color(forWindowIndex index: Int) -> NSColor {
        guard index > 0 else { return self.baseColor }
        let blend = min(0.5, CGFloat(index) * 0.28)
        let base = self.baseColor.usingColorSpace(.sRGB) ?? self.baseColor
        return NSColor(
            srgbRed: base.redComponent + (1 - base.redComponent) * blend,
            green: base.greenComponent + (1 - base.greenComponent) * blend,
            blue: base.blueComponent + (1 - base.blueComponent) * blend,
            alpha: 1)
    }
}

struct StatsHistoricalReset {
    let date: Date
    let color: NSColor
    let providerId: String
    let windowName: String
    let name: String
}

struct StatsAccountOption: Equatable {
    let id: String
    let label: String
}

struct StatsUsage {
    var providers: [StatsProvider] = []
    /// Codex visible accounts, when more than one exists, so the pane can offer an account picker.
    var codexAccounts: [StatsAccountOption] = []
    /// The Codex account currently being shown (resolved against the available accounts).
    var selectedCodexAccountID: String?

    var hasData: Bool {
        self.providers.contains { !$0.windows.isEmpty }
    }

    static let empty = StatsUsage()

    /// A live snapshot window before history is attached.
    private struct SnapshotWindow {
        let id: String
        let title: String
        let windowMinutes: Int
        let usedPercent: Double
        let resetsAt: Date?
        /// The plan-utilization series name the recorder would assign this window, used to attach
        /// historical points for the chart.
        let historyName: String
    }

    /// Builds the model from the live usage store. The window list, labels, and current values come
    /// from each provider's live snapshot (so they match the menu card — e.g. Cursor's Total/Auto/API
    /// tiers and Antigravity's per-service windows). Historical points for the chart are attached from
    /// plan-utilization history, matched by series name and — for lanes the recorder names in a way the
    /// snapshot can't reproduce (Cursor's total/auto/api, Antigravity's per-pool series) — by same-window
    /// value continuity, so every lane attaches its own recorded history instead of a lone live dot.
    ///
    /// Codex has multiple visible accounts; `codexAccountID` selects which one to show (its snapshot
    /// and its account-scoped history), defaulting to the active account so accounts never mix.
    @MainActor
    static func build(store: UsageStore, codexAccountID: String? = nil) -> StatsUsage {
        let codexProjection = store.settings.codexVisibleAccountProjection
        let codexVisible = codexProjection.visibleAccounts
        let resolvedCodexID = codexVisible.first(where: { $0.id == codexAccountID })?.id
            ?? codexProjection.activeVisibleAccountID
            ?? codexVisible.first?.id

        var providers: [StatsProvider] = []
        for provider in store.enabledProviders() {
            let metadata = store.metadata(for: provider)
            let (snapshot, histories) = Self.providerData(
                provider,
                store: store,
                codexAccounts: codexVisible,
                resolvedCodexID: resolvedCodexID,
                codexActiveID: codexProjection.activeVisibleAccountID)

            let branding = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
            let base = NSColor(srgbRed: branding.red, green: branding.green, blue: branding.blue, alpha: 1)

            let windows = Self.windows(snapshot: snapshot, histories: histories, provider: provider, metadata: metadata)
            guard !windows.isEmpty else { continue }
            providers.append(StatsProvider(
                id: provider.rawValue, name: metadata.displayName, baseColor: base, windows: windows))
        }

        return StatsUsage(
            providers: providers,
            codexAccounts: codexVisible.count > 1
                ? codexVisible.map { StatsAccountOption(id: $0.id, label: $0.displayName) }
                : [],
            selectedCodexAccountID: codexVisible.count > 1 ? resolvedCodexID : nil)
    }

    /// Resolves the snapshot + history for a provider, scoping Codex to the selected account.
    @MainActor
    private static func providerData(
        _ provider: UsageProvider,
        store: UsageStore,
        codexAccounts: [CodexVisibleAccount],
        resolvedCodexID: String?,
        codexActiveID: String?) -> (UsageSnapshot?, [PlanUtilizationSeriesHistory])
    {
        let allHistory = { (history: [PlanUtilizationSeriesHistory]) in
            history.filter { !$0.entries.isEmpty && $0.windowMinutes > 0 }
        }
        guard provider == .codex, let account = codexAccounts.first(where: { $0.id == resolvedCodexID }) else {
            return (store.snapshot(for: provider), allHistory(store.planUtilizationHistory(for: provider)))
        }
        let snapshot = store.codexAccountSnapshots.first(where: { $0.id == account.id })?.snapshot
            ?? (account.id == codexActiveID ? store.snapshot(for: .codex) : nil)
        return (snapshot, allHistory(store.codexPlanUtilizationHistories(forVisibleAccount: account)))
    }

    /// Builds a provider's windows: from the live snapshot when present (so stale tiers the snapshot
    /// no longer reports — e.g. an inactive Claude Sonnet limit — do not linger), otherwise from any
    /// recorded history as a fallback.
    private static func windows(
        snapshot: UsageSnapshot?,
        histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        metadata: ProviderMetadata) -> [StatsWindow]
    {
        guard let snapshot else {
            return histories
                .map { history in
                    StatsWindow(
                        name: history.name.rawValue,
                        displayName: self.windowLabel(history.name, metadata: metadata),
                        windowMinutes: history.windowMinutes,
                        entries: self.entries(history.entries))
                }
                .filter(self.isActive)
        }

        let updatedAt = snapshot.updatedAt
        var windows: [StatsWindow] = []
        var claimedSeries = Set<String>()
        for snap in Self.snapshotWindows(snapshot, provider: provider, metadata: metadata) {
            // Prefer an exact series-name match; otherwise attach the recorded series of the same
            // window length whose latest value tracks this window (lanes sharing a window — e.g.
            // Cursor's total/auto/api, Antigravity's per-pool series — are named by the recorder in
            // a way the snapshot can't reproduce, so fall back to value continuity instead of
            // dropping the history and rendering a lone dot).
            let match = histories.first {
                $0.name.rawValue == snap.historyName && !claimedSeries.contains(Self.seriesID($0))
            } ?? Self.nearestHistory(to: snap, in: histories, claimed: claimedSeries)
            if let match { claimedSeries.insert(Self.seriesID(match)) }
            var entries = match.map { Self.entries($0.entries) } ?? []
            // Always reflect the live value as the most recent point.
            if (entries.last?.capturedAt ?? .distantPast) < updatedAt.addingTimeInterval(-1) {
                entries.append(StatsEntry(
                    capturedAt: updatedAt,
                    usedPercent: max(0, min(100, snap.usedPercent)),
                    resetsAt: statsRecordedResetBoundary(
                        usedPercent: snap.usedPercent,
                        liveReset: snap.resetsAt,
                        priorEntries: entries,
                        capturedAt: updatedAt)))
            }
            windows.append(StatsWindow(
                name: snap.id,
                displayName: snap.title,
                windowMinutes: snap.windowMinutes,
                entries: entries.sorted { $0.capturedAt < $1.capturedAt }))
        }
        return windows.filter(Self.isActive)
    }

    /// Whether a window represents an active limit worth showing. An inactive tier — e.g. Claude's
    /// Sonnet limit on a plan that doesn't track it — has no upcoming reset and no usage, so it is
    /// dropped. Windows with a future reset (even at 0%) or any usage (e.g. non-resetting credit
    /// balances) are kept.
    private static func isActive(_ window: StatsWindow) -> Bool {
        let now = Date()
        if statsUpcomingReset(window, from: now) != nil { return true }
        return (window.latest?.usedPercent ?? 0) > 0.5
    }

    private static func entries(_ entries: [PlanUtilizationHistoryEntry]) -> [StatsEntry] {
        let sorted = entries.sorted { $0.capturedAt < $1.capturedAt }
        var result: [StatsEntry] = []
        result.reserveCapacity(sorted.count)
        for entry in sorted {
            let usedPercent = max(0, min(100, entry.usedPercent))
            result.append(StatsEntry(
                capturedAt: entry.capturedAt,
                usedPercent: usedPercent,
                resetsAt: statsRecordedResetBoundary(
                    usedPercent: usedPercent,
                    liveReset: entry.resetsAt,
                    priorEntries: result,
                    capturedAt: entry.capturedAt)))
        }
        return result
    }

    private static func seriesID(_ history: PlanUtilizationSeriesHistory) -> String {
        "\(history.name.rawValue):\(history.windowMinutes)"
    }

    /// Fallback used when no recorded series name matches a live window: the unclaimed series of the
    /// same window length whose latest value is closest to the window's current value. The recorder
    /// always records the live value, so the matching lane's latest point coincides with it.
    private static func nearestHistory(
        to snap: SnapshotWindow,
        in histories: [PlanUtilizationSeriesHistory],
        claimed: Set<String>) -> PlanUtilizationSeriesHistory?
    {
        histories
            .filter { $0.windowMinutes == snap.windowMinutes && !claimed.contains(Self.seriesID($0)) }
            .min {
                abs(($0.entries.last?.usedPercent ?? 0) - snap.usedPercent)
                    < abs(($1.entries.last?.usedPercent ?? 0) - snap.usedPercent)
            }
    }

    /// Enumerates a provider's live windows with their display titles, mirroring the menu card:
    /// primary/secondary/tertiary are labelled from metadata; `extraRateWindows` keep their own
    /// titles; Antigravity uses only its per-service quota-summary windows when present.
    private static func snapshotWindows(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        metadata: ProviderMetadata) -> [SnapshotWindow]
    {
        let antigravitySummaryPrefix = "antigravity-quota-summary-"
        if provider == .antigravity,
           let extras = snapshot.extraRateWindows,
           extras.contains(where: { $0.id.hasPrefix(antigravitySummaryPrefix) })
        {
            return extras
                .filter(\.usageKnown)
                .map { Self.snapshotWindow(fromExtra: $0) }
        }

        // Copilot's monthly quotas/budgets carry no window duration; stamp the same canonical
        // monthly window the recorder uses so each live window lines up with its recorded series.
        let defaultWindowMinutes = provider == .copilot ? UsageStore.copilotMonthlyWindowMinutes : 0

        var result: [SnapshotWindow] = []
        if let primary = snapshot.primary {
            result.append(Self.snapshotWindow(
                from: primary,
                id: "primary",
                title: L(metadata.sessionLabel),
                historyName: Self.historyName(.session, windowMinutes: primary.windowMinutes, provider: provider),
                defaultWindowMinutes: defaultWindowMinutes))
        }
        if let secondary = snapshot.secondary {
            result.append(Self.snapshotWindow(
                from: secondary,
                id: "secondary",
                title: L(metadata.weeklyLabel),
                historyName: Self.historyName(.weekly, windowMinutes: secondary.windowMinutes, provider: provider),
                defaultWindowMinutes: defaultWindowMinutes))
        }
        if metadata.supportsOpus, let tertiary = snapshot.tertiary {
            result.append(Self.snapshotWindow(
                from: tertiary,
                id: "tertiary",
                title: metadata.opusLabel.map(L) ?? L("Opus"),
                historyName: Self.historyName(.opus, windowMinutes: tertiary.windowMinutes, provider: provider),
                defaultWindowMinutes: defaultWindowMinutes))
        }
        // Codex's extra windows are optional credits/usage; keep the summary focused on the core windows.
        if provider != .codex, let extras = snapshot.extraRateWindows {
            for extra in extras where extra.usageKnown {
                result.append(Self.snapshotWindow(fromExtra: extra, defaultWindowMinutes: defaultWindowMinutes))
            }
        }
        return result
    }

    private static func snapshotWindow(
        from window: RateWindow,
        id: String,
        title: String,
        historyName: String,
        defaultWindowMinutes: Int = 0) -> SnapshotWindow
    {
        SnapshotWindow(
            id: id,
            title: title,
            windowMinutes: window.windowMinutes ?? defaultWindowMinutes,
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt,
            historyName: historyName)
    }

    private static func snapshotWindow(
        fromExtra named: NamedRateWindow,
        defaultWindowMinutes: Int = 0) -> SnapshotWindow
    {
        let minutes = named.window.windowMinutes ?? defaultWindowMinutes
        let historyName = Self.isAntigravityQuotaSummaryWindow(named.id)
            ? Self.antigravityHistoryName(for: named)
            : Self.genericHistoryName(windowMinutes: minutes)
        return SnapshotWindow(
            id: named.id,
            title: named.title,
            windowMinutes: minutes,
            usedPercent: named.window.usedPercent,
            resetsAt: named.window.resetsAt,
            historyName: historyName)
    }

    private static func isAntigravityQuotaSummaryWindow(_ id: String) -> Bool {
        id.hasPrefix("antigravity-quota-summary-")
    }

    /// Matches `UsageStore.antigravitySeriesName(for:)` so each quota pool attaches its own history.
    private static func antigravityHistoryName(for named: NamedRateWindow) -> String {
        let slug = Self.seriesSlug(named.title)
        return slug.isEmpty ? named.id : slug
    }

    /// Lowercases `raw` and collapses every run of non-alphanumeric characters into a single dash.
    private static func seriesSlug(_ raw: String) -> String {
        var result = ""
        var pendingDash = false
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingDash, !result.isEmpty { result.append("-") }
                pendingDash = false
                result.append(character)
            } else {
                pendingDash = true
            }
        }
        return result
    }

    /// The series name the recorder assigns. Codex/Claude (and Copilot) record by role
    /// (session/weekly/opus); every other provider records its weekly lane, mapped here from the
    /// window duration to the canonical `.weekly`/`.session` names via `genericHistoryName`.
    private static func historyName(
        _ role: PlanUtilizationSeriesName,
        windowMinutes: Int?,
        provider: UsageProvider) -> String
    {
        if provider == .codex || provider == .claude || provider == .copilot {
            // Copilot records its two monthly quotas by role (Premium → session, Chat → weekly),
            // matching the recorder, so the live window maps straight onto its recorded series.
            return role.rawValue
        }
        return self.genericHistoryName(windowMinutes: windowMinutes ?? 0)
    }

    private static func genericHistoryName(windowMinutes: Int) -> String {
        switch windowMinutes {
        case 295...305: PlanUtilizationSeriesName.session.rawValue
        case 10070...10090: PlanUtilizationSeriesName.weekly.rawValue
        default: "window-\(windowMinutes)m"
        }
    }

    private static func windowLabel(_ name: PlanUtilizationSeriesName, metadata: ProviderMetadata) -> String {
        switch name {
        case .session: L(metadata.sessionLabel)
        case .weekly: L(metadata.weeklyLabel)
        case .opus: metadata.opusLabel.map(L) ?? L("Opus")
        default:
            name.rawValue.prefix(1).uppercased() + name.rawValue.dropFirst()
        }
    }
}

extension StatsUsage {
    /// Test seam: Antigravity quota pools must map onto the same series slugs the recorder uses.
    internal static func antigravityHistoryNameForTests(title: String, id: String) -> String {
        Self.antigravityHistoryName(for: NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)))
    }
}

// MARK: - Reset / formatting helpers

/// The next reset for a window: the furthest `resetsAt` still in the future, else `nil` (inactive).
func statsUpcomingReset(_ window: StatsWindow, from now: Date) -> Date? {
    let future = window.entries.compactMap(\.resetsAt).filter { $0 > now }
    return future.max()
}

/// The soonest upcoming reset across a provider's windows whose duration falls in
/// `windowMinutes` (e.g. the ~5h session window or the ~7d weekly window), or `nil` when the
/// provider has no such active window. Used to order providers in the Stats pane.
///
/// For an unused provider the matching window keeps rolling forward, so each reading records a
/// fresh reset boundary; `statsUpcomingReset` already collapses those to the single latest one,
/// and this returns that same displayed value so the sort matches what the row shows.
func statsProviderReset(_ provider: StatsProvider, in windowMinutes: ClosedRange<Int>, from now: Date) -> Date? {
    provider.windows
        .filter { windowMinutes.contains($0.windowMinutes) }
        .compactMap { statsUpcomingReset($0, from: now) }
        .min()
}

/// Orders providers for the Stats pane. The default mode preserves the incoming order; the reset
/// modes sort by the soonest matching upcoming reset (ascending), with providers that have no such
/// reset pushed to the end. The sort is stable: ties (and the no-reset tail) keep their original
/// relative order.
func statsSortedProviders(_ providers: [StatsProvider], mode: StatsSortMode, now: Date) -> [StatsProvider] {
    guard let windowMinutes = mode.resetWindowMinutes else { return providers }
    return providers.enumerated().sorted { lhs, rhs in
        let lhsReset = statsProviderReset(lhs.element, in: windowMinutes, from: now)
        let rhsReset = statsProviderReset(rhs.element, in: windowMinutes, from: now)
        switch (lhsReset, rhsReset) {
        case let (left?, right?):
            return left == right ? lhs.offset < rhs.offset : left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return lhs.offset < rhs.offset
        }
    }.map(\.element)
}

/// Whether a window has ever recorded meaningful usage. Unused providers keep rolling their reset
/// boundary forward on every refresh; those phantom past resets must not clutter the chart.
func statsWindowHasRecordedUsage(_ window: StatsWindow) -> Bool {
    window.entries.contains { $0.usedPercent > 0.5 }
}

/// At 0% the live API nudges past `resetsAt` samples on every poll. Freeze only boundaries that
/// are already past at capture time; keep future resets so weekly/session countdowns stay visible.
func statsRecordedResetBoundary(
    usedPercent: Double,
    liveReset: Date?,
    priorEntries: [StatsEntry],
    capturedAt: Date) -> Date?
{
    if usedPercent > 0.5 {
        return liveReset
    }
    if let liveReset, liveReset > capturedAt {
        return liveReset
    }
    return priorEntries.last?.resetsAt ?? liveReset
}

/// At most one reset marker per quota-window length. Frequent polls nudge `resetsAt` slightly, so
/// without spacing every sampled boundary becomes its own stripe (especially on Codex's ~5h session).
func statsCoalescedResetDates(_ dates: [Date], windowMinutes: Int) -> [Date] {
    guard windowMinutes > 0 else { return dates.sorted() }
    let minSpacing = TimeInterval(windowMinutes * 60)
    var result: [Date] = []
    for date in dates.sorted() {
        if let last = result.last, date.timeIntervalSince(last) < minSpacing {
            continue
        }
        result.append(date)
    }
    return result
}

/// Past reset boundaries per provider+window, for the thin historical marker lines.
func statsHistoricalResets(_ providers: [StatsProvider], before now: Date) -> [StatsHistoricalReset] {
    var result: [StatsHistoricalReset] = []
    for provider in providers {
        for (index, window) in provider.windows.enumerated() {
            guard statsWindowHasRecordedUsage(window) else { continue }
            let color = provider.color(forWindowIndex: index)
            let pastDates = window.entries.compactMap(\.resetsAt).filter { $0 <= now }
            for date in statsCoalescedResetDates(pastDates, windowMinutes: window.windowMinutes) {
                result.append(StatsHistoricalReset(
                    date: date, color: color, providerId: provider.id, windowName: window.name,
                    name: "\(provider.name) \(window.displayName)"))
            }
        }
    }
    return result
}

func statsCountdown(to date: Date, from now: Date) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.maximumUnitCount = 2
    let interval = max(0, date.timeIntervalSince(now))
    if interval < 60 { return L("now") }
    return formatter.string(from: interval) ?? "—"
}

func statsAbsoluteDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = codexBarLocalizedLocale()
    formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
    return formatter.string(from: date)
}

func statsRelativeAge(_ date: Date, from now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = codexBarLocalizedLocale()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: now)
}

// MARK: - SwiftUI hosting

@MainActor
struct StatsPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    @State private var tick = 0

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        // Reading the revision/tick here makes the body (and thus `updateNSView`) re-run when the
        // underlying data changes or the periodic timer fires, keeping "now" and countdowns fresh.
        StatsChartRepresentable(store: self.store, revision: self.revision)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(self.ticker) { _ in self.tick &+= 1 }
    }

    private var revision: Int {
        self.store.planUtilizationHistoryRevision &+ self.tick
    }
}

@MainActor
struct StatsChartRepresentable: NSViewRepresentable {
    let store: UsageStore
    /// Changes whenever the data should be rebuilt; read in the parent body so SwiftUI re-runs
    /// `updateNSView`. The value itself is unused — the root view rebuilds from `store`.
    let revision: Int

    func makeNSView(context _: Context) -> StatsRootView {
        StatsRootView()
    }

    func updateNSView(_ nsView: StatsRootView, context _: Context) {
        nsView.update(store: self.store)
    }
}

// MARK: - Root view (port of AITokensPreview)

@MainActor
final class StatsRootView: NSView {
    /// Fixed header holding the usage chart; it never scrolls.
    private let chartHost = NSStackView()
    private let scrollView = NSScrollView()
    private let stack = FlippedStackView()
    private let usageChart = StatsMultiLineChart(fixedYMax: 100) { "\(Int($0.rounded()))%" }

    private let rangeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: StatsRange.allCases.map(\.title),
            trackingMode: .selectOne,
            target: nil,
            action: nil)
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()

    private let sortControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: StatsSortMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: nil,
            action: nil)
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.translatesAutoresizingMaskIntoConstraints = false
        control.toolTip = L("stats_sort_tooltip")
        return control
    }()

    private static let rangeDefaultsKey = "Stats_rangeIndex"
    private static let sortDefaultsKey = "Stats_sortMode"
    private var selectedRange: StatsRange = .week
    private var sortMode: StatsSortMode = .defaultOrder
    private var signature = ""
    private var summaryPanels: [String: StatsSummaryPanel] = [:]
    private var selectedSeriesKey: (providerId: String, windowName: String)?

    /// The live store, captured from `updateNSView`, so account/range changes can rebuild in place.
    private weak var store: UsageStore?
    /// Which Codex account the pane is showing (when more than one exists).
    private var selectedCodexAccountID: String?
    /// The Codex accounts available for the picker (cached for the picker's action handler).
    private var codexAccounts: [StatsAccountOption] = []
    /// Provider IDs the user has toggled off in the Stats pane (hidden from chart + summary).
    private var hiddenProviders: Set<String> = []
    private static let hiddenProvidersKey = "Stats_hiddenProviders"

    override init(frame: NSRect) {
        super.init(frame: frame)
        let saved = UserDefaults.standard.object(forKey: Self.rangeDefaultsKey) as? Int
        self.selectedRange = saved.flatMap(StatsRange.init(rawValue:)) ?? .week
        let savedSort = UserDefaults.standard.object(forKey: Self.sortDefaultsKey) as? Int
        self.sortMode = savedSort.flatMap(StatsSortMode.init(rawValue:)) ?? .defaultOrder
        self.hiddenProviders = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenProvidersKey) ?? [])

        self.chartHost.orientation = .vertical
        self.chartHost.alignment = .leading
        self.chartHost.spacing = 8
        self.chartHost.translatesAutoresizingMaskIntoConstraints = false
        self.chartHost.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        self.chartHost.setContentHuggingPriority(.required, for: .vertical)

        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.hasVerticalScroller = true
        self.scrollView.drawsBackground = false
        self.scrollView.automaticallyAdjustsContentInsets = false

        self.stack.orientation = .vertical
        self.stack.alignment = .leading
        self.stack.spacing = 16
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)

        let clip = self.scrollView.contentView
        self.scrollView.documentView = self.stack
        self.addSubview(self.chartHost)
        self.addSubview(self.scrollView)
        NSLayoutConstraint.activate([
            self.chartHost.topAnchor.constraint(equalTo: self.topAnchor),
            self.chartHost.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.chartHost.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.scrollView.topAnchor.constraint(equalTo: self.chartHost.bottomAnchor),
            self.scrollView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.scrollView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.scrollView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            self.stack.topAnchor.constraint(equalTo: clip.topAnchor),
            self.stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            self.stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            self.stack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

        self.rangeControl.target = self
        self.rangeControl.action = #selector(self.rangeChanged(_:))
        self.rangeControl.selectedSegment = self.selectedRange.rawValue

        self.sortControl.target = self
        self.sortControl.action = #selector(self.sortChanged(_:))
        self.sortControl.selectedSegment = self.sortMode.rawValue

        // Continuous zoom/pan only moves the highlight to the closest preset — it never changes
        // the persisted range or recomputes the viewport. The chart owns the viewport.
        self.usageChart.onZoomOrPan = { [weak self] range in
            self?.rangeControl.selectedSegment = range.rawValue
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Apply data

    /// Called from `updateNSView`: capture the store and rebuild from the current selection.
    func update(store: UsageStore) {
        self.store = store
        self.reload()
    }

    /// Rebuilds the model from the store for the current Codex-account / range selection.
    private func reload() {
        guard let store else { return }
        var usage = StatsUsage.build(store: store, codexAccountID: self.selectedCodexAccountID)
        self.selectedCodexAccountID = usage.selectedCodexAccountID
        usage.providers = statsSortedProviders(usage.providers, mode: self.sortMode, now: Date())
        self.apply(usage)
    }

    private func apply(_ usage: StatsUsage) {
        let signature = self.signature(for: usage)
        if signature != self.signature {
            self.rebuild(usage)
        } else {
            self.refresh(usage)
        }
    }

    private func signature(for usage: StatsUsage) -> String {
        let hidden = self.hiddenProviders.sorted().joined(separator: ",")
        return "\(hidden)!" + Self.signature(for: usage)
    }

    private static func signature(for usage: StatsUsage) -> String {
        let accounts = usage.codexAccounts.map(\.id).joined(separator: ",")
        let providers = usage.providers
            .map { "\($0.id):" + $0.windows.map(\.name).joined(separator: ",") }
            .joined(separator: "|")
        return "\(usage.selectedCodexAccountID ?? "-")#\(accounts)#\(providers)" + (usage.hasData ? "" : "·empty")
    }

    /// Adds an arranged subview pinned to a stack's full width (an `.leading`-aligned `NSStackView`
    /// otherwise sizes children to their hugging width, collapsing the chart).
    private func addFullWidth(_ view: NSView, to target: NSStackView) {
        target.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: target.widthAnchor).isActive = true
    }

    private func rebuild(_ usage: StatsUsage) {
        self.chartHost.arrangedSubviews.forEach { $0.removeFromSuperview() }
        self.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        self.summaryPanels.removeAll()
        self.signature = self.signature(for: usage)

        guard usage.hasData else {
            self.addFullWidth(statsSection(
                title: L("stats_title"),
                StatsEmptyView()), to: self.stack)
            return
        }

        // Usage-history chart is pinned to the top (in `chartHost`) so it never scrolls; the
        // per-provider summaries scroll below it.
        self.addFullWidth(statsSection(
            title: L("stats_usage_history"),
            self.chartContainer()), to: self.chartHost)

        self.codexAccounts = usage.codexAccounts
        for provider in usage.providers where !provider.windows.isEmpty {
            let isVisible = !self.hiddenProviders.contains(provider.id)
            // Click the provider name to hide/show it from the chart + summary. Codex also gets an
            // account switch (it shows one account — the primary/active by default — never a mix).
            let picker = provider.id == UsageProvider.codex.rawValue
                ? self.makeCodexAccountPicker(selectedID: usage.selectedCodexAccountID)
                : nil
            let providerID = provider.id
            let panel = StatsSummaryPanel(
                provider: provider,
                accessory: picker,
                contentHidden: !isVisible,
                onTitleClick: { [weak self] in self?.toggleProviderVisibility(providerID) },
                onWindowClicked: { [weak self] providerId, windowName in
                    self?.rowClicked(providerId: providerId, windowName: windowName)
                })
            self.summaryPanels[provider.id] = panel
            self.addFullWidth(panel.section, to: self.stack)
        }

        self.refresh(usage)
        self.updateRowSelectionStates()
    }

    private func toggleProviderVisibility(_ providerID: String) {
        if self.hiddenProviders.contains(providerID) {
            self.hiddenProviders.remove(providerID)
        } else {
            self.hiddenProviders.insert(providerID)
        }
        UserDefaults.standard.set(Array(self.hiddenProviders), forKey: Self.hiddenProvidersKey)
        self.reload()
    }

    private func makeCodexAccountPicker(selectedID: String?) -> NSView? {
        guard self.codexAccounts.count > 1 else { return nil }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: self.codexAccounts.map(\.label))
        if let selectedID, let index = self.codexAccounts.firstIndex(where: { $0.id == selectedID }) {
            popup.selectItem(at: index)
        }
        popup.target = self
        popup.action = #selector(self.codexAccountChanged(_:))
        return popup
    }

    @objc private func codexAccountChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < self.codexAccounts.count else { return }
        self.selectedCodexAccountID = self.codexAccounts[index].id
        self.reload()
    }

    private func refresh(_ usage: StatsUsage) {
        let now = Date()
        var series: [StatsMultiLineChart.Series] = []
        for provider in usage.providers {
            self.summaryPanels[provider.id]?.update(provider, now: now)
            // Hidden providers keep their (collapsed) section header so they can be re-enabled,
            // but contribute no lines to the chart.
            guard !self.hiddenProviders.contains(provider.id) else { continue }
            for (index, window) in provider.windows.enumerated() {
                let points = window.entries.map { StatsSample(value: $0.usedPercent, ts: $0.capturedAt) }
                guard !points.isEmpty else { continue }
                series.append(.init(
                    name: "\(provider.name) \(window.displayName)",
                    color: provider.color(forWindowIndex: index),
                    points: points,
                    upcomingReset: statsUpcomingReset(window, from: now),
                    windowMinutes: window.windowMinutes,
                    windowName: window.name,
                    providerId: provider.id))
            }
        }

        let visibleProviders = usage.providers.filter { !self.hiddenProviders.contains($0.id) }
        let historical = statsHistoricalResets(visibleProviders, before: now)
        self.updateRangeAvailability(usage, now: now)
        self.usageChart.setData(
            series: series,
            now: now,
            historicalResets: historical,
            initialPreset: self.selectedRange)
        self.updateRowSelectionStates()
    }

    // MARK: Selection

    private func rowClicked(providerId: String, windowName: String) {
        if self.selectedSeriesKey?.providerId == providerId,
           self.selectedSeriesKey?.windowName == windowName
        {
            self.selectedSeriesKey = nil
        } else {
            self.selectedSeriesKey = (providerId, windowName)
        }
        self.usageChart.setHighlightedSeries(
            providerId: self.selectedSeriesKey?.providerId,
            windowName: self.selectedSeriesKey?.windowName)
        self.updateRowSelectionStates()
    }

    private func updateRowSelectionStates() {
        for panel in self.summaryPanels.values {
            panel.updateSelection(selectedKey: self.selectedSeriesKey)
        }
    }

    // MARK: Range availability / changes

    /// Enables only the ranges the data actually spans; the shortest range stays enabled as a floor.
    private func updateRangeAvailability(_ usage: StatsUsage, now: Date) {
        let timestamps = usage.providers.flatMap { $0.windows.flatMap { $0.entries.map(\.capturedAt) } }
        let span = (timestamps.max()?.timeIntervalSince(timestamps.min() ?? now)) ?? 0
        var enabledRanges: [StatsRange] = []
        for range in StatsRange.allCases {
            let enabled: Bool = if let prev = StatsRange(rawValue: range.rawValue - 1) {
                span > prev.lookback
            } else {
                true
            }
            self.rangeControl.setEnabled(enabled, forSegment: range.rawValue)
            if enabled { enabledRanges.append(range) }
        }
        if !enabledRanges.contains(self.selectedRange), let fallback = enabledRanges.last {
            self.selectedRange = fallback
            UserDefaults.standard.set(fallback.rawValue, forKey: Self.rangeDefaultsKey)
            self.rangeControl.selectedSegment = fallback.rawValue
        }
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        guard let range = StatsRange(rawValue: sender.selectedSegment) else { return }
        self.selectedRange = range
        UserDefaults.standard.set(range.rawValue, forKey: Self.rangeDefaultsKey)
        self.usageChart.applyPreset(range, animated: true)
    }

    @objc private func sortChanged(_ sender: NSSegmentedControl) {
        guard let mode = StatsSortMode(rawValue: sender.selectedSegment) else { return }
        self.sortMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.sortDefaultsKey)
        // Re-sort the provider summaries (and their chart lines) in place; the new order changes
        // the signature, so this rebuilds the stacked panels rather than only refreshing values.
        self.reload()
    }

    // MARK: Layout helpers

    private func chartContainer() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(self.sortControl)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(self.rangeControl)
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(row)

        self.usageChart.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(self.usageChart)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: container.widthAnchor),
            self.usageChart.widthAnchor.constraint(equalTo: container.widthAnchor),
            self.usageChart.heightAnchor.constraint(equalToConstant: 180),
        ])
        return container
    }
}

/// A vertical stack that lays its content out top-down inside a scroll view.
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool {
        true
    }
}

// MARK: - Titled section + empty state

@MainActor
func statsSection(title: String?, _ content: NSView) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    if let title {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        stack.addArrangedSubview(header)
    }
    content.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(content)
    content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return stack
}

final class StatsEmptyView: NSView {
    init() {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 26, weight: .regular)

        let title = NSTextField(labelWithString: L("stats_empty_title"))
        title.font = .systemFont(ofSize: 13)
        title.alignment = .center

        let subtitle = NSTextField(wrappingLabelWithString: L("stats_empty_subtitle"))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 360

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Per-provider summary (port of AITokensSummaryPanel + ClickableRow)

private final class StatsClickableRow: NSStackView {
    var onClick: (() -> Void)?
    var isHovered = false {
        didSet { self.needsDisplay = true }
    }

    var isSelected = false {
        didSet { self.needsDisplay = true }
    }

    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = self.trackingArea { self.removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        self.isHovered = true
    }

    override func mouseExited(with _: NSEvent) {
        self.isHovered = false
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        self.onClick?()
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        let color: NSColor = if self.isSelected {
            NSColor.textColor.withAlphaComponent(0.08)
        } else if self.isHovered {
            NSColor.textColor.withAlphaComponent(0.04)
        } else {
            .clear
        }
        self.layer?.backgroundColor = color.cgColor
        self.layer?.cornerRadius = 4
    }
}

/// A section title that toggles its provider's visibility when clicked, with a pointing-hand
/// cursor and hover/dim feedback so it reads as interactive.
private final class StatsClickableTitle: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dimmed: Bool
    private var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    init(text: String, dimmed: Bool, onClick: @escaping () -> Void) {
        self.dimmed = dimmed
        super.init(frame: .zero)
        self.onClick = onClick
        self.translatesAutoresizingMaskIntoConstraints = false
        self.label.stringValue = text
        self.label.font = .systemFont(ofSize: 11, weight: .semibold)
        self.label.textColor = self.restingColor
        self.label.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.label)
        NSLayoutConstraint.activate([
            self.label.topAnchor.constraint(equalTo: self.topAnchor),
            self.label.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            self.label.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.label.trailingAnchor.constraint(equalTo: self.trailingAnchor),
        ])
        self.toolTip = self.dimmed ? L("Show in Stats") : L("Hide from Stats")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var restingColor: NSColor {
        self.dimmed ? .tertiaryLabelColor : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = self.trackingArea { self.removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with _: NSEvent) {
        self.label.textColor = .labelColor
    }

    override func mouseExited(with _: NSEvent) {
        self.label.textColor = self.restingColor
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        self.onClick?()
    }
}

@MainActor
private final class StatsSummaryPanel {
    let section: NSView
    private let provider: StatsProvider
    private var windowFields: [String: (used: NSTextField, reset: NSTextField, updated: NSTextField)] = [:]
    private var windowRows: [String: StatsClickableRow] = [:]

    init(
        provider: StatsProvider,
        accessory: NSView? = nil,
        contentHidden: Bool = false,
        onTitleClick: @escaping () -> Void,
        onWindowClicked: @escaping (String, String) -> Void)
    {
        self.provider = provider
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = contentHidden

        for (index, window) in provider.windows.enumerated() {
            let color = provider.color(forWindowIndex: index)
            let row = StatsClickableRow()
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            let providerId = provider.id
            let windowName = window.name
            row.onClick = { onWindowClicked(providerId, windowName) }

            let swatch = StatsColorSwatch(color: color)
            swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true

            let nameField = NSTextField(labelWithString: window.displayName)
            nameField.font = .systemFont(ofSize: 12, weight: .medium)
            nameField.widthAnchor.constraint(equalToConstant: 78).isActive = true

            let usedField = NSTextField(labelWithString: "—")
            usedField.font = .systemFont(ofSize: 12, weight: .semibold)
            usedField.widthAnchor.constraint(equalToConstant: 46).isActive = true

            let resetField = NSTextField(labelWithString: "—")
            resetField.font = .systemFont(ofSize: 11, weight: .regular)
            resetField.textColor = .secondaryLabelColor
            resetField.lineBreakMode = .byTruncatingTail

            let updatedField = NSTextField(labelWithString: "—")
            updatedField.font = .systemFont(ofSize: 10, weight: .light)
            updatedField.textColor = .tertiaryLabelColor
            updatedField.alignment = .right

            row.addArrangedSubview(swatch)
            row.addArrangedSubview(nameField)
            row.addArrangedSubview(usedField)
            row.addArrangedSubview(resetField)
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(updatedField)
            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

            self.windowFields[window.name] = (usedField, resetField, updatedField)
            self.windowRows[window.name] = row
        }

        // Clicking the provider name toggles its visibility (replaces a checkbox); the title dims
        // when the provider is hidden so the state stays obvious.
        let titleView = StatsClickableTitle(
            text: provider.name.uppercased(),
            dimmed: contentHidden,
            onClick: onTitleClick)
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(titleView)
        headerRow.addArrangedSubview(NSView())
        if let accessory {
            headerRow.addArrangedSubview(accessory)
        }

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(headerRow)
        outer.addArrangedSubview(container)
        headerRow.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        container.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        self.section = outer
    }

    func update(_ provider: StatsProvider, now: Date) {
        for window in provider.windows {
            guard let fields = self.windowFields[window.name], let latest = window.latest else { continue }
            fields.used.stringValue = "\(Int(latest.usedPercent.rounded()))%"
            if let upcoming = statsUpcomingReset(window, from: now) {
                fields.reset.stringValue = "\(L("resets")) \(statsCountdown(to: upcoming, from: now)) · "
                    + statsAbsoluteDate(upcoming)
            } else {
                fields.reset.stringValue = "\(L("inactive")) · \(L("last seen")) "
                    + statsRelativeAge(latest.capturedAt, from: now)
            }
            fields.updated.stringValue = statsRelativeAge(latest.capturedAt, from: now)
        }
    }

    func updateSelection(selectedKey: (providerId: String, windowName: String)?) {
        for (windowName, row) in self.windowRows {
            if let key = selectedKey {
                let isThis = key.providerId == self.provider.id && key.windowName == windowName
                row.isSelected = isThis
                row.alphaValue = isThis ? 1.0 : 0.4
            } else {
                row.isSelected = false
                row.alphaValue = 1.0
            }
        }
    }
}

private final class StatsColorSwatch: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = color.cgColor
        self.layer?.cornerRadius = 2
        self.translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
