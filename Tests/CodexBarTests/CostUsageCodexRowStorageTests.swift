import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexRowStorageTests {
    enum ReadMode: CaseIterable {
        case report, scan, cache, snapshot
    }

    @Test(arguments: ReadMode.allCases)
    func `retained Codex rows share identical turn strings without changing their bytes`(mode: ReadMode) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 1)
        defer { fixture.remove() }
        let turns: [String?] = [
            nil,
            "synthetic-turn-caf\u{e9}-00000001",
            "synthetic-turn-cafe\u{301}-00000001",
            "synthetic-turn-third-0000000001",
        ]
        let rows = (0..<10000).map { index in
            CostUsageScanner.CodexUsageRow(
                day: ReadWorkFixture.day,
                model: ReadWorkFixture.model,
                rawModel: "synthetic-original-model",
                turnID: turns[index % turns.count],
                eventIndex: index,
                timestampUnixMs: 1_785_542_400_000 + Int64(index),
                input: index,
                cached: 2,
                output: 3,
                reasoning: 1,
                knownCostNanos: Int64(index),
                pricingModel: "synthetic-priced-model",
                pricingMode: index.isMultiple(of: 2) ? "priority" : nil,
                responseID: "synthetic-response-\(index)",
                requestMirrorKeys: ["synthetic-mirror-\(index)"])
        }
        var cache = fixture.canonical
        let paths = cache.files.keys.sorted()
        cache.files[paths[0]]?.codexRows = Array(rows.prefix(5000))
        cache.files[paths[1]]?.codexRows = Array(rows.suffix(5000))
        #expect(!fixture.save(cache).catchUpRequired)
        let loaded: CostUsageCache
        switch mode {
        case .report:
            let view = fixture.store.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .report)
            loaded = try #require(Mirror(reflecting: view).children.first { $0.label == "cache" }?.value
                as? CostUsageCache)
        case .scan:
            let scan = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            loaded = scan.cache
            scan.release()
        case .cache:
            loaded = fixture.store.syncLoadCodexCache(calendar: fixture.calendar, loadTokenSnapshots: false)
        case .snapshot:
            loaded = await CostUsageStore.decodeCodexCache(from: fixture.store.readSnapshot(), recorder: nil)
        }
        let actual = paths.flatMap { loaded.files[$0]?.codexRows ?? [] }
        #expect(actual.count == rows.count)
        let strings = actual.compactMap(\.turnID)
        let identities = try Set(strings.map { value in
            try #require(value.utf8.withContiguousStorageIfAvailable { UInt(bitPattern: $0.baseAddress) })
        })
        print("[codex-row-storage] mode=\(mode) rows=\(actual.count) turnAllocations=\(identities.count)")
        #expect(identities.count == turns.compactMap(\.self).count)
        #expect(Set(strings.map { Data($0.utf8) }) == Set(turns.compactMap(\.self).map { Data($0.utf8) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(actual) == encoder.encode(rows))
    }
}
