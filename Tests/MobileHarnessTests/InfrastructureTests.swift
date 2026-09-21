import Foundation
import Testing
@testable import MobileHarness

@Suite("Usage tracker and statistics")
struct UsageStatisticsTests {
    @Test("Records accumulate per model with reported and estimated costs apart")
    func trackerAggregation() {
        var tracker = UsageTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        tracker.record(UsageRecord(
            model: "openai/gpt-4o-mini",
            promptTokens: 10, completionTokens: 5, totalTokens: 15,
            cost: Decimal(string: "0.0001"), costSource: .reported
        ), at: start)
        tracker.record(UsageRecord(
            model: "openai/gpt-4o-mini",
            promptTokens: 20, completionTokens: 10, totalTokens: 30,
            cost: Decimal(string: "0.0002"), costSource: .reported
        ), at: start.addingTimeInterval(10))
        tracker.record(UsageRecord(
            model: "anthropic/claude-sonnet-4.5",
            promptTokens: 100, completionTokens: 50, totalTokens: 150,
            cost: Decimal(string: "0.001"), costSource: .estimated
        ), at: start.addingTimeInterval(20))

        let statistics = tracker.statistics
        #expect(statistics.requestCount == 3)
        #expect(statistics.promptTokens == 130)
        #expect(statistics.completionTokens == 65)
        #expect(statistics.totalTokens == 195)
        #expect(statistics.reportedCost == Decimal(string: "0.0003"))
        #expect(statistics.estimatedCost == Decimal(string: "0.001"))
        #expect(statistics.totalCost == Decimal(string: "0.0013"))
        #expect(statistics.startedAt == start)
        #expect(statistics.lastRequestAt == start.addingTimeInterval(20))

        let mini = statistics.perModel["openai/gpt-4o-mini"]
        #expect(mini?.requestCount == 2)
        #expect(mini?.totalTokens == 45)
        #expect(mini?.reportedCost == Decimal(string: "0.0003"))
        #expect(mini?.estimatedCost == 0)

        let claude = statistics.perModel["anthropic/claude-sonnet-4.5"]
        #expect(claude?.requestCount == 1)
        #expect(claude?.estimatedCost == Decimal(string: "0.001"))

        tracker.reset()
        #expect(tracker.statistics.requestCount == 0)
        #expect(tracker.statistics.startedAt == nil)
        #expect(tracker.statistics.perModel.isEmpty)
    }

    @Test("Records with no cost information still count tokens")
    func costlessRecords() {
        var tracker = UsageTracker()
        tracker.record(UsageRecord(
            model: "m", promptTokens: 1, completionTokens: 1, totalTokens: 2, cost: nil, costSource: nil
        ))
        let statistics = tracker.statistics
        #expect(statistics.requestCount == 1)
        #expect(statistics.totalCost == 0)
        #expect(statistics.averageCostPerRequest == 0)
    }

    @Test("Merging run records sums tokens and costs")
    func recordMerging() {
        let first = UsageRecord(
            model: "m", promptTokens: 10, completionTokens: 5, totalTokens: 15,
            cost: Decimal(string: "0.0001"), costSource: .reported
        )
        let second = UsageRecord(
            model: "m", promptTokens: 20, completionTokens: 15, totalTokens: 35,
            cost: Decimal(string: "0.0004"), costSource: .estimated
        )
        let merged = first.adding(second)
        #expect(merged.promptTokens == 30)
        #expect(merged.totalTokens == 50)
        #expect(merged.cost == Decimal(string: "0.0005"))
        // Mixed sources conservatively report as estimated.
        #expect(merged.costSource == .estimated)

        let costless = UsageRecord(model: "m", promptTokens: 0, completionTokens: 0, totalTokens: 0, cost: nil, costSource: nil)
        #expect(first.adding(costless).cost == Decimal(string: "0.0001"))
        #expect(costless.adding(costless).cost == nil)
    }
}

@Suite("Multipart form data")
struct MultipartFormDataTests {
    @Test("Bodies encode fields, files, and the closing boundary")
    func bodyLayout() {
        var form = MultipartFormData(boundary: "BOUNDARY")
        form.append("model_id", value: "scribe_v1")
        form.append("file", filename: "rec.m4a", mimeType: "audio/m4a", data: Data([0x41]))
        form.append("flag", value: "true")

        let body = String(decoding: form.body, as: UTF8.self)
        let expected = """
        --BOUNDARY\r
        Content-Disposition: form-data; name="model_id"\r
        \r
        scribe_v1\r
        --BOUNDARY\r
        Content-Disposition: form-data; name="file"; filename="rec.m4a"\r
        Content-Type: audio/m4a\r
        \r
        A\r
        --BOUNDARY\r
        Content-Disposition: form-data; name="flag"\r
        \r
        true\r
        --BOUNDARY--\r

        """
        #expect(body == expected)
        #expect(form.contentType == "multipart/form-data; boundary=BOUNDARY")
    }

    @Test("Boundaries are random per form")
    func randomBoundaries() {
        let first = MultipartFormData()
        let second = MultipartFormData()
        #expect(first.boundary != second.boundary)
    }
}

@Suite("API key stores")
struct APIKeyStoreTests {
    @Test("The in-memory store round-trips keys")
    func inMemoryRoundTrip() async throws {
        let store = InMemoryAPIKeyStore()
        let loaded = try await store.loadAPIKey(for: APIKeyService.openRouter)
        #expect(loaded == nil)

        try await store.saveAPIKey("key-1", for: APIKeyService.openRouter)
        #expect(try await store.loadAPIKey(for: APIKeyService.openRouter) == "key-1")

        // Saving again replaces rather than duplicates.
        try await store.saveAPIKey("key-2", for: APIKeyService.openRouter)
        #expect(try await store.loadAPIKey(for: APIKeyService.openRouter) == "key-2")

        try await store.deleteAPIKey(for: APIKeyService.openRouter)
        #expect(try await store.loadAPIKey(for: APIKeyService.openRouter) == nil)
        // Deleting an absent key succeeds.
        try await store.deleteAPIKey(for: APIKeyService.openRouter)
    }

    @Test("The keychain store round-trips keys and survives replacement", .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func keychainRoundTrip() async throws {
        let service = "MobileHarness.Tests.\(UUID().uuidString)"
        let account = "test-account"
        // The test process is unsigned, so macOS routes it at the legacy
        // file-based keychain instead of the entitlement-gated data
        // protection keychain a signed app would use.
        #if os(macOS)
        let store = KeychainAPIKeyStore(service: service, useDataProtectionKeychain: false)
        #else
        let store = KeychainAPIKeyStore(service: service)
        #endif

        var loaded = try await store.loadAPIKey(for: account)
        #expect(loaded == nil)

        try await store.saveAPIKey("first", for: account)
        loaded = try await store.loadAPIKey(for: account)
        #expect(loaded == "first")

        // Add-or-update: the second save replaces without failing.
        try await store.saveAPIKey("second", for: account)
        loaded = try await store.loadAPIKey(for: account)
        #expect(loaded == "second")

        try await store.deleteAPIKey(for: account)
        loaded = try await store.loadAPIKey(for: account)
        #expect(loaded == nil)
    }
}
