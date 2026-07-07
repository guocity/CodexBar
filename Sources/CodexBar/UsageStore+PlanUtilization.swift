import CodexBarCore
import Foundation

extension UsageStore {
    private nonisolated static let limitResetThreshold = 1.0
    nonisolated static let sessionLimitResetDetectorDefaultsKey = "sessionLimitResetDetectorStates"
    private nonisolated static let weeklyLimitResetDetectorDefaultsKey = "weeklyLimitResetDetectorStates"
    private nonisolated static let claudeOAuthAccountUuidMapDefaultsKey = "ClaudeOAuthHistoryOwnerAccountUuidMapV1"
    private nonisolated static let claudeOAuthAccountCandidateMapDefaultsKey =
        "ClaudeOAuthHistoryOwnerAccountCandidateMapV1"
    private nonisolated static let weeklyWindowMinutes = 7 * 24 * 60
    /// Canonical window length for Copilot's monthly-resetting quotas/budgets, which report
    /// no window duration of their own. Stamped on recorded samples so they reach history and
    /// stay grouped as one stable series across refreshes (real month lengths vary).
    nonisolated static let copilotMonthlyWindowMinutes = 30 * 24 * 60
    private nonisolated static let planUtilizationUnscopedPreferredKey = "__unscoped__"
    private nonisolated static let claudeOAuthPlanUtilizationAccountKeyPrefix = "__claude_oauth__:"

    enum ClaudeOAuthActiveAccountObservation: Equatable, Sendable {
        case stable(identity: String?)
        case changed
    }

    struct ClaudeOAuthAccountBindingCandidate: Codable, Equatable {
        let identity: String
        let observedAt: Date
    }

    private struct ClaudeOAuthHistoryEvidence {
        let owner: String
        let persistentRefHash: String?
        let keychainCredentialMismatch: Bool
        let keychainCredentialAbsent: Bool
        let keychainCredentialUnavailable: Bool
        let activeAccountObservation: ClaudeOAuthActiveAccountObservation
        let observedAt: Date
    }

    struct LimitResetDetectorState: Codable, Equatable {
        let wasAboveThreshold: Bool
        let lastObservedAt: Date
        let sourceRawValue: String?
    }

    /// Whether the plan-utilization history menu/chart is surfaced for this
    /// provider. Codex and Claude always qualify; every other provider qualifies
    /// once it has accumulated history in the store, or as soon as its live snapshot
    /// can produce samples. This fork always records history, so the toggle does not
    /// gate surfacing here.
    func supportsPlanUtilizationHistory(for provider: UsageProvider) -> Bool {
        switch provider {
        case .codex, .claude:
            true
        default:
            if self.planUtilizationHistory[provider]?.isEmpty == false {
                true
            } else if let snapshot = self.snapshots[provider] {
                !self.planUtilizationSeriesSamples(
                    provider: provider,
                    snapshot: snapshot,
                    capturedAt: snapshot.updatedAt).isEmpty
            } else {
                false
            }
        }
    }

    private nonisolated static let planUtilizationResetEquivalenceToleranceSeconds: TimeInterval = 2 * 60
    private nonisolated static let planUtilizationMaxSamples: Int = 24 * 730

    private struct PlanUtilizationSeriesKey: Hashable {
        let name: PlanUtilizationSeriesName
        let windowMinutes: Int
    }

    private struct PlanUtilizationSeriesSample {
        let name: PlanUtilizationSeriesName
        let windowMinutes: Int
        let entry: PlanUtilizationHistoryEntry
    }

    private struct LimitResetDetectionContext {
        let provider: UsageProvider
        let account: ProviderTokenAccount?
        let snapshot: UsageSnapshot
        let accountKey: String?
        let capturedAt: Date
    }

    private struct LimitResetObservation {
        let usedPercent: Double
        let observedAt: Date
        let source: SessionQuotaWindowSource?
    }

    private struct LimitResetDetectionDescriptor {
        let seriesName: PlanUtilizationSeriesName
        let defaultsKey: String
        let resetKind: String
    }

    func planUtilizationHistory(for provider: UsageProvider) -> [PlanUtilizationSeriesHistory] {
        self.planUtilizationHistorySelection(for: provider).histories
    }

    func planUtilizationHistorySelection(for provider: UsageProvider)
        -> (accountKey: String?, histories: [PlanUtilizationSeriesHistory])
    {
        var providerBuckets = self.planUtilizationHistory[provider] ?? PlanUtilizationHistoryBuckets()
        if provider == .claude,
           providerBuckets.preferredAccountKey == Self.planUtilizationUnscopedPreferredKey
           || Self.isClaudeOAuthPlanUtilizationAccountKey(providerBuckets.preferredAccountKey)
        {
            // Persisted OAuth provenance outranks an unrelated configured token account. The unscoped
            // sentinel intentionally resolves to nil, including after the history store is reloaded.
            let accountKey = self.stickyPlanUtilizationAccountKey(providerBuckets: providerBuckets)
            return (accountKey, providerBuckets.histories(for: accountKey))
        }
        let originalProviderBuckets = providerBuckets
        let accountKey = self.resolvePlanUtilizationAccountKey(
            provider: provider,
            snapshot: self.snapshots[provider],
            preferredAccount: nil,
            providerBuckets: &providerBuckets)
        self.planUtilizationHistory[provider] = providerBuckets
        if providerBuckets != originalProviderBuckets {
            let snapshotToPersist = self.planUtilizationHistory
            Task {
                await self.planUtilizationPersistenceCoordinator.enqueue(snapshotToPersist)
            }
        }
        return (accountKey, providerBuckets.histories(for: accountKey))
    }

    func codexPlanUtilizationHistories(forVisibleAccount account: CodexVisibleAccount)
        -> [PlanUtilizationSeriesHistory]
    {
        var providerBuckets = self.planUtilizationHistory[.codex] ?? PlanUtilizationHistoryBuckets()
        let originalProviderBuckets = providerBuckets
        let ownership = self.codexOwnershipContext(forVisibleAccount: account)
        guard let canonicalKey = ownership.canonicalKey else { return [] }

        if ownership.hasAdjacentEmailScopeAmbiguity {
            guard canonicalKey != ownership.canonicalEmailHashKey else { return [] }
            return providerBuckets.histories(for: canonicalKey)
        }

        let accountKey = self.materializeCodexPlanUtilizationHistoryIfNeeded(
            into: canonicalKey,
            ownership: ownership,
            shouldAdoptUnscopedHistory: true,
            providerBuckets: &providerBuckets)
        self.planUtilizationHistory[.codex] = providerBuckets
        if providerBuckets != originalProviderBuckets {
            let snapshotToPersist = self.planUtilizationHistory
            Task {
                await self.planUtilizationPersistenceCoordinator.enqueue(snapshotToPersist)
            }
        }
        return providerBuckets.histories(for: accountKey)
    }

    func shouldShowRefreshingMenuCard(for provider: UsageProvider) -> Bool {
        let isRefreshing = self.isRefreshing || self.refreshingProviders.contains(provider)
        return isRefreshing
            && self.snapshots[provider] == nil
            && self.error(for: provider) == nil
    }

    func shouldShowRefreshingMenuCardIndicator(for provider: UsageProvider) -> Bool {
        let isRefreshing = self.isRefreshing || self.refreshingProviders.contains(provider)
        return isRefreshing && self.error(for: provider) == nil
    }

    func shouldHidePlanUtilizationMenuItem(for provider: UsageProvider) -> Bool {
        guard self.supportsPlanUtilizationHistory(for: provider) else { return true }
        return self.shouldShowRefreshingMenuCard(for: provider)
    }

    func recordPlanUtilizationHistorySample(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        account: ProviderTokenAccount? = nil,
        claudeOAuthPersistentRefHash: String? = nil,
        claudeOAuthHistoryOwnerIdentifier: String? = nil,
        claudeOAuthKeychainCredentialMismatch: Bool = false,
        claudeOAuthKeychainCredentialAbsent: Bool = false,
        claudeOAuthKeychainCredentialUnavailable: Bool = false,
        claudeOAuthActiveAccountObservation: ClaudeOAuthActiveAccountObservation = .stable(identity: nil),
        isClaudeOAuthSample: Bool = false,
        shouldUpdatePreferredAccountKey: Bool = true,
        shouldAdoptUnscopedHistory: Bool = true,
        now: Date = Date())
        async
    {
        let samples = self.planUtilizationSeriesSamples(provider: provider, snapshot: snapshot, capturedAt: now)
        var effectiveOwner = claudeOAuthHistoryOwnerIdentifier
        if provider == .claude, isClaudeOAuthSample, let owner = claudeOAuthHistoryOwnerIdentifier {
            effectiveOwner = self.resolvedClaudeOAuthHistoryOwner(evidence: ClaudeOAuthHistoryEvidence(
                owner: owner,
                persistentRefHash: claudeOAuthPersistentRefHash,
                keychainCredentialMismatch: claudeOAuthKeychainCredentialMismatch,
                keychainCredentialAbsent: claudeOAuthKeychainCredentialAbsent,
                keychainCredentialUnavailable: claudeOAuthKeychainCredentialUnavailable,
                activeAccountObservation: claudeOAuthActiveAccountObservation,
                observedAt: now))
        }
        let detectorAccountKey = if provider == .claude, isClaudeOAuthSample {
            Self.claudeOAuthPlanUtilizationAccountKey(
                historyOwnerIdentifier: effectiveOwner,
                corroboratingPersistentRefHash: claudeOAuthPersistentRefHash)
        } else {
            self.planUtilizationAccountKey(
                for: provider,
                snapshot: snapshot,
                preferredAccount: account)
        }
        if provider == .claude, isClaudeOAuthSample, detectorAccountKey == nil {
            // Persisting without a high-entropy owner would merge unrelated OAuth accounts into `unscoped`.
            return
        }
        let detectorContext = LimitResetDetectionContext(
            provider: provider,
            account: account,
            snapshot: snapshot,
            accountKey: detectorAccountKey,
            capturedAt: now)
        await MainActor.run {
            self.postLimitResetCelebrationsIfNeeded(
                context: detectorContext,
                samples: samples)
        }

        guard !samples.isEmpty else { return }
        guard self.shouldRecordPlanUtilizationHistory(for: provider) else { return }
        guard !self.shouldDeferClaudePlanUtilizationHistory(provider: provider) else { return }

        var snapshotToPersist: [UsageProvider: PlanUtilizationHistoryBuckets]?
        var telemetryAccountKey: String?
        await MainActor.run {
            var providerBuckets = self.planUtilizationHistory[provider] ?? PlanUtilizationHistoryBuckets()
            let originalProviderBuckets = providerBuckets
            let preferredAccount = account ?? self.settings.selectedTokenAccount(for: provider)
            let accountKey = self.resolvePlanUtilizationAccountKey(
                provider: provider,
                snapshot: snapshot,
                preferredAccount: preferredAccount,
                claudeOAuthPersistentRefHash: claudeOAuthPersistentRefHash,
                claudeOAuthHistoryOwnerIdentifier: effectiveOwner,
                isClaudeOAuthSample: isClaudeOAuthSample,
                shouldUpdatePreferredAccountKey: shouldUpdatePreferredAccountKey,
                shouldAdoptUnscopedHistory: shouldAdoptUnscopedHistory,
                providerBuckets: &providerBuckets)
            let histories = providerBuckets.histories(for: accountKey)

            if let updatedHistories = Self.updatedPlanUtilizationHistories(
                provider: provider,
                existingHistories: histories,
                samples: samples)
            {
                providerBuckets.setHistories(updatedHistories, for: accountKey)
            }

            let accountLabel = self.planUtilizationAccountLabel(
                provider: provider,
                snapshot: snapshot,
                account: preferredAccount,
                accountKey: accountKey)
            providerBuckets.setLabel(accountLabel, for: accountKey)

            guard providerBuckets != originalProviderBuckets else { return }
            self.planUtilizationHistory[provider] = providerBuckets
            self.planUtilizationHistoryRevision &+= 1
            snapshotToPersist = self.planUtilizationHistory
            telemetryAccountKey = accountKey
        }

        guard let snapshotToPersist else { return }
        await self.planUtilizationPersistenceCoordinator.enqueue(snapshotToPersist)

        // Mirror the freshly recorded samples to the self-hosted telemetry pipeline.
        // Self-contained in Sources/CodexBar/Telemetry/; no-ops when telemetry is off.
        await TelemetryService.shared.send(usageSamples: samples.map { sample in
            TelemetryUsageSample(
                provider: provider.rawValue,
                accountKey: telemetryAccountKey,
                series: sample.name.rawValue,
                windowMinutes: sample.windowMinutes,
                usedPercent: sample.entry.usedPercent,
                capturedAt: sample.entry.capturedAt,
                resetsAt: sample.entry.resetsAt)
        })
    }

    private func shouldRecordPlanUtilizationHistory(for _: UsageProvider) -> Bool {
        // This fork always records plan-utilization history for every provider, regardless of
        // the `historicalTrackingEnabled` toggle, so usage charts keep accumulating. The toggle
        // still governs its other consumers (e.g. Codex historical pace).
        true
    }

    private nonisolated static func updatedPlanUtilizationHistories(
        provider: UsageProvider,
        existingHistories: [PlanUtilizationSeriesHistory],
        samples: [PlanUtilizationSeriesSample]) -> [PlanUtilizationSeriesHistory]?
    {
        guard !samples.isEmpty else { return nil }

        // Rescue history stranded under an older series-naming scheme by folding it into
        // the current lane it continues, so renaming a provider's series never looks like
        // its accumulated records were deleted.
        let canonicalLanes = samples.map { sample in
            PlanUtilizationLegacySeriesMigration.CanonicalLane(
                name: sample.name,
                windowMinutes: sample.windowMinutes,
                usedPercent: sample.entry.usedPercent,
                resetsAt: sample.entry.resetsAt)
        }
        let (migratedHistories, didMigrate) = PlanUtilizationLegacySeriesMigration.migrate(
            provider: provider,
            histories: existingHistories,
            canonicalLanes: canonicalLanes)

        var historiesByKey: [PlanUtilizationSeriesKey: PlanUtilizationSeriesHistory] = [:]
        var didChange = didMigrate
        for history in migratedHistories {
            let canonicalWindowMinutes = history.name.canonicalWindowMinutes(history.windowMinutes)
            let key = PlanUtilizationSeriesKey(name: history.name, windowMinutes: canonicalWindowMinutes)
            let canonicalHistory = PlanUtilizationSeriesHistory(
                name: history.name,
                windowMinutes: canonicalWindowMinutes,
                entries: history.entries)
            if let existingHistory = historiesByKey[key] {
                historiesByKey[key] = PlanUtilizationSeriesHistory(
                    name: history.name,
                    windowMinutes: canonicalWindowMinutes,
                    entries: self.mergedPlanUtilizationEntries(existingHistory.entries + canonicalHistory.entries))
                didChange = true
            } else {
                historiesByKey[key] = canonicalHistory
                didChange = didChange || canonicalWindowMinutes != history.windowMinutes
            }
        }

        for sample in samples {
            let canonicalWindowMinutes = sample.name.canonicalWindowMinutes(sample.windowMinutes)
            let key = PlanUtilizationSeriesKey(name: sample.name, windowMinutes: canonicalWindowMinutes)
            if let existingHistory = historiesByKey[key] {
                guard let updatedEntries = self.updatedPlanUtilizationEntries(
                    existingEntries: existingHistory.entries,
                    entry: sample.entry)
                else {
                    continue
                }
                historiesByKey[key] = PlanUtilizationSeriesHistory(
                    name: sample.name,
                    windowMinutes: canonicalWindowMinutes,
                    entries: updatedEntries)
            } else {
                historiesByKey[key] = PlanUtilizationSeriesHistory(
                    name: sample.name,
                    windowMinutes: canonicalWindowMinutes,
                    entries: [sample.entry])
            }
            didChange = true
        }

        guard didChange else { return nil }
        return historiesByKey.values.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    private nonisolated static func mergedPlanUtilizationEntries(
        _ entries: [PlanUtilizationHistoryEntry]) -> [PlanUtilizationHistoryEntry]
    {
        entries.reduce(into: []) { result, entry in
            guard !result.contains(entry) else { return }
            result.append(entry)
        }
    }

    private nonisolated static func updatedPlanUtilizationEntries(
        existingEntries: [PlanUtilizationHistoryEntry],
        entry: PlanUtilizationHistoryEntry) -> [PlanUtilizationHistoryEntry]?
    {
        var entries = existingEntries
        let insertionIndex = entries.firstIndex(where: { $0.capturedAt > entry.capturedAt }) ?? entries.endIndex

        // Keep every refresh: record each observation as its own point, even when the
        // usage value is unchanged, so the series accumulates continuously over time.
        // The only thing dropped is an exact duplicate (identical timestamp, usage, and
        // reset boundary), which guards against recording the very same sample twice.
        guard !entries.contains(entry) else { return nil }

        entries.insert(entry, at: insertionIndex)

        if entries.count > self.planUtilizationMaxSamples {
            entries.removeFirst(entries.count - self.planUtilizationMaxSamples)
        }
        return entries
    }

    #if DEBUG
    nonisolated static func _updatedPlanUtilizationEntriesForTesting(
        existingEntries: [PlanUtilizationHistoryEntry],
        entry: PlanUtilizationHistoryEntry) -> [PlanUtilizationHistoryEntry]?
    {
        self.updatedPlanUtilizationEntries(existingEntries: existingEntries, entry: entry)
    }

    nonisolated static func _updatedPlanUtilizationHistoriesForTesting(
        existingHistories: [PlanUtilizationSeriesHistory],
        samples: [PlanUtilizationSeriesHistory],
        provider: UsageProvider = .codex) -> [PlanUtilizationSeriesHistory]?
    {
        let normalized = samples.flatMap { history in
            history.entries.map { entry in
                PlanUtilizationSeriesSample(name: history.name, windowMinutes: history.windowMinutes, entry: entry)
            }
        }
        return self.updatedPlanUtilizationHistories(
            provider: provider,
            existingHistories: existingHistories,
            samples: normalized)
    }

    nonisolated static var _planUtilizationMaxSamplesForTesting: Int {
        self.planUtilizationMaxSamples
    }
    #endif

    private nonisolated static func clampedPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return max(0, min(100, value))
    }

    /// The sample used to detect a weekly-limit reset. Prefers the canonical
    /// `.weekly` series; for providers that record weekly usage under semantic
    /// per-pool names (e.g. Antigravity's `gemini-weekly`), falls back to the
    /// highest-used sample whose canonical window is weekly.
    private nonisolated static func representativeWeeklySample(
        _ samples: [PlanUtilizationSeriesSample]) -> PlanUtilizationSeriesSample?
    {
        if let exact = samples.last(where: { $0.name == .weekly }) {
            return exact
        }
        return samples
            .filter { $0.name.canonicalWindowMinutes($0.windowMinutes) == Self.weeklyWindowMinutes }
            .max(by: { $0.entry.usedPercent < $1.entry.usedPercent })
    }

    private func postLimitResetCelebrationsIfNeeded(
        context: LimitResetDetectionContext,
        samples: [PlanUtilizationSeriesSample])
    {
        let shouldIgnoreCommandCode = context.provider == .commandcode
            && context.snapshot.commandCodeSubscriptionEnrichmentUnavailable
        let sessionObservation: LimitResetObservation? = if shouldIgnoreCommandCode {
            nil
        } else if context.provider == .codex {
            samples.last(where: { $0.name == .session }).map {
                LimitResetObservation(
                    usedPercent: $0.entry.usedPercent,
                    observedAt: $0.entry.capturedAt,
                    source: nil)
            }
        } else {
            self.sessionQuotaWindow(provider: context.provider, snapshot: context.snapshot).flatMap { resolved in
                guard Self.isSemanticSessionResetWindow(resolved) else { return nil }
                return Self.clampedPercent(resolved.window.usedPercent).map {
                    LimitResetObservation(
                        usedPercent: $0,
                        observedAt: context.capturedAt,
                        source: resolved.source)
                }
            }
        }
        self.postLimitResetCelebrationIfNeeded(
            states: &self.sessionLimitResetDetectorStates,
            context: context,
            descriptor: LimitResetDetectionDescriptor(
                seriesName: .session,
                defaultsKey: Self.sessionLimitResetDetectorDefaultsKey,
                resetKind: "session"),
            observation: sessionObservation)
        let weeklyObservation = Self.representativeWeeklySample(samples).map {
            LimitResetObservation(
                usedPercent: $0.entry.usedPercent,
                observedAt: $0.entry.capturedAt,
                source: nil)
        }
        self.postLimitResetCelebrationIfNeeded(
            states: &self.weeklyLimitResetDetectorStates,
            context: context,
            descriptor: LimitResetDetectionDescriptor(
                seriesName: .weekly,
                defaultsKey: Self.weeklyLimitResetDetectorDefaultsKey,
                resetKind: "weekly"),
            observation: weeklyObservation)
    }

    private static func isSemanticSessionResetWindow(
        _ resolved: (window: RateWindow, source: SessionQuotaWindowSource)) -> Bool
    {
        switch resolved.source {
        case .primary:
            guard let minutes = resolved.window.windowMinutes else { return false }
            return minutes > 0 && minutes <= 6 * 60
        case .copilotSecondaryFallback, .zaiTertiary, .antigravityQuotaSummary, .antigravityLegacy:
            return true
        }
    }

    private func postLimitResetCelebrationIfNeeded(
        states: inout [String: LimitResetDetectorState],
        context: LimitResetDetectionContext,
        descriptor: LimitResetDetectionDescriptor,
        observation: LimitResetObservation?)
    {
        guard let observation else { return }

        let accountIdentifier = self.limitResetAccountIdentifier(
            provider: context.provider,
            account: context.account,
            snapshot: context.snapshot,
            accountKey: context.accountKey)
        let detectorKey = Self.limitResetDetectorStateKey(
            provider: context.provider,
            accountIdentifier: accountIdentifier)
        let currentUsed = observation.usedPercent
        let currentObservedAt = observation.observedAt
        let wasAboveThreshold = currentUsed > Self.limitResetThreshold
        if let existingState = states[detectorKey],
           currentObservedAt <= existingState.lastObservedAt
        {
            return
        }

        let previousState = states[detectorKey]
        let sourceRawValue = observation.source?.rawValue
        let sourceChanged = descriptor.seriesName == .session
            && previousState?.sourceRawValue != nil
            && previousState?.sourceRawValue != sourceRawValue
        let shouldPost = !sourceChanged
            && previousState?.wasAboveThreshold == true
            && !wasAboveThreshold
        states[detectorKey] = LimitResetDetectorState(
            wasAboveThreshold: wasAboveThreshold,
            lastObservedAt: currentObservedAt,
            sourceRawValue: sourceRawValue)
        self.persistLimitResetDetectorStates(
            states,
            defaultsKey: descriptor.defaultsKey,
            logName: descriptor.resetKind)

        guard shouldPost else { return }
        let accountLabel = self.limitResetAccountLabel(
            provider: context.provider,
            account: context.account,
            snapshot: context.snapshot)

        CodexBarLog.logger(LogCategories.confetti).info(
            "\(descriptor.resetKind.capitalized) limit reset",
            metadata: [
                "provider": context.provider.rawValue,
                "accountIdentifier": accountIdentifier,
                "accountLabel": accountLabel ?? "",
                "resetKind": descriptor.resetKind,
                "usedPercent": String(format: "%.2f", currentUsed),
                "observedAt": String(format: "%.0f", currentObservedAt.timeIntervalSince1970),
            ])
        switch descriptor.seriesName {
        case .session:
            let event = SessionLimitResetEvent(
                provider: context.provider,
                accountIdentifier: accountIdentifier,
                accountLabel: accountLabel,
                usedPercent: currentUsed)
            NotificationCenter.default.post(name: .codexbarSessionLimitReset, object: event)
        case .weekly:
            let event = WeeklyLimitResetEvent(
                provider: context.provider,
                accountIdentifier: accountIdentifier,
                accountLabel: accountLabel,
                usedPercent: currentUsed)
            NotificationCenter.default.post(name: .codexbarWeeklyLimitReset, object: event)
        default:
            return
        }
    }

    private func planUtilizationSeriesSamples(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        capturedAt: Date) -> [PlanUtilizationSeriesSample]
    {
        var samplesByKey: [PlanUtilizationSeriesKey: PlanUtilizationSeriesSample] = [:]

        func appendWindow(
            _ window: RateWindow?,
            name: PlanUtilizationSeriesName?,
            windowMinutesOverride: Int? = nil)
        {
            guard let name,
                  let window,
                  let windowMinutes = windowMinutesOverride ?? window.windowMinutes,
                  windowMinutes > 0,
                  let usedPercent = Self.clampedPercent(window.usedPercent)
            else {
                return
            }

            let canonicalWindowMinutes = name.canonicalWindowMinutes(windowMinutes)
            let key = PlanUtilizationSeriesKey(name: name, windowMinutes: canonicalWindowMinutes)
            samplesByKey[key] = PlanUtilizationSeriesSample(
                name: name,
                windowMinutes: canonicalWindowMinutes,
                entry: PlanUtilizationHistoryEntry(
                    capturedAt: capturedAt,
                    usedPercent: usedPercent,
                    resetsAt: window.resetsAt))
        }

        switch provider {
        case .codex:
            let projection = self.codexConsumerProjection(
                surface: .liveCard,
                snapshotOverride: snapshot,
                now: capturedAt)
            for lane in projection.planUtilizationLanes {
                appendWindow(lane.window, name: lane.role)
            }
        case .claude:
            appendWindow(snapshot.primary, name: .session)
            appendWindow(snapshot.secondary, name: .weekly)
            appendWindow(snapshot.tertiary, name: .opus)
        case .cursor:
            // All three lanes share the billing-cycle duration, so the generic
            // window-duration name would collapse them into one series. Name them by
            // lane instead so total/auto/api each persist as their own series.
            appendWindow(snapshot.primary, name: "total")
            appendWindow(snapshot.secondary, name: "auto")
            appendWindow(snapshot.tertiary, name: "api")
        case .copilot:
            // Copilot's premium-interaction and chat quotas (plus any configured budgets) reset
            // monthly but report no window duration, so the generic path — which requires a window
            // length — skips them and nothing reaches history. Stamp the shared monthly window and
            // record the two core lanes by role (Premium → session, Chat → weekly) so both persist
            // as distinct series; record each named budget under its own slug.
            appendWindow(snapshot.primary, name: .session, windowMinutesOverride: Self.copilotMonthlyWindowMinutes)
            appendWindow(snapshot.secondary, name: .weekly, windowMinutesOverride: Self.copilotMonthlyWindowMinutes)
            for extra in snapshot.extraRateWindows ?? [] where extra.usageKnown {
                appendWindow(
                    extra.window,
                    name: Self.copilotSeriesName(for: extra),
                    windowMinutesOverride: Self.copilotMonthlyWindowMinutes)
            }
        case .antigravity:
            // Record one series per named quota pool (Gemini / Claude+GPT × Session /
            // Weekly) so every bucket reaches history instead of collapsing into a single
            // weekly point. Fall back to the representative weekly lanes when no named
            // pools are present.
            let namedWindows = snapshot.extraRateWindows?.filter {
                $0.usageKnown && $0.id.hasPrefix("antigravity-quota-summary-")
            } ?? []
            if namedWindows.isEmpty {
                for window in [snapshot.primary, snapshot.secondary, snapshot.tertiary] {
                    guard let window, window.windowMinutes == Self.weeklyWindowMinutes else { continue }
                    appendWindow(window, name: .weekly)
                }
            } else {
                for namedWindow in namedWindows {
                    appendWindow(namedWindow.window, name: Self.antigravitySeriesName(for: namedWindow))
                }
            }
        default:
            let standardWeeklyWindow = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
                .compactMap(\.self)
                .first { $0.windowMinutes == Self.weeklyWindowMinutes }
            let extraWeeklyWindow = snapshot.extraRateWindows?
                .lazy
                .first { $0.usageKnown && $0.window.windowMinutes == Self.weeklyWindowMinutes }?
                .window
            if let weeklyWindow = standardWeeklyWindow ?? extraWeeklyWindow {
                appendWindow(weeklyWindow, name: .weekly)
            }
        }

        return samplesByKey.values.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    /// Stable, human-readable series name for an Antigravity named quota window,
    /// derived from its title (e.g. "Gemini Weekly" → `gemini-weekly`).
    private nonisolated static func antigravitySeriesName(
        for namedWindow: NamedRateWindow) -> PlanUtilizationSeriesName
    {
        let slug = self.seriesSlug(namedWindow.title)
        return PlanUtilizationSeriesName(rawValue: slug.isEmpty ? namedWindow.id : slug)
    }

    /// Stable, human-readable series name for a Copilot named budget window, derived
    /// from its title (e.g. "Premium requests" → `premium-requests`). Falls back to the
    /// window id when the title has no alphanumeric characters to slug.
    private nonisolated static func copilotSeriesName(
        for namedWindow: NamedRateWindow) -> PlanUtilizationSeriesName
    {
        let slug = self.seriesSlug(namedWindow.title)
        return PlanUtilizationSeriesName(rawValue: slug.isEmpty ? namedWindow.id : slug)
    }

    /// Lowercases `raw` and collapses every run of non-alphanumeric characters into
    /// a single dash, trimming leading/trailing dashes.
    private nonisolated static func seriesSlug(_ raw: String) -> String {
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

    private func planUtilizationAccountKey(
        for provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        preferredAccount: ProviderTokenAccount? = nil) -> String?
    {
        let account = preferredAccount ?? self.settings.selectedTokenAccount(for: provider)
        let accountKey = Self.planUtilizationAccountKey(provider: provider, account: account)
        if let accountKey {
            return accountKey
        }
        let resolvedSnapshot = snapshot ?? self.snapshots[provider]
        return resolvedSnapshot.flatMap { Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: $0) }
    }

    private nonisolated static func planUtilizationAccountKey(
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> String?
    {
        guard let account else { return nil }
        return self.sha256Hex("\(provider.rawValue):token-account:\(account.id.uuidString.lowercased())")
    }

    /// The Keychain row reference is corroborating provenance, not principal identity. Excluding it from the
    /// canonical key keeps one credential stable when its row is recreated, while requiring the credential
    /// discriminator ensures an in-place login replacement cannot inherit the prior principal's history.
    private nonisolated static func claudeOAuthPlanUtilizationAccountKey(
        historyOwnerIdentifier: String?,
        corroboratingPersistentRefHash _: String? = nil) -> String?
    {
        guard let normalizedIdentifier = historyOwnerIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            normalizedIdentifier.count == 64,
            normalizedIdentifier.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        let digest = self.sha256Hex("claude:oauth-history-owner:v2:\(normalizedIdentifier)")
        return "\(self.claudeOAuthPlanUtilizationAccountKeyPrefix)\(digest)"
    }

    private nonisolated static func isClaudeOAuthPlanUtilizationAccountKey(_ accountKey: String?) -> Bool {
        accountKey?.hasPrefix(self.claudeOAuthPlanUtilizationAccountKeyPrefix) == true
    }

    private nonisolated static func planUtilizationIdentityAccountKey(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> String?
    {
        guard let identity = snapshot.identity(for: provider) else { return nil }

        let normalizedEmail = identity.accountEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedEmail, !normalizedEmail.isEmpty {
            if provider == .codex {
                return CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)
            }
            if provider == .claude {
                let normalizedOrganization = identity.accountOrganization?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let normalizedLoginMethod = identity.loginMethod?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let normalizedPlan = ClaudePlan.fromCompatibilityLoginMethod(identity.loginMethod)?.rawValue
                let organizationDiscriminator: String? =
                    if let normalizedOrganization, !normalizedOrganization.isEmpty {
                        "org:\(normalizedOrganization)"
                    } else {
                        nil
                    }
                let planDiscriminator = normalizedPlan.map { "plan:\($0)" }
                let loginMethodDiscriminator: String? =
                    if let normalizedLoginMethod, !normalizedLoginMethod.isEmpty {
                        "plan:\(normalizedLoginMethod)"
                    } else {
                        nil
                    }
                let discriminator = organizationDiscriminator ?? planDiscriminator ?? loginMethodDiscriminator
                guard let discriminator else {
                    return self.sha256Hex("claude:email:\(normalizedEmail)")
                }
                return self.sha256Hex("\(provider.rawValue):email:\(normalizedEmail):\(discriminator)")
            }
            return self.sha256Hex("\(provider.rawValue):email:\(normalizedEmail)")
        }

        if provider == .claude {
            return nil
        }

        let normalizedOrganization = identity.accountOrganization?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedOrganization, !normalizedOrganization.isEmpty {
            return self.sha256Hex("\(provider.rawValue):organization:\(normalizedOrganization)")
        }

        return nil
    }

    private nonisolated static func legacyClaudePlanUtilizationEmailAccountKey(snapshot: UsageSnapshot) -> String? {
        guard let identity = snapshot.identity(for: .claude) else { return nil }
        let normalizedEmail = identity.accountEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedEmail, !normalizedEmail.isEmpty else { return nil }
        return self.sha256Hex("claude:email:\(normalizedEmail)")
    }

    private func shouldDeferClaudePlanUtilizationHistory(provider: UsageProvider) -> Bool {
        provider == .claude && self.shouldHidePlanUtilizationMenuItem(for: .claude)
    }

    private func limitResetAccountIdentifier(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot,
        accountKey: String?) -> String
    {
        let identity = snapshot.identity(for: provider)
        return account?.id.uuidString.lowercased()
            ?? accountKey
            ?? identity?.accountEmail
            ?? identity?.accountOrganization
            ?? provider.rawValue
    }

    private func limitResetAccountLabel(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot) -> String?
    {
        let identity = snapshot.identity(for: provider)
        return account?.label
            ?? identity?.accountEmail
            ?? identity?.accountOrganization
    }

    /// Human-readable name persisted alongside an account's history so each
    /// account can be identified in the history folder. Prefers the account
    /// email/login, falls back to the displayName, then the opaque account key.
    private func planUtilizationAccountLabel(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        account: ProviderTokenAccount?,
        accountKey: String?) -> String?
    {
        func cleaned(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }

        let identity = snapshot.identity(for: provider)
        // Prefer a login identity (email / login / organization)…
        if let email = cleaned(identity?.accountEmail) { return email }
        if let login = cleaned(account?.externalIdentifier) { return login }
        if let organization = cleaned(identity?.accountOrganization) { return organization }
        // …then the user-facing display name…
        if let displayName = cleaned(account?.displayName) { return displayName }
        // …and finally the opaque account key so the bucket is still labelled.
        return cleaned(accountKey)
    }

    private nonisolated static func limitResetDetectorStateKey(
        provider: UsageProvider,
        accountIdentifier: String) -> String
    {
        "\(provider.rawValue):\(accountIdentifier)"
    }

    nonisolated static func loadWeeklyLimitResetDetectorStates(from userDefaults: UserDefaults)
        -> [String: LimitResetDetectorState]
    {
        self.loadLimitResetDetectorStates(
            from: userDefaults,
            defaultsKey: self.weeklyLimitResetDetectorDefaultsKey,
            logName: "weekly")
    }

    nonisolated static func loadLimitResetDetectorStates(
        from userDefaults: UserDefaults,
        defaultsKey: String,
        logName: String) -> [String: LimitResetDetectorState]
    {
        guard let data = userDefaults.data(forKey: defaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: LimitResetDetectorState].self, from: data)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to decode \(logName) limit reset detector state",
                metadata: ["error": String(describing: error)])
            return [:]
        }
    }

    private func persistLimitResetDetectorStates(
        _ states: [String: LimitResetDetectorState],
        defaultsKey: String,
        logName: String)
    {
        do {
            let data = try JSONEncoder().encode(states)
            self.settings.userDefaults.set(data, forKey: defaultsKey)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to encode \(logName) limit reset detector state",
                metadata: ["error": String(describing: error)])
        }
    }

    // MARK: - Active Claude account corroboration (~/.claude.json)

    /// The currently-active Claude account UUID, read prompt-free from `~/.claude.json`. This is the only
    /// always-fresh, never-gated signal of the active account on a background poll: Claude Code's `/login`
    /// updates the Keychain item in place and leaves `~/.claude/.credentials.json` stale, but immediately
    /// rewrites `oauthAccount.accountUuid` in this sibling plain file. Returns nil on absence/corruption.
    nonisolated static func activeClaudeAccountUuid() -> String? {
        ClaudeActiveAccountProbe.activeClaudeAccountUuid()
    }

    /// Persisted `historyOwnerIdentifier -> hashed active account identity` bindings.
    nonisolated static func loadClaudeOAuthAccountUuidMap(from userDefaults: UserDefaults) -> [String: String] {
        guard let data = userDefaults.data(forKey: claudeOAuthAccountUuidMapDefaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to decode Claude OAuth history owner account UUID map",
                metadata: ["error": String(describing: error)])
            return [:]
        }
    }

    /// Persist the `historyOwnerIdentifier -> active accountUuid` map. Mirrors `persistLimitResetDetectorStates`.
    func persistClaudeOAuthAccountUuidMap(_ map: [String: String]) {
        do {
            let data = try JSONEncoder().encode(map)
            self.settings.userDefaults.set(data, forKey: Self.claudeOAuthAccountUuidMapDefaultsKey)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to encode Claude OAuth history owner account UUID map",
                metadata: ["error": String(describing: error)])
        }
    }

    nonisolated static func loadClaudeOAuthAccountBindingCandidateMap(
        from userDefaults: UserDefaults) -> [String: ClaudeOAuthAccountBindingCandidate]
    {
        guard let data = userDefaults.data(forKey: claudeOAuthAccountCandidateMapDefaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: ClaudeOAuthAccountBindingCandidate].self, from: data)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to decode Claude OAuth account binding candidates",
                metadata: ["error": String(describing: error)])
            return [:]
        }
    }

    private func confirmClaudeOAuthAccountBindingCandidate(
        owner: String,
        identity: String,
        observedAt: Date) -> Bool
    {
        var candidates = Self.loadClaudeOAuthAccountBindingCandidateMap(from: self.settings.userDefaults)
        if let candidate = candidates[owner],
           candidate.identity == identity,
           candidate.observedAt < observedAt
        {
            candidates.removeValue(forKey: owner)
            self.persistClaudeOAuthAccountBindingCandidateMap(candidates)
            return true
        }
        candidates[owner] = ClaudeOAuthAccountBindingCandidate(identity: identity, observedAt: observedAt)
        self.persistClaudeOAuthAccountBindingCandidateMap(candidates)
        return false
    }

    private func resolvedClaudeOAuthHistoryOwner(evidence: ClaudeOAuthHistoryEvidence) -> String? {
        let requiresClaudeCodeCorroboration = evidence.persistentRefHash != nil
            || evidence.keychainCredentialMismatch
            || evidence.keychainCredentialAbsent
            || evidence.keychainCredentialUnavailable
        guard requiresClaudeCodeCorroboration else {
            // Explicit/environment credentials do not belong to Claude Code's active-account lifecycle.
            return evidence.owner
        }
        guard case let .stable(currentAccountIdentity) = evidence.activeAccountObservation else {
            // An account/credential change while capturing the UUID cannot safely identify this sample.
            return nil
        }
        var map = Self.loadClaudeOAuthAccountUuidMap(from: self.settings.userDefaults)
        if let mapped = map[evidence.owner] {
            guard let currentAccountIdentity else {
                return evidence.keychainCredentialMismatch || evidence.keychainCredentialUnavailable
                    ? nil
                    : evidence.owner
            }
            guard mapped != currentAccountIdentity else {
                self.clearClaudeOAuthAccountBindingCandidate(owner: evidence.owner)
                return evidence.owner
            }
            guard evidence.persistentRefHash != nil,
                  self.confirmClaudeOAuthAccountBindingCandidate(
                      owner: evidence.owner,
                      identity: currentAccountIdentity,
                      observedAt: evidence.observedAt)
            else {
                return nil
            }
            // Two stable exact-Keychain observations repair a binding poisoned by a non-atomic login.
            map[evidence.owner] = currentAccountIdentity
            self.persistClaudeOAuthAccountUuidMap(map)
            return evidence.owner
        }

        if evidence.keychainCredentialUnavailable,
           !evidence.keychainCredentialMismatch
        {
            // With no authoritative binding, the secret-derived file owner is the only safe bootstrap scope.
            // Existing bindings are checked above, so normal background gating cannot bypass a detected switch.
            return evidence.owner
        }
        if evidence.keychainCredentialAbsent {
            // A proven-empty Keychain leaves the file credential as the only owner. Existing bindings were
            // checked above, so an unbound owner is safe without inventing account continuity.
            return evidence.owner
        }

        guard let currentAccountIdentity else {
            return evidence.keychainCredentialMismatch || evidence.keychainCredentialUnavailable
                ? nil
                : evidence.owner
        }
        guard evidence.persistentRefHash != nil else { return nil }
        // Two stable exact-Keychain observations are required before a first binding becomes authoritative.
        if self.confirmClaudeOAuthAccountBindingCandidate(
            owner: evidence.owner,
            identity: currentAccountIdentity,
            observedAt: evidence.observedAt)
        {
            map[evidence.owner] = currentAccountIdentity
            self.persistClaudeOAuthAccountUuidMap(map)
        }
        return evidence.owner
    }

    private func clearClaudeOAuthAccountBindingCandidate(owner: String) {
        var candidates = Self.loadClaudeOAuthAccountBindingCandidateMap(from: self.settings.userDefaults)
        guard candidates.removeValue(forKey: owner) != nil else { return }
        self.persistClaudeOAuthAccountBindingCandidateMap(candidates)
    }

    private func persistClaudeOAuthAccountBindingCandidateMap(
        _ candidates: [String: ClaudeOAuthAccountBindingCandidate])
    {
        do {
            let data = try JSONEncoder().encode(candidates)
            self.settings.userDefaults.set(data, forKey: Self.claudeOAuthAccountCandidateMapDefaultsKey)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to encode Claude OAuth account binding candidates",
                metadata: ["error": String(describing: error)])
        }
    }

    nonisolated static func activeClaudeAccountIdentity() -> String? {
        self.activeClaudeAccountUuid().map(self.claudeAccountIdentity)
    }

    private nonisolated static func claudeAccountIdentity(_ uuid: String) -> String {
        self.sha256Hex(
            "claude:active-account:v1:\(uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())")
    }

    #if DEBUG
    static func withActiveClaudeAccountUuidForTesting<T>(
        _ uuid: String?,
        _ body: () async throws -> T) async rethrows -> T
    {
        try await ClaudeActiveAccountProbe.$activeClaudeAccountUuidOverrideForTesting.withValue(
            .value(uuid),
            operation: body)
    }

    nonisolated static func _activeClaudeAccountIdentityForTesting(_ uuid: String) -> String {
        self.claudeAccountIdentity(uuid)
    }
    #endif

    private func resolvePlanUtilizationAccountKey(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        preferredAccount: ProviderTokenAccount?,
        claudeOAuthPersistentRefHash: String? = nil,
        claudeOAuthHistoryOwnerIdentifier: String? = nil,
        isClaudeOAuthSample: Bool = false,
        shouldUpdatePreferredAccountKey: Bool = true,
        shouldAdoptUnscopedHistory: Bool = true,
        providerBuckets: inout PlanUtilizationHistoryBuckets) -> String?
    {
        if provider == .codex {
            return self.resolveCodexPlanUtilizationAccountKey(
                snapshot: snapshot,
                shouldUpdatePreferredAccountKey: shouldUpdatePreferredAccountKey,
                shouldAdoptUnscopedHistory: shouldAdoptUnscopedHistory,
                providerBuckets: &providerBuckets)
        }

        // Claude's unscoped history is only safe to adopt during the first unambiguous migration.
        // The sentinel marks identityless OAuth, while any scoped bucket proves multiple owners may exist.
        let canAdoptUnscopedHistory = shouldAdoptUnscopedHistory
            && !(provider == .claude
                && (providerBuckets.preferredAccountKey == Self.planUtilizationUnscopedPreferredKey
                    || !providerBuckets.accounts.isEmpty))

        if provider == .claude, isClaudeOAuthSample {
            if let oauthAccountKey = Self.claudeOAuthPlanUtilizationAccountKey(
                historyOwnerIdentifier: claudeOAuthHistoryOwnerIdentifier,
                corroboratingPersistentRefHash: claudeOAuthPersistentRefHash)
            {
                if shouldUpdatePreferredAccountKey {
                    providerBuckets.preferredAccountKey = oauthAccountKey
                }
                // Existing unscoped or identity-keyed history can belong to another OAuth account.
                // Preserve it in place rather than silently adopting it into this opaque account.
                return oauthAccountKey
            }
            // Never append identityless OAuth samples to the shared unscoped bucket. A future fetch with
            // trustworthy ownership evidence can start a scoped history without inheriting this sample.
            return nil
        }

        let resolvedAccount = preferredAccount ?? self.settings.selectedTokenAccount(for: provider)
        if let tokenAccountKey = Self.planUtilizationAccountKey(provider: provider, account: resolvedAccount) {
            if shouldUpdatePreferredAccountKey {
                providerBuckets.preferredAccountKey = tokenAccountKey
            }
            if canAdoptUnscopedHistory {
                self.adoptPlanUtilizationUnscopedHistoryIfNeeded(
                    into: tokenAccountKey,
                    provider: provider,
                    providerBuckets: &providerBuckets)
            }
            return tokenAccountKey
        }

        if let snapshot,
           let identityAccountKey = Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: snapshot)
        {
            let resolvedIdentityAccountKey = self.materializeLegacyClaudePlanUtilizationHistoryIfNeeded(
                into: identityAccountKey,
                provider: provider,
                snapshot: snapshot,
                providerBuckets: &providerBuckets)
            if shouldUpdatePreferredAccountKey {
                providerBuckets.preferredAccountKey = resolvedIdentityAccountKey
            }
            if canAdoptUnscopedHistory {
                self.adoptPlanUtilizationUnscopedHistoryIfNeeded(
                    into: resolvedIdentityAccountKey,
                    provider: provider,
                    providerBuckets: &providerBuckets)
            }
            return resolvedIdentityAccountKey
        }

        if let stickyAccountKey = self.stickyPlanUtilizationAccountKey(providerBuckets: providerBuckets) {
            return stickyAccountKey
        }

        return nil
    }

    private func resolveCodexPlanUtilizationAccountKey(
        snapshot: UsageSnapshot?,
        shouldUpdatePreferredAccountKey: Bool,
        shouldAdoptUnscopedHistory: Bool,
        providerBuckets: inout PlanUtilizationHistoryBuckets) -> String?
    {
        let ownership = self.codexOwnershipContext(snapshot: snapshot, includeDashboardFallback: true)
        if let canonicalKey = ownership.canonicalKey {
            let resolvedAccountKey = self.materializeCodexPlanUtilizationHistoryIfNeeded(
                into: canonicalKey,
                ownership: ownership,
                shouldAdoptUnscopedHistory: shouldAdoptUnscopedHistory,
                providerBuckets: &providerBuckets)
            if shouldUpdatePreferredAccountKey {
                providerBuckets.preferredAccountKey = resolvedAccountKey
            }
            return resolvedAccountKey
        }

        if let stickyAccountKey = self.stickyPlanUtilizationAccountKey(providerBuckets: providerBuckets) {
            return stickyAccountKey
        }

        return nil
    }

    private func materializeCodexPlanUtilizationHistoryIfNeeded(
        into canonicalKey: String,
        ownership: CodexOwnershipContext,
        shouldAdoptUnscopedHistory: Bool,
        providerBuckets: inout PlanUtilizationHistoryBuckets) -> String
    {
        var historiesToMerge: [[PlanUtilizationSeriesHistory]] = []
        let scopedRawKeys = Array(providerBuckets.accounts.keys)
        var legacyRawKeysToRemove: [String] = []

        for rawKey in scopedRawKeys {
            let owner = CodexHistoryOwnership.classifyPersistedKey(
                rawKey,
                legacyEmailHash: ownership.planUtilizationLegacyEmailHash)
            let matchesTargetContinuity = CodexHistoryOwnership.belongsToTargetContinuity(
                owner,
                targetCanonicalKey: canonicalKey,
                canonicalEmailHashKey: ownership.canonicalEmailHashKey)
            if matchesTargetContinuity,
               !Self.codexPlanHistoryOwnerIsAmbiguousEmailScope(owner, ownership: ownership),
               let accountHistories = providerBuckets.accounts[rawKey],
               !accountHistories.isEmpty
            {
                historiesToMerge.append(accountHistories)
                if rawKey != canonicalKey {
                    legacyRawKeysToRemove.append(rawKey)
                }
            }
        }

        if let recoverableOpaqueRawKey = self.recoverableCodexOpaquePlanHistoryRawKey(
            targetCanonicalKey: canonicalKey,
            ownership: ownership,
            providerBuckets: providerBuckets),
            let opaqueHistories = providerBuckets.accounts[recoverableOpaqueRawKey],
            !opaqueHistories.isEmpty
        {
            historiesToMerge.append(opaqueHistories)
            legacyRawKeysToRemove.append(recoverableOpaqueRawKey)
        }

        if shouldAdoptUnscopedHistory,
           !providerBuckets.unscoped.isEmpty,
           CodexHistoryOwnership.hasStrictSingleAccountContinuity(
               scopedRawKeys: Self.scopedRawKeysRelevantToCodexUnscopedPlanHistory(providerBuckets),
               targetCanonicalKey: canonicalKey,
               canonicalEmailHashKey: ownership.canonicalEmailHashKey,
               legacyEmailHash: ownership.planUtilizationLegacyEmailHash,
               hasAdjacentMultiAccountVeto: ownership.hasAdjacentMultiAccountVeto)
        {
            historiesToMerge.append(providerBuckets.unscoped)
            providerBuckets.unscoped = []
        }

        guard !historiesToMerge.isEmpty else { return canonicalKey }
        for rawKey in legacyRawKeysToRemove {
            providerBuckets.accounts.removeValue(forKey: rawKey)
        }
        let mergedHistory = Self.mergedPlanUtilizationHistories(provider: .codex, histories: historiesToMerge)
        providerBuckets.setHistories(mergedHistory, for: canonicalKey)
        return canonicalKey
    }

    private static func codexPlanHistoryOwnerIsAmbiguousEmailScope(
        _ owner: CodexHistoryPersistedOwner,
        ownership: CodexOwnershipContext) -> Bool
    {
        guard ownership.hasAdjacentEmailScopeAmbiguity else { return false }
        return switch owner {
        case let .canonical(key):
            key == ownership.canonicalEmailHashKey
        case .legacyEmailHash:
            true
        case .legacyOpaqueScoped, .legacyUnscoped:
            false
        }
    }

    private func materializeLegacyClaudePlanUtilizationHistoryIfNeeded(
        into accountKey: String,
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        providerBuckets: inout PlanUtilizationHistoryBuckets) -> String
    {
        guard provider == .claude,
              let legacyAccountKey = Self.legacyClaudePlanUtilizationEmailAccountKey(snapshot: snapshot),
              legacyAccountKey != accountKey,
              let legacyHistories = providerBuckets.accounts[legacyAccountKey],
              !legacyHistories.isEmpty
        else {
            return accountKey
        }

        let existingHistories = providerBuckets.accounts[accountKey] ?? []
        let mergedHistory = Self.mergedPlanUtilizationHistories(provider: provider, histories: [
            existingHistories,
            legacyHistories,
        ])
        providerBuckets.accounts.removeValue(forKey: legacyAccountKey)
        providerBuckets.setHistories(mergedHistory, for: accountKey)
        if providerBuckets.preferredAccountKey == legacyAccountKey {
            providerBuckets.preferredAccountKey = accountKey
        }
        return accountKey
    }

    private func adoptPlanUtilizationUnscopedHistoryIfNeeded(
        into accountKey: String,
        provider: UsageProvider,
        providerBuckets: inout PlanUtilizationHistoryBuckets)
    {
        guard !providerBuckets.unscoped.isEmpty else { return }

        let existingHistory = providerBuckets.accounts[accountKey] ?? []
        let mergedHistory = Self.mergedPlanUtilizationHistories(provider: provider, histories: [
            existingHistory,
            providerBuckets.unscoped,
        ])
        providerBuckets.setHistories(mergedHistory, for: accountKey)
        providerBuckets.setHistories([], for: nil)
    }

    private func stickyPlanUtilizationAccountKey(
        providerBuckets: PlanUtilizationHistoryBuckets) -> String?
    {
        if providerBuckets.preferredAccountKey == Self.planUtilizationUnscopedPreferredKey {
            return nil
        }
        let knownAccountKeys = self.knownPlanUtilizationAccountKeys(providerBuckets: providerBuckets)
        guard !knownAccountKeys.isEmpty else { return nil }

        if let preferredAccountKey = providerBuckets.preferredAccountKey,
           knownAccountKeys.contains(preferredAccountKey)
        {
            return preferredAccountKey
        }

        if knownAccountKeys.count == 1 {
            return knownAccountKeys[0]
        }

        return knownAccountKeys.max { lhs, rhs in
            let lhsDate = providerBuckets.accounts[lhs]?.compactMap(\.latestCapturedAt).max() ?? .distantPast
            let rhsDate = providerBuckets.accounts[rhs]?.compactMap(\.latestCapturedAt).max() ?? .distantPast
            if lhsDate == rhsDate {
                return lhs > rhs
            }
            return lhsDate < rhsDate
        }
    }

    private func knownPlanUtilizationAccountKeys(providerBuckets: PlanUtilizationHistoryBuckets) -> [String] {
        providerBuckets.accounts.keys
            .sorted()
    }

    private func recoverableCodexOpaquePlanHistoryRawKey(
        targetCanonicalKey: String,
        ownership: CodexOwnershipContext,
        providerBuckets: PlanUtilizationHistoryBuckets) -> String?
    {
        guard !ownership.hasAdjacentMultiAccountVeto,
              let targetWeeklyResetAt = ownership.currentWeeklyResetAt
        else {
            return nil
        }

        let candidates = providerBuckets.accounts.compactMap { rawKey, histories -> String? in
            let owner = CodexHistoryOwnership.classifyPersistedKey(
                rawKey,
                legacyEmailHash: ownership.planUtilizationLegacyEmailHash)
            guard case .legacyOpaqueScoped = owner else { return nil }
            guard Self.isRecoverableCodexOpaquePlanHistory(
                histories,
                targetWeeklyResetAt: targetWeeklyResetAt)
            else {
                return nil
            }
            return rawKey
        }

        guard candidates.count == 1,
              let recoverableRawKey = candidates.first,
              let targetWeeklyResetAt = ownership.currentWeeklyResetAt
        else {
            return nil
        }

        guard !Self.hasConflictingScopedCodexPlanHistory(
            recoverableRawKey: recoverableRawKey,
            targetWeeklyResetAt: targetWeeklyResetAt,
            targetCanonicalKey: targetCanonicalKey,
            ownership: ownership,
            providerBuckets: providerBuckets)
        else {
            return nil
        }

        return recoverableRawKey
    }

    private nonisolated static func isRecoverableCodexOpaquePlanHistory(
        _ histories: [PlanUtilizationSeriesHistory],
        targetWeeklyResetAt: Date) -> Bool
    {
        guard let weekly = histories.first(where: { $0.name == .weekly && $0.windowMinutes == 10080 }),
              let session = histories.first(where: { $0.name == .session && $0.windowMinutes == 300 }),
              !session.entries.isEmpty
        else {
            return false
        }

        let distinctWeeklyResets = Set(weekly.entries.compactMap(\.resetsAt))
        guard distinctWeeklyResets.count >= 2 else { return false }
        guard weekly.entries.contains(where: { entry in
            Self.areEquivalentPlanUtilizationResetBoundaries(entry.resetsAt, targetWeeklyResetAt)
        }) else {
            return false
        }
        guard weekly.entries.contains(where: { entry in
            guard let reset = entry.resetsAt else { return false }
            return !Self.areEquivalentPlanUtilizationResetBoundaries(reset, targetWeeklyResetAt)
        }) else {
            return false
        }
        return true
    }

    private nonisolated static func areEquivalentPlanUtilizationResetBoundaries(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < self.planUtilizationResetEquivalenceToleranceSeconds
    }

    private nonisolated static func scopedRawKeysRelevantToCodexUnscopedPlanHistory(
        _ providerBuckets: PlanUtilizationHistoryBuckets) -> [String]
    {
        guard let continuityWindow = self.planUtilizationContinuityWindow(for: providerBuckets) else {
            return []
        }

        return providerBuckets.accounts.compactMap { rawKey, histories in
            guard self.planUtilizationHistories(histories, overlap: continuityWindow) else {
                return nil
            }
            return rawKey
        }
    }

    private nonisolated static func planUtilizationContinuityWindow(
        for providerBuckets: PlanUtilizationHistoryBuckets) -> ClosedRange<Date>?
    {
        let capturedDates = providerBuckets.unscoped.flatMap(\.entries).map(\.capturedAt)
        guard let lowerBound = capturedDates.min(),
              let upperBound = capturedDates.max()
        else {
            return nil
        }
        let allHistories = providerBuckets.unscoped + providerBuckets.accounts.values.flatMap(\.self)
        let expansionMinutes = allHistories.map(\.windowMinutes).max() ?? 0
        let expansion = TimeInterval(expansionMinutes) * 60
        return lowerBound.addingTimeInterval(-expansion)...upperBound.addingTimeInterval(expansion)
    }

    private nonisolated static func planUtilizationHistories(
        _ histories: [PlanUtilizationSeriesHistory],
        overlap continuityWindow: ClosedRange<Date>) -> Bool
    {
        histories.contains { history in
            history.entries.contains { continuityWindow.contains($0.capturedAt) }
        }
    }

    private nonisolated static func hasConflictingScopedCodexPlanHistory(
        recoverableRawKey: String,
        targetWeeklyResetAt: Date,
        targetCanonicalKey: String,
        ownership: CodexOwnershipContext,
        providerBuckets: PlanUtilizationHistoryBuckets) -> Bool
    {
        providerBuckets.accounts.contains { rawKey, histories in
            guard rawKey != recoverableRawKey else { return false }
            guard self.historiesContainEquivalentWeeklyResetBoundary(
                histories,
                targetWeeklyResetAt: targetWeeklyResetAt)
            else {
                return false
            }

            let owner = CodexHistoryOwnership.classifyPersistedKey(
                rawKey,
                legacyEmailHash: ownership.planUtilizationLegacyEmailHash)
            switch owner {
            case .legacyOpaqueScoped:
                return false
            case .canonical, .legacyEmailHash:
                return !CodexHistoryOwnership.belongsToTargetContinuity(
                    owner,
                    targetCanonicalKey: targetCanonicalKey,
                    canonicalEmailHashKey: ownership.canonicalEmailHashKey)
            case .legacyUnscoped:
                return false
            }
        }
    }

    private nonisolated static func historiesContainEquivalentWeeklyResetBoundary(
        _ histories: [PlanUtilizationSeriesHistory],
        targetWeeklyResetAt: Date) -> Bool
    {
        histories.contains { history in
            history.entries.contains { entry in
                self.areEquivalentPlanUtilizationResetBoundaries(entry.resetsAt, targetWeeklyResetAt)
            }
        }
    }

    private nonisolated static func mergedPlanUtilizationHistories(
        provider _: UsageProvider,
        histories: [[PlanUtilizationSeriesHistory]]) -> [PlanUtilizationSeriesHistory]
    {
        var mergedByKey: [PlanUtilizationSeriesKey: PlanUtilizationSeriesHistory] = [:]

        for historyGroup in histories {
            for history in historyGroup {
                let key = PlanUtilizationSeriesKey(name: history.name, windowMinutes: history.windowMinutes)
                let existingEntries = mergedByKey[key]?.entries ?? []
                var mergedEntries = existingEntries
                for entry in history.entries.sorted(by: { $0.capturedAt < $1.capturedAt }) {
                    if let updatedEntries = self.updatedPlanUtilizationEntries(
                        existingEntries: mergedEntries,
                        entry: entry)
                    {
                        mergedEntries = updatedEntries
                    }
                }
                mergedByKey[key] = PlanUtilizationSeriesHistory(
                    name: history.name,
                    windowMinutes: history.windowMinutes,
                    entries: mergedEntries)
            }
        }

        return mergedByKey.values.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    #if DEBUG
    nonisolated static func _planUtilizationAccountKeyForTesting(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> String?
    {
        self.planUtilizationIdentityAccountKey(provider: provider, snapshot: snapshot)
    }

    nonisolated static func _planUtilizationTokenAccountKeyForTesting(
        provider: UsageProvider,
        account: ProviderTokenAccount) -> String?
    {
        self.planUtilizationAccountKey(provider: provider, account: account)
    }

    nonisolated static func _claudeOAuthPlanUtilizationAccountKeyForTesting(
        historyOwnerIdentifier: String?,
        persistentRefHash: String? = nil) -> String?
    {
        self.claudeOAuthPlanUtilizationAccountKey(
            historyOwnerIdentifier: historyOwnerIdentifier,
            corroboratingPersistentRefHash: persistentRefHash)
    }

    nonisolated static func _legacyClaudePlanUtilizationEmailAccountKeyForTesting(snapshot: UsageSnapshot) -> String? {
        self.legacyClaudePlanUtilizationEmailAccountKey(snapshot: snapshot)
    }

    nonisolated static func _codexLegacyPlanUtilizationEmailHashKeyForTesting(
        normalizedEmail: String) -> String
    {
        self.codexLegacyPlanUtilizationEmailHashKey(for: normalizedEmail)
    }
    #endif
}

actor PlanUtilizationHistoryPersistenceCoordinator {
    private let store: PlanUtilizationHistoryStore
    private var pendingSnapshot: [UsageProvider: PlanUtilizationHistoryBuckets]?
    private var isPersisting: Bool = false

    init(store: PlanUtilizationHistoryStore) {
        self.store = store
    }

    func enqueue(_ snapshot: [UsageProvider: PlanUtilizationHistoryBuckets]) {
        self.pendingSnapshot = snapshot
        guard !self.isPersisting else { return }
        self.isPersisting = true

        Task(priority: .utility) {
            await self.persistLoop()
        }
    }

    private func persistLoop() async {
        while let nextSnapshot = self.pendingSnapshot {
            self.pendingSnapshot = nil
            await self.saveAsync(nextSnapshot)
        }

        self.isPersisting = false
    }

    private func saveAsync(_ snapshot: [UsageProvider: PlanUtilizationHistoryBuckets]) async {
        let store = self.store
        await Task.detached(priority: .utility) {
            store.save(snapshot)
        }.value
    }
}

/// Prompt-free reader for the active Claude account UUID recorded in `~/.claude.json`. The `@TaskLocal` test
/// seam lives here (not on `UsageStore`) because Swift forbids stored properties in extensions and task-local
/// storage must be nonisolated, whereas `UsageStore` is `@MainActor`.
private enum ClaudeActiveAccountProbe {
    #if DEBUG
    enum Override: Sendable {
        case value(String?)
    }

    @TaskLocal static var activeClaudeAccountUuidOverrideForTesting: Override?
    #endif

    private struct ClaudeConfigAccount: Decodable {
        struct OAuthAccount: Decodable {
            let accountUuid: String?
        }

        let oauthAccount: OAuthAccount?
    }

    static func activeClaudeAccountUuid() -> String? {
        #if DEBUG
        if case let .value(uuid) = self.activeClaudeAccountUuidOverrideForTesting {
            return uuid
        }
        #endif
        // `~/.claude.json` is a SIBLING of `.claude/`, not inside it. Home resolution mirrors
        // `ClaudeOAuthCredentials.defaultCredentialsURL()`. This intentionally does NOT honor
        // CLAUDE_CONFIG_DIR: the credential store that yields `historyOwnerIdentifier` is purely
        // home-relative, so the accountUuid corroboration must resolve against the same home or the
        // two signals would point at different accounts.
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ClaudeConfigAccount.self, from: data),
              let uuid = decoded.oauthAccount?.accountUuid?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uuid.isEmpty
        else {
            return nil
        }
        return uuid
    }
}
