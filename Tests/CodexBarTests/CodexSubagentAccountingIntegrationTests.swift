import Foundation
import Testing
@testable import CodexBarCore

struct CodexSubagentAccountingIntegrationTests {
    private typealias Usage = (input: Int, cached: Int, output: Int)

    @Test
    func `copied parent prefix keeps the inherited baseline after late lineage metadata`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 16)
        let forkTimestamp = env.isoString(for: day)
        let parentModel = "openai/gpt-5.3"
        let leafModel = "openai/gpt-5.4"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(forkTimestamp)-child-session.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": forkTimestamp,
                    "payload": [
                        "id": "child-session",
                        "timestamp": forkTimestamp,
                        "source": [
                            "subagent": [
                                "thread_spawn": ["parent_thread_id": "parent-session"],
                            ],
                        ],
                    ],
                ],
                self.turnContext(timestamp: forkTimestamp, model: parentModel),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: parentModel,
                    total: (input: 1000, cached: 900, output: 100),
                    last: (input: 50, cached: 10, output: 5)),
                [
                    "type": "session_meta",
                    "timestamp": forkTimestamp,
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "parent-session",
                        "timestamp": forkTimestamp,
                    ],
                ],
                [
                    "type": "session_meta",
                    "timestamp": forkTimestamp,
                    "payload": [
                        "id": "parent-session",
                        "timestamp": forkTimestamp,
                    ],
                ],
                self.turnContext(timestamp: forkTimestamp, model: leafModel),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: leafModel,
                    total: (input: 1050, cached: 910, output: 105),
                    last: (input: 50, cached: 10, output: 5)),
            ]))

        var resolvedParentBaseline = false
        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            inheritedTotalsResolver: { parentSessionID, _ in
                resolvedParentBaseline = true
                #expect(parentSessionID == "parent-session")
                return .resolved(.init(input: 1000, cached: 900, output: 100))
            })

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalizedLeafModel = CostUsagePricing.normalizeCodexModel(leafModel)
        #expect(parsed.days[dayKey]?[normalizedLeafModel] == [50, 10, 5])
        #expect(parsed.days[dayKey]?[CostUsagePricing.normalizeCodexModel(parentModel)] == nil)
        #expect(resolvedParentBaseline)
        #expect(parsed.dependsOnParentTotals)
    }

    @Test
    func `local marker owns only its suffix and persists lineage-only cache mode`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 16)
        let forkTimestamp = env.isoString(for: day)
        let parentModel = "openai/gpt-5.3"
        let leafModel = "openai/gpt-5.4"
        let fastContents = try env.jsonl([
            [
                "type": "session_meta",
                "timestamp": forkTimestamp,
                "payload": [
                    "id": "marker-child",
                    "timestamp": forkTimestamp,
                    "source": [
                        "subagent": [
                            "thread_spawn": ["parent_thread_id": "parent-session"],
                        ],
                    ],
                ],
            ],
            self.turnContext(timestamp: forkTimestamp, model: parentModel),
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: parentModel,
                total: (input: 1000, cached: 900, output: 100),
                last: (input: 50, cached: 10, output: 5)),
            [
                "type": "session_meta",
                "timestamp": forkTimestamp,
                "payload": [
                    "id": "marker-child",
                    "forked_from_id": "parent-session",
                    "timestamp": forkTimestamp,
                ],
            ],
            [
                "type": "session_meta",
                "timestamp": forkTimestamp,
                "payload": ["id": "ancestor-session"],
            ],
            self.turnContext(timestamp: env.isoString(for: day.addingTimeInterval(2)), model: leafModel),
            [
                "type": "inter_agent_communication_metadata",
                "timestamp": env.isoString(for: day.addingTimeInterval(2)),
                "payload": ["trigger_turn": true],
            ],
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(2.5)),
                model: parentModel,
                total: (input: 1000, cached: 900, output: 100),
                last: (input: 50, cached: 10, output: 5)),
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(3)),
                model: leafModel,
                total: (input: 1050, cached: 910, output: 105),
                last: (input: 50, cached: 10, output: 5)),
        ])
        let fastFileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(forkTimestamp)-marker-child.jsonl",
            contents: fastContents)
        let fallbackFileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(forkTimestamp)-marker-child-fallback.jsonl",
            contents: fastContents
                .replacingOccurrences(of: "marker-child", with: "marker-child-fallback")
                .replacingOccurrences(
                    of: "\"type\":\"session_meta\"",
                    with: "\"ty\\u0070e\":\"session_meta\"")
                .replacingOccurrences(
                    of: "\"type\":\"turn_context\"",
                    with: "\"ty\\u0070e\":\"turn_context\"")
                .replacingOccurrences(
                    of: "\"type\":\"inter_agent_communication_metadata\"",
                    with: "\"ty\\u0070e\":\"inter_agent_communication_metadata\""))

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalizedLeafModel = CostUsagePricing.normalizeCodexModel(leafModel)
        for fileURL in [fastFileURL, fallbackFileURL] {
            var resolvedParentBaseline = false
            let parsed = CostUsageScanner.parseCodexFile(
                fileURL: fileURL,
                range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
                inheritedTotalsResolver: { _, _ in
                    resolvedParentBaseline = true
                    return .resolved(.init(input: 10, cached: 0, output: 0))
                })
            #expect(parsed.days[dayKey]?[normalizedLeafModel] == [50, 10, 5])
            #expect(parsed.days[dayKey]?[CostUsagePricing.normalizeCodexModel(parentModel)] == nil)
            #expect(!parsed.dependsOnParentTotals)
            #expect(!resolvedParentBaseline)
        }

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(report.data.first?.totalTokens == 110)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let childUsages = cache.files.values.filter { $0.sessionId?.hasPrefix("marker-child") == true }
        #expect(childUsages.count == 2)
        #expect(childUsages.allSatisfy {
            $0.forkBaselineDependencyKey == CostUsageScanner.codexForkDependencyNotRequiredKey
        })
    }

    @Test
    func `copied prefix infers its parent and ignores a spoofed trigger outside the payload`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 16)
        let forkTimestamp = env.isoString(for: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(forkTimestamp)-inferred-parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": forkTimestamp,
                    "payload": [
                        "id": "inferred-child",
                        "timestamp": forkTimestamp,
                        "source": ["subagent": ["thread_spawn": [:]]],
                    ],
                ],
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: "openai/gpt-5.3",
                    total: (input: 1000, cached: 900, output: 100),
                    last: (input: 50, cached: 10, output: 5)),
                [
                    "type": "session_meta",
                    "timestamp": forkTimestamp,
                    "payload": ["id": "inferred-parent"],
                ],
                self.turnContext(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: "openai/gpt-5.4"),
                [
                    "type": "inter_agent_communication_metadata",
                    "timestamp": env.isoString(for: day.addingTimeInterval(2)),
                    "trigger_turn": true,
                    "payload": ["trigger_turn": false],
                ],
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: "openai/gpt-5.4",
                    total: (input: 1050, cached: 910, output: 105),
                    last: (input: 50, cached: 10, output: 5)),
            ]))

        var resolvedParentBaseline = false
        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            inheritedTotalsResolver: { parentSessionID, _ in
                resolvedParentBaseline = true
                #expect(parentSessionID == "inferred-parent")
                return .resolved(.init(input: 1000, cached: 900, output: 100))
            })

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let model = CostUsagePricing.normalizeCodexModel("openai/gpt-5.4")
        #expect(parsed.days[dayKey]?[model] == [50, 10, 5])
        #expect(parsed.forkedFromId == "inferred-parent")
        #expect(parsed.dependsOnParentTotals)
        #expect(resolvedParentBaseline)
    }

    @Test
    func `idless copied prefix without a parent or local marker is suppressed`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 16)
        let timestamp = env.isoString(for: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-ambiguous-prefix.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": [
                        "id": "ambiguous-child",
                        "source": ["subagent": ["thread_spawn": [:]]],
                    ],
                ],
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: "openai/gpt-5.3",
                    total: (input: 1000, cached: 900, output: 100)),
                ["type": "session_meta", "timestamp": timestamp, "payload": [:]],
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: "openai/gpt-5.4",
                    total: (input: 1050, cached: 910, output: 105)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))

        #expect(parsed.days.isEmpty)
        #expect(parsed.rows.isEmpty)
    }

    @Test
    func `appended ancestor metadata reclassifies the complete subagent rollout`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 16)
        let timestamp = env.isoString(for: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-growing-subagent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": [
                        "id": "growing-child",
                        "source": ["subagent": ["thread_spawn": [:]]],
                    ],
                ],
                self.turnContext(timestamp: timestamp, model: "openai/gpt-5.3"),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: "openai/gpt-5.3",
                    total: (input: 1000, cached: 900, output: 100)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.first?.totalTokens == 1100)

        let appended = try env.jsonl([
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "growing-parent"]],
            self.turnContext(
                timestamp: env.isoString(for: day.addingTimeInterval(2)),
                model: "openai/gpt-5.4"),
            [
                "type": "inter_agent_communication_metadata",
                "timestamp": env.isoString(for: day.addingTimeInterval(2)),
                "payload": ["trigger_turn": true],
            ],
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(3)),
                model: "openai/gpt-5.4",
                total: (input: 1050, cached: 910, output: 105),
                last: (input: 50, cached: 10, output: 5)),
        ])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(second.data.first?.totalTokens == 55)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let usage = try #require(cache.files.values.first { $0.sessionId == "growing-child" })
        #expect(usage.sessionId == "growing-child")
        #expect(usage.forkedFromId == "growing-parent")
        #expect(usage.forkBaselineDependencyKey == CostUsageScanner.codexForkDependencyNotRequiredKey)
    }

    private func turnContext(timestamp: String, model: String) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": ["model": model],
        ]
    }

    private func tokenCount(
        timestamp: String,
        model: String,
        total: Usage? = nil,
        last: Usage? = nil) -> [String: Any]
    {
        var info: [String: Any] = ["model": model]
        if let total {
            info["total_token_usage"] = [
                "input_tokens": total.input,
                "cached_input_tokens": total.cached,
                "output_tokens": total.output,
            ]
        }
        if let last {
            info["last_token_usage"] = [
                "input_tokens": last.input,
                "cached_input_tokens": last.cached,
                "output_tokens": last.output,
            ]
        }
        return [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": info,
            ],
        ]
    }
}
