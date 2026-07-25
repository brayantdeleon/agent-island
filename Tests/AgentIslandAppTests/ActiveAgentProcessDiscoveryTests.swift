import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

struct ActiveAgentProcessDiscoveryTests {
    @Test
    func discoverOnlyReturnsInteractiveClaudeAndCodexProcesses() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  101 1 ?? /Users/test/.local/bin/claude --resume abc
                  102 301 ttys002 claude
                  201 1 ttys000 node /Users/test/.nvm/versions/node/v22/bin/codex
                  202 401 ttys001 /Users/test/.nvm/versions/node/v22/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex
                  301 900 ttys002 -/opt/homebrew/bin/fish
                  401 900 ttys001 -/opt/homebrew/bin/fish
                  900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
                """
            }

            guard executablePath == "/usr/sbin/lsof",
                  let pid = arguments.dropFirst(2).first else {
                return nil
            }

            switch pid {
            case "102":
                return """
                fcwd
                n/tmp/agent-island
                """
            case "202":
                return """
                fcwd
                n/tmp/agent-island
                n/Users/test/.codex/sessions/2026/04/03/rollout-2026-04-03T11-42-31-019d516f-71ee-7e40-bcff-502fedac0928.jsonl
                """
            default:
                Issue.record("unexpected lsof lookup for pid \(pid)")
                return nil
            }
        }

        let snapshots = discovery.discover()

        #expect(snapshots.count == 2)
        #expect(snapshots.contains(.init(
            tool: .claudeCode,
            sessionID: nil,
            workingDirectory: "/tmp/agent-island",
            terminalTTY: "/dev/ttys002",
            terminalApp: "Ghostty"
        )))
        #expect(snapshots.contains(.init(
            tool: .codex,
            sessionID: "019d516f-71ee-7e40-bcff-502fedac0928",
            workingDirectory: "/tmp/agent-island",
            terminalTTY: "/dev/ttys001",
            terminalApp: "Ghostty"
        )))
    }

    @Test
    func discoverClaudeSessionIDFromResumeFlagWhenTranscriptIsNotOpen() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, _ in
            if executablePath == "/bin/ps" {
                return """
                  102 301 ttys002 /Users/test/.local/bin/claude --resume 9df061a9-6836-4ccb-b83b-aea3196eca43 --permission-mode acceptEdits
                  301 900 ttys002 -/opt/homebrew/bin/fish
                  900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
                """
            }

            guard executablePath == "/usr/sbin/lsof" else {
                return nil
            }

            return """
            fcwd
            n/tmp/agent-island
            """
        }

        let snapshots = discovery.discover()

        #expect(snapshots == [
            .init(
                tool: .claudeCode,
                sessionID: "9df061a9-6836-4ccb-b83b-aea3196eca43",
                workingDirectory: "/tmp/agent-island",
                terminalTTY: "/dev/ttys002",
                terminalApp: "Ghostty"
            ),
        ])
    }

    @Test
    func codexDiscoveryUsesNewestOpenRolloutWhenProcessKeepsOldDescriptors() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  202 401 ttys001 /opt/homebrew/bin/codex
                  401 900 ttys001 -/opt/homebrew/bin/fish
                  900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
                """
            }

            guard executablePath == "/usr/sbin/lsof",
                  let pid = arguments.dropFirst(2).first else {
                return nil
            }

            guard pid == "202" else {
                Issue.record("unexpected lsof lookup for pid \(pid)")
                return nil
            }

            return """
            fcwd
            n/tmp/agent-island
            n/Users/test/.codex/sessions/2026/05/10/rollout-2026-05-10T01-04-52-019e0db2-f3a5-7fe0-bea8-e63bd356c226.jsonl
            n/Users/test/.codex/sessions/2026/05/10/rollout-2026-05-10T01-20-29-019e0dc1-3f8b-7eb0-ae8d-04a5911e95b9.jsonl
            """
        }

        let snapshots = discovery.discover()

        #expect(snapshots == [
            .init(
                tool: .codex,
                sessionID: "019e0dc1-3f8b-7eb0-ae8d-04a5911e95b9",
                workingDirectory: "/tmp/agent-island",
                terminalTTY: "/dev/ttys001",
                terminalApp: "Ghostty"
            ),
        ])
    }

    @Test
    func discoverCursorAgentProcessFromOpenChatStore() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  302 401 ttys003 /Users/test/.local/bin/cursor-agent --use-system-ca /Users/test/.local/share/cursor-agent/versions/2026.06.26/index.js
                  401 500 ttys003 -/opt/homebrew/bin/fish
                  500 900 ttys003 /usr/bin/login -flp test /bin/bash --noprofile --norc -c exec -l /opt/homebrew/bin/fish
                  900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
                """
            }

            guard executablePath == "/usr/sbin/lsof",
                  let pid = arguments.dropFirst(2).first else {
                return nil
            }

            guard pid == "302" else {
                Issue.record("unexpected lsof lookup for pid \(pid)")
                return nil
            }

            return """
            fcwd
            n/tmp/simple-agent-lab
            n/Users/test/.cursor/chats/cf595f65441221b71014fd6f7b9999b2/6f7b9f8a-2bd0-48b4-a497-9801dd191d03/store.db-shm
            """
        }

        let snapshots = discovery.discover()

        #expect(snapshots == [
            .init(
                tool: .cursor,
                sessionID: "6f7b9f8a-2bd0-48b4-a497-9801dd191d03",
                workingDirectory: "/tmp/simple-agent-lab",
                terminalTTY: "/dev/ttys003",
                terminalApp: "Ghostty"
            ),
        ])
    }

    @Test
    func discoverCursorAgentDeduplicatesProcessesForSameConversation() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  302 401 ttys003 /Users/test/.local/bin/cursor-agent --use-system-ca /Users/test/.local/share/cursor-agent/versions/2026.06.26/index.js
                  303 402 ttys004 /Users/test/.local/bin/cursor-agent --use-system-ca /Users/test/.local/share/cursor-agent/versions/2026.06.26/index.js
                  401 900 ttys003 -/opt/homebrew/bin/fish
                  402 900 ttys004 -/opt/homebrew/bin/fish
                  900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
                """
            }

            guard executablePath == "/usr/sbin/lsof",
                  let pid = arguments.dropFirst(2).first else {
                return nil
            }

            guard pid == "302" || pid == "303" else {
                Issue.record("unexpected lsof lookup for pid \(pid)")
                return nil
            }

            return """
            fcwd
            n/tmp/simple-agent-lab
            n/Users/test/.cursor/chats/cf595f65441221b71014fd6f7b9999b2/6f7b9f8a-2bd0-48b4-a497-9801dd191d03/store.db
            """
        }

        let snapshots = discovery.discover()

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.sessionID == "6f7b9f8a-2bd0-48b4-a497-9801dd191d03")
    }

    /// VS Code forks (Cursor, Windsurf, Trae, Qoder) bundle Electron's "Code
    /// Helper" inside their .app bundles. Their helper paths therefore contain
    /// both "/<fork>.app/" and "/code helper", and Agent-Island used to match
    /// the broad "/code helper" check first → mis-attributed every fork to
    /// stock VS Code (#415). Verify each fork is recognized correctly.
    @Test(arguments: [
        ("/Applications/Cursor.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "Cursor"),
        ("/Applications/Windsurf.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "Windsurf"),
        ("/Applications/Trae.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "Trae"),
        ("/Applications/Qoder.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "Qoder"),
        ("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "VS Code"),
    ])
    func recognizesVSCodeForkBeforeFallingBackToVSCode(parentCommand: String, expectedTerminal: String) {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  102 301 ttys002 /Users/test/.local/bin/claude
                  301 900 ttys002 -/opt/homebrew/bin/fish
                  900 1 ?? \(parentCommand)
                """
            }
            guard executablePath == "/usr/sbin/lsof" else {
                return nil
            }
            return """
            fcwd
            n/tmp/agent-island
            """
        }

        let snapshots = discovery.discover()

        #expect(snapshots == [
            .init(
                tool: .claudeCode,
                sessionID: nil,
                workingDirectory: "/tmp/agent-island",
                terminalTTY: "/dev/ttys002",
                terminalApp: expectedTerminal
            ),
        ])
    }

    @Test
    func discoverDetectsOpenCodeProcessWithoutTTY() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  102 1 ?? opencode
                """
            }

            guard executablePath == "/usr/sbin/lsof",
                  let pid = arguments.dropFirst(2).first else {
                return nil
            }

            switch pid {
            case "102":
                return """
                fcwd
                n/tmp/agent-island
                """
            default:
                Issue.record("unexpected lsof lookup for pid \(pid)")
                return nil
            }
        }

        let snapshots = discovery.discover()

        let openCodeSnapshots = snapshots.filter { $0.tool == .openCode }
        #expect(openCodeSnapshots.count == 1)
        #expect(openCodeSnapshots.first?.workingDirectory == "/tmp/agent-island")
        #expect(openCodeSnapshots.first?.terminalTTY == nil)
    }

    // MARK: - Claude Desktop ("local agent mode")

    /// Command lines taken verbatim from a live Claude Desktop session. Both
    /// the wrapper and the real CLI are TTY-less, and the binary path contains
    /// a space ("Application Support"), which is what the old first-token
    /// matcher could never handle.
    private static let claudeDesktopPS = """
      13866 76267 ?? /Applications/Claude.app/Contents/Helpers/disclaimer /Users/test/Library/Application Support/Claude/claude-code/2.1.219/claude.app/Contents/MacOS/claude --output-format stream-json --model claude-opus-5
      13867 13866 ?? /Users/test/Library/Application Support/Claude/claude-code/2.1.219/claude.app/Contents/MacOS/claude --output-format stream-json --model claude-opus-5
      76267 1 ?? /Applications/Claude.app/Contents/MacOS/Claude
    """

    @Test
    func discoverFindsTTYLessClaudeDesktopProcess() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" { return Self.claudeDesktopPS }
            guard executablePath == "/usr/sbin/lsof",
                  let pid = arguments.dropFirst(2).first else { return nil }
            // Claude Desktop holds no transcript descriptor — only its cwd.
            switch pid {
            case "13867":
                return """
                fcwd
                n/tmp/agent-island
                """
            default:
                Issue.record("unexpected lsof lookup for pid \(pid)")
                return nil
            }
        }

        let snapshots = discovery.discover()

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.tool == .claudeCode)
        #expect(snapshots.first?.workingDirectory == "/tmp/agent-island")
        #expect(snapshots.first?.terminalTTY == nil)
        // The gate in ProcessMonitoringCoordinator keys on this exact tag.
        #expect(snapshots.first?.terminalApp == "Claude.app")
        // No per-conversation identity is recoverable from the process.
        #expect(snapshots.first?.sessionID == nil)
        #expect(snapshots.first?.transcriptPath == nil)
    }

    /// The disclaimer shim re-execs its child with an identical command line;
    /// only the leaf holds the agent's descriptors.
    @Test
    func discoverSuppressesClaudeDesktopDisclaimerWrapper() {
        // Give the wrapper and the leaf different cwds so a snapshot from
        // either is distinguishable in the result.
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" { return Self.claudeDesktopPS }
            guard executablePath == "/usr/sbin/lsof",
                  let pid = arguments.dropFirst(2).first else { return nil }
            return """
            fcwd
            n/tmp/\(pid == "13866" ? "wrapper" : "leaf")
            """
        }

        let snapshots = discovery.discover()

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.workingDirectory == "/tmp/leaf")
    }

    /// The TTY gate exists to keep headless invocations out of the island, and
    /// only Claude Desktop is exempted. A TTY-less `~/.local/bin/claude`
    /// (a scripted `claude -p`, an MCP child, CI) must still be skipped.
    @Test
    func discoverStillSkipsTTYLessTerminalClaude() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, _ in
            if executablePath == "/bin/ps" {
                return "  101 1 ?? /Users/test/.local/bin/claude --resume abc"
            }
            return nil
        }

        #expect(discovery.discover().isEmpty)
    }

    @Test
    func discoverSkipsTTYLessClaudeDesktopSubagentWorktree() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" { return Self.claudeDesktopPS }
            guard executablePath == "/usr/sbin/lsof",
                  arguments.dropFirst(2).first != nil else { return nil }
            return """
            fcwd
            n/tmp/agent-island/.claude/worktrees/agent-abc
            """
        }

        #expect(discovery.discover().isEmpty)
    }

    // MARK: - Binary paths containing spaces

    @Test
    func discoverMatchesBinaryPathsContainingSpaces() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  201 301 ttys001 /Users/John Smith/.local/bin/codex
                  301 900 ttys001 -/opt/homebrew/bin/fish
                  900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
                """
            }
            guard executablePath == "/usr/sbin/lsof",
                  arguments.dropFirst(2).first != nil else { return nil }
            return """
            fcwd
            n/tmp/agent-island
            n/Users/John Smith/.codex/sessions/2026/04/03/rollout-2026-04-03T11-42-31-019d516f-71ee-7e40-bcff-502fedac0928.jsonl
            """
        }

        let snapshots = discovery.discover()
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.tool == .codex)
        #expect(snapshots.first?.sessionID == "019d516f-71ee-7e40-bcff-502fedac0928")
    }

    /// Agent-Island's own hook binary names the agent it reports for. Matching
    /// a bare name anywhere in the command line would classify it as an agent.
    @Test
    func discoverDoesNotClassifyHooksBinaryAsAgent() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, _ in
            if executablePath == "/bin/ps" {
                return """
                  101 301 ttys001 /Users/test/Library/Application Support/AgentIsland/bin/AgentIslandHooks --source claude
                  301 900 ttys001 -/opt/homebrew/bin/fish
                """
            }
            return nil
        }

        #expect(discovery.discover().isEmpty)
    }

    /// An interpreter plus a script path is the same session as the real
    /// binary, not a second one.
    @Test
    func discoverDoesNotTreatInterpreterPlusScriptAsSeparateAgent() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, _ in
            if executablePath == "/bin/ps" {
                return """
                  201 301 ttys001 node /Users/test/.nvm/versions/node/v22/bin/codex
                  301 900 ttys001 -/opt/homebrew/bin/fish
                """
            }
            return nil
        }

        #expect(discovery.discover().isEmpty)
    }

    @Test
    func discoverDoesNotClassifyKimiAuxiliaryBinaries() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, _ in
            if executablePath == "/bin/ps" {
                return """
                  101 301 ttys001 /opt/homebrew/bin/kimi-info
                  102 301 ttys001 /opt/homebrew/bin/kimi-mcp
                  301 900 ttys001 -/opt/homebrew/bin/fish
                """
            }
            return nil
        }

        #expect(discovery.discover().isEmpty)
    }
}
