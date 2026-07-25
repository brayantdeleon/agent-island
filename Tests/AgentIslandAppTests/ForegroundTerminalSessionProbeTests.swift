import XCTest
@testable import AgentIslandApp
import AgentIslandCore

final class ForegroundTerminalSessionProbeTests: XCTestCase {
    func testMatchesGhosttyFrontmostTerminalBySessionID() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { "com.mitchellh.ghostty" },
            appleScriptRunner: { _ in "ghostty-frontmost" }
        )

        let matches = await probe.matches(
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "codex ~/agent-island",
                terminalSessionID: "ghostty-frontmost"
            )
        )

        XCTAssertTrue(matches)
    }

    func testMatchesTerminalFrontmostTabByTTY() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { "com.apple.Terminal" },
            appleScriptRunner: { _ in "ttys001" }
        )

        let matches = await probe.matches(
            jumpTarget: JumpTarget(
                terminalApp: "Terminal",
                workspaceName: "agent-island",
                paneTitle: "codex ~/agent-island",
                terminalTTY: "/dev/ttys001"
            )
        )

        XCTAssertTrue(matches)
    }

    func testMatchesITermFrontmostSessionByTTYFallback() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { "com.googlecode.iterm2" },
            appleScriptRunner: { _ in "different-session\u{1f}/dev/ttys002" }
        )

        let matches = await probe.matches(
            jumpTarget: JumpTarget(
                terminalApp: "iTerm",
                workspaceName: "agent-island",
                paneTitle: "codex ~/agent-island",
                terminalSessionID: "tracked-session",
                terminalTTY: "/dev/ttys002"
            )
        )

        XCTAssertTrue(matches)
    }

    func testReturnsFalseForUnsupportedFrontmostApp() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { "com.example.Editor" },
            appleScriptRunner: { _ in "" }
        )

        let matches = await probe.matches(
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "codex ~/agent-island",
                terminalSessionID: "ghostty-frontmost"
            )
        )

        XCTAssertFalse(matches)
    }
}
