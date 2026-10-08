import Darwin
import Foundation
import Testing
import WebKit
@testable import CodexBarCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_PERF_SWEEP"] == "1"))
struct CostUsagePerfSweepBenchmarkTests {
    @MainActor
    @Test
    func `synthetic WebKit leases release their owners`() async throws {
        final class WeakView {
            weak var value: WKWebView?

            init(_ value: WKWebView) { self.value = value }
        }
        let cache = OpenAIDashboardWebViewCache()
        defer { cache.clearAllForTesting() }
        let store = WKWebsiteDataStore.nonPersistent()
        var views: [WeakView] = []
        var processes: Set<pid_t> = []
        let url = try #require(URL(string: "about:blank"))
        for cycle in 0..<12 {
            let lease = try await cache.acquire(websiteDataStore: store, usageURL: url, logger: nil)
            _ = try await lease.webView.evaluateJavaScript("1")
            views.append(WeakView(lease.webView))
            let selector = NSSelectorFromString("_webProcessIdentifier")
            if lease.webView.responds(to: selector),
               let process = lease.webView.value(forKey: "_webProcessIdentifier") as? NSNumber,
               process.int32Value > 0
            {
                processes.insert(process.int32Value)
            }
            lease.release()
            #expect(cache.entryCount == 0)
            #expect(cache.activeAcquisitionCountForTesting == 0)
            print("[webkit-sweep] cycle=\(cycle) cacheEntries=\(cache.entryCount) " +
                "liveViews=\(views.filter { $0.value != nil }.count) " +
                "liveProcesses=\(processes.filter { $0 > 0 && kill($0, 0) == 0 }.count)")
            try await Task.sleep(for: .seconds(3))
        }
        try await Task.sleep(for: .seconds(3))
        print("[webkit-sweep] final cacheEntries=\(cache.entryCount) " +
            "liveViews=\(views.filter { $0.value != nil }.count) observedProcesses=\(processes.count) " +
            "liveProcesses=\(processes.filter { $0 > 0 && kill($0, 0) == 0 }.count)")
    }

    @Test
    func `fixed corpus refreshes over thirty minutes`() throws {
        let claude = try CostUsageClaudeWriteAmplificationTests.Fixture(rowCount: 24000, identityLength: 48)
        defer { claude.env.cleanup() }
        let codex = try ReadWorkFixture(fileCount: 180, rowsPerFile: 1000)
        defer { codex.remove() }
        let initial = try autoreleasepool { try claude.load(context: .spendDashboard) }
        let originalStamps = try claude.stamps(context: .spendDashboard)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let start = ContinuousClock.now
        let cpuStart = Self.cpuSeconds
        let seconds = Double(ProcessInfo.processInfo.environment["CODEXBAR_PERF_SWEEP_SECONDS"] ?? "1800") ?? 1800
        var cycle = 0
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            repeat {
                try autoreleasepool {
                    let report = try claude.load(context: .spendDashboard, cycle: cycle + 1)
                    #expect(report.summary == initial.summary)
                    let loaded = codex.store.syncLoadCodexScan(calendar: codex.calendar)
                    defer { loaded.release() }
                    #expect(loaded.cache.files.values.reduce(0) { $0 + ($1.codexRows?.count ?? 0) } == codex.rowCount)
                    let view = codex.store.syncLoadCodexReadView(calendar: codex.calendar, purpose: .report)
                    #expect(view.dailyReport(range: codex.range, cacheRoot: codex.env.cacheRoot).summary != nil)
                }
                let elapsed = start.duration(to: .now).components
                let wall = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let work = recorder.snapshot()
                print("[perf-sweep] pid=\(getpid()) cycle=\(cycle) elapsed=\(wall) rss=\(Self.residentBytes) " +
                    "cpuSeconds=\(Self.cpuSeconds - cpuStart) decodes=\(work.cacheDecodes) " +
                    "encodes=\(work.cacheEncodes)")
                fflush(nil)
                if wall >= seconds { break }
                Thread.sleep(forTimeInterval: min(30, seconds - wall))
                cycle += 1
            } while true
        }
        #expect(try claude.stamps(context: .spendDashboard) == originalStamps)
        #expect(recorder.snapshot().cacheDecodes == 0)
        #expect(recorder.snapshot().cacheEncodes == 0)
    }

    private static var cpuSeconds: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static var residentBytes: UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
