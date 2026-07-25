import Foundation
import Testing
@testable import AgentIslandApp

@Suite(.serialized)
struct CodexSessionIndexWatcherTests {
    private actor ChangeRecorder {
        private(set) var count = 0

        func record() {
            count += 1
        }
    }

    @Test
    func detectsAtomicSessionIndexReplacement() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-island-session-index-\(UUID().uuidString)", isDirectory: true)
        let sessionIndexURL = directoryURL.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data().write(to: sessionIndexURL)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let recorder = ChangeRecorder()
        let watcher = CodexSessionIndexWatcher(
            sessionIndexURL: sessionIndexURL,
            debounceInterval: 0.01
        ) {
            Task {
                await recorder.record()
            }
        }
        watcher.start()
        defer {
            watcher.stop()
        }

        try """
        {"id":"codex-session","thread_name":"Renamed thread"}
        """.appending("\n").write(
            to: sessionIndexURL,
            atomically: true,
            encoding: .utf8
        )

        for _ in 0..<20 where await recorder.count == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(await recorder.count > 0)
    }
}
