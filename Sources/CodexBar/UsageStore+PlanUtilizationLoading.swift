import Foundation

extension UsageStore {
    func startPlanUtilizationHistoryLoad(gate: PlanUtilizationHistoryLoadGate?) {
        let historyStore = self.planUtilizationHistoryStore
        self.planUtilizationHistoryLoadTask = Task { @MainActor [weak self] in
            // In-memory starts empty; mutation paths and sync menu accessors gate on
            // `planUtilizationHistoryLoaded` until the background decode publishes once.
            if let gate {
                let shouldLoad = await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    gate.cancel()
                }
                guard shouldLoad, !Task.isCancelled else { return }
            }
            let loaded = await historyStore.loadAsync()
            guard !Task.isCancelled, let self, !self.planUtilizationHistoryLoaded else { return }
            self.planUtilizationHistory = loaded
            self.planUtilizationHistoryLoaded = true
            self.planUtilizationHistoryRevision &+= 1
        }
    }
}
