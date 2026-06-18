import CodexBarCore
import Foundation

extension UsageStore {
    private nonisolated static let weeklyLimitResetThreshold = 1.0
    private nonisolated static let weeklyLimitResetDetectorDefaultsKey = "weeklyLimitResetDetectorStates"
    private nonisolated static let weeklyWindowMinutes = 7 * 24 * 60

    struct WeeklyLimitResetDetectorState: Codable, Equatable {
        let wasAboveThreshold: Bool
        let lastObservedAt: Date
    }

    /// Whether plan-utilization samples are persisted to the history folder for
    /// this provider. Recording is enabled for every provider; providers that
    /// expose no percent-bearing rate windows simply produce no samples.
    func recordsPlanUtilizationHistory(for _: UsageProvider) -> Bool {
        true
    }

    /// Whether the plan-utilization history menu/chart is surfaced for this
    /// provider. Codex and Claude always qualify; every other provider qualifies
    /// once it has accumulated history in the store.
    func supportsPlanUtilizationHistory(for provider: UsageProvider) -> Bool {
        switch provider {
        case .codex, .claude:
            true
        default:
            !(self.planUtilizationHistory[provider]?.isEmpty ?? true)
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

    func planUtilizationHistory(for provider: UsageProvider) -> [PlanUtilizationSeriesHistory] {
        self.planUtilizationHistorySelection(for: provider).histories
    }

    func planUtilizationHistorySelection(for provider: UsageProvider)
        -> (accountKey: String?, histories: [PlanUtilizationSeriesHistory])
    {
        var providerBuckets = self.planUtilizationHistory[provider] ?? PlanUtilizationHistoryBuckets()
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
        shouldUpdatePreferredAccountKey: Bool = true,
        shouldAdoptUnscopedHistory: Bool = true,
        now: Date = Date())
        async
    {
        let samples = self.planUtilizationSeriesSamples(provider: provider, snapshot: snapshot, capturedAt: now)
        guard !samples.isEmpty else { return }

        let detectorAccountKey = self.planUtilizationAccountKey(
            for: provider,
            snapshot: snapshot,
            preferredAccount: account)
        await MainActor.run {
            self.postWeeklyLimitResetCelebrationIfNeeded(
                provider: provider,
                account: account,
                snapshot: snapshot,
                accountKey: detectorAccountKey,
                samples: samples)
        }

        guard self.recordsPlanUtilizationHistory(for: provider) else { return }
        guard !self.shouldDeferClaudePlanUtilizationHistory(provider: provider) else { return }

        var snapshotToPersist: [UsageProvider: PlanUtilizationHistoryBuckets]?
        var telemetryAccountKey: String?
        await MainActor.run {
            var providerBuckets = self.planUtilizationHistory[provider] ?? PlanUtilizationHistoryBuckets()
            let preferredAccount = account ?? self.settings.selectedTokenAccount(for: provider)
            let accountKey = self.resolvePlanUtilizationAccountKey(
                provider: provider,
                snapshot: snapshot,
                preferredAccount: preferredAccount,
                shouldUpdatePreferredAccountKey: shouldUpdatePreferredAccountKey,
                shouldAdoptUnscopedHistory: shouldAdoptUnscopedHistory,
                providerBuckets: &providerBuckets)
            let histories = providerBuckets.histories(for: accountKey)

            guard let updatedHistories = Self.updatedPlanUtilizationHistories(
                provider: provider,
                existingHistories: histories,
                samples: samples)
            else {
                return
            }

            let accountLabel = self.planUtilizationAccountLabel(
                provider: provider,
                snapshot: snapshot,
                account: preferredAccount,
                accountKey: accountKey)
            providerBuckets.setHistories(updatedHistories, for: accountKey)
            providerBuckets.setLabel(accountLabel, for: accountKey)
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

    private func postWeeklyLimitResetCelebrationIfNeeded(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot,
        accountKey: String?,
        samples: [PlanUtilizationSeriesSample])
    {
        guard let weeklySample = Self.representativeWeeklySample(samples) else { return }

        let accountIdentifier = self.weeklyLimitResetAccountIdentifier(
            provider: provider,
            account: account,
            snapshot: snapshot,
            accountKey: accountKey)
        let detectorKey = Self.weeklyLimitResetDetectorStateKey(
            provider: provider,
            accountIdentifier: accountIdentifier)
        let currentUsed = weeklySample.entry.usedPercent
        let currentObservedAt = weeklySample.entry.capturedAt
        let wasAboveThreshold = currentUsed > Self.weeklyLimitResetThreshold
        if let existingState = self.weeklyLimitResetDetectorStates[detectorKey],
           currentObservedAt <= existingState.lastObservedAt
        {
            return
        }

        let shouldPost = self.weeklyLimitResetDetectorStates[detectorKey]?.wasAboveThreshold == true
            && !wasAboveThreshold
        self.weeklyLimitResetDetectorStates[detectorKey] = WeeklyLimitResetDetectorState(
            wasAboveThreshold: wasAboveThreshold,
            lastObservedAt: currentObservedAt)
        self.persistWeeklyLimitResetDetectorStates()

        guard shouldPost else { return }
        let accountLabel = self.weeklyLimitResetAccountLabel(
            provider: provider,
            account: account,
            snapshot: snapshot)
        let event = WeeklyLimitResetEvent(
            provider: provider,
            accountIdentifier: accountIdentifier,
            accountLabel: accountLabel,
            usedPercent: currentUsed)

        CodexBarLog.logger(LogCategories.confetti).info(
            "Weekly limit reset",
            metadata: [
                "provider": provider.rawValue,
                "accountIdentifier": accountIdentifier,
                "accountLabel": accountLabel ?? "",
                "usedPercent": String(format: "%.2f", currentUsed),
                "observedAt": String(format: "%.0f", currentObservedAt.timeIntervalSince1970),
            ])
        NotificationCenter.default.post(name: .codexbarWeeklyLimitReset, object: event)
    }

    private func planUtilizationSeriesSamples(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        capturedAt: Date) -> [PlanUtilizationSeriesSample]
    {
        var samplesByKey: [PlanUtilizationSeriesKey: PlanUtilizationSeriesSample] = [:]

        func appendWindow(_ window: RateWindow?, name: PlanUtilizationSeriesName?) {
            guard let name,
                  let window,
                  let windowMinutes = window.windowMinutes,
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
            for window in [snapshot.primary, snapshot.secondary, snapshot.tertiary] {
                guard let window, let windowMinutes = window.windowMinutes, windowMinutes > 0 else { continue }
                appendWindow(window, name: Self.genericPlanUtilizationSeriesName(forWindowMinutes: windowMinutes))
            }
        }

        return samplesByKey.values.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    /// Maps an arbitrary provider rate-window duration to a stable series name.
    /// Known durations reuse the canonical `.session`/`.weekly` names; anything
    /// else gets a deterministic per-window name so distinct windows stay
    /// separate series.
    private nonisolated static func genericPlanUtilizationSeriesName(
        forWindowMinutes windowMinutes: Int) -> PlanUtilizationSeriesName
    {
        switch windowMinutes {
        case 295...305:
            .session
        case 10070...10090:
            .weekly
        default:
            PlanUtilizationSeriesName(rawValue: "window-\(windowMinutes)m")
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

    private func weeklyLimitResetAccountIdentifier(
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

    private func weeklyLimitResetAccountLabel(
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

    private nonisolated static func weeklyLimitResetDetectorStateKey(
        provider: UsageProvider,
        accountIdentifier: String) -> String
    {
        "\(provider.rawValue):\(accountIdentifier)"
    }

    nonisolated static func loadWeeklyLimitResetDetectorStates(from userDefaults: UserDefaults)
        -> [String: WeeklyLimitResetDetectorState]
    {
        guard let data = userDefaults.data(forKey: self.weeklyLimitResetDetectorDefaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: WeeklyLimitResetDetectorState].self, from: data)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to decode weekly limit reset detector state",
                metadata: ["error": String(describing: error)])
            return [:]
        }
    }

    private func persistWeeklyLimitResetDetectorStates() {
        do {
            let data = try JSONEncoder().encode(self.weeklyLimitResetDetectorStates)
            self.settings.userDefaults.set(data, forKey: Self.weeklyLimitResetDetectorDefaultsKey)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to encode weekly limit reset detector state",
                metadata: ["error": String(describing: error)])
        }
    }

    private func resolvePlanUtilizationAccountKey(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        preferredAccount: ProviderTokenAccount?,
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

        let resolvedAccount = preferredAccount ?? self.settings.selectedTokenAccount(for: provider)
        if let tokenAccountKey = Self.planUtilizationAccountKey(provider: provider, account: resolvedAccount) {
            if shouldUpdatePreferredAccountKey {
                providerBuckets.preferredAccountKey = tokenAccountKey
            }
            if shouldAdoptUnscopedHistory {
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
            if shouldAdoptUnscopedHistory {
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
