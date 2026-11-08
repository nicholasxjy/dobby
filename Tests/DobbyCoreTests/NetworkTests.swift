import Foundation
import Testing
@testable import DobbyCore

@Suite struct NetworkTests {
    @Test func derivesRatesAndHandlesCounterResets() {
        let old = NetworkCounters(received: 4096, sent: 2048)
        #expect(NetworkCounters(received: 8192, sent: 3072).rate(since: old, seconds: 2) == NetworkRate(upload: 512, download: 2048))
        #expect(NetworkCounters(received: 1, sent: 1).rate(since: old, seconds: 2) == .zero)
        #expect(old.rate(since: old, seconds: 0) == .zero)
    }

    @Test func interfaceChangesDoNotCreateSpikes() {
        let previous: [UInt16: NetworkCounters] = [
            1: .init(received: 100, sent: 200),
            2: .init(received: 900_000, sent: 800_000),
            3: .init(received: 5000, sent: 5000),
        ]
        let current: [UInt16: NetworkCounters] = [
            1: .init(received: 300, sent: 600),
            3: .init(received: 10, sent: 20),
            4: .init(received: 1_000_000, sent: 2_000_000),
        ]
        #expect(NetworkStats.rate(previous: previous, current: current, seconds: 2) == NetworkRate(upload: 200, download: 100))
    }

    @Test func parsesNettopSamplesWithPunctuationInNames() throws {
        let output = """
        ,bytes_in,bytes_out,
        com.example.app.42,1024,2048,
        app, helper.73,10,20,
        exited.99,9999,9999,
        ,bytes_in,bytes_out,
        com.example.app.42,5120,4096,
        app, helper.73,30,60,
        new.101,9000,9000,
        """
        let rates = try NetworkProcessSampler.rates(from: output, seconds: 2)
        #expect(rates[42] == NetworkRate(upload: 1024, download: 2048))
        #expect(rates[73] == NetworkRate(upload: 20, download: 10))
        #expect(rates[99] == nil)
        #expect(rates[101] == .zero)
    }

    @Test func rejectsIncompleteOrMalformedNettopOutput() {
        for output in ["", ",bytes_in,bytes_out,\napp.42,1,2,", ",bytes_in,bytes_out,\napp.42,no,2,", ",bytes_in,bytes_out,\napp.no-pid,1,2,"] {
            #expect(throws: (any Error).self) { try NetworkProcessSampler.rates(from: output, seconds: 1) }
        }
    }

    @Test func ranksByCombinedTrafficAndKeepsSearch() {
        var upload = usage(10, "Uploader")
        upload.network = NetworkRate(upload: 5000, download: 0)
        var download = usage(20, "Browser")
        download.network = NetworkRate(upload: 100, download: 10_000)
        #expect(ProcessRanking.ranked([upload, download], by: .network, query: "").map(\.pid) == [20, 10])
        #expect(ProcessRanking.ranked([upload, download], by: .network, query: "upload").map(\.pid) == [10])
    }

    @Test func formatsRatesForNarrowReadouts() {
        #expect(UsageFormat.rate(0) == "0 B/s")
        #expect(UsageFormat.rate(512) == "512 B/s")
        #expect(UsageFormat.rate(1536) == "1.5 KB/s")
        #expect(UsageFormat.rate(512 * 1024) == "512 KB/s")
        #expect(UsageFormat.rate(1.5 * 1024 * 1024) == "1.5 MB/s")
        #expect(UsageFormat.rate(-1) == "0 B/s")
        #expect(UsageFormat.rate(.nan) == "0 B/s")
    }

    @Test func readsLiveInterfaceCounters() throws {
        let interfaces = try #require(NetworkStats.interfaces())
        #expect(!interfaces.isEmpty)
    }

    @Test func readsLiveProcessTraffic() async throws {
        let rates = try await NetworkProcessSampler.sample(seconds: 1)
        #expect(!rates.isEmpty)
        #expect(rates.values.allSatisfy { $0.upload >= 0 && $0.download >= 0 })
    }

    @Test func cancelsProcessSamplingPromptly() async throws {
        let task = Task { try await NetworkProcessSampler.sample(seconds: 5) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled network sampling returned a result")
        } catch is CancellationError {
            #expect(start.duration(to: .now) < .seconds(2))
        }
    }
}
