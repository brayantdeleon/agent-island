import Testing
@testable import AgentIslandApp

struct CompletionMessageSanitizerTests {
    @Test
    func stripsConsecutiveCodexControlDirectives() {
        let source = """
Changes are merged into your repository.

::git-push{cwd="/repo" branch="fix/directives"}
::git-create-pr{cwd="/repo" branch="fix/directives" url="https://example.com/pr/2" isDraft=false}
"""

        #expect(CompletionMessageSanitizer.textForDisplay(source) == "Changes are merged into your repository.")
    }

    @Test
    func stripsOtherStandaloneCodexDirectives() {
        let source = """
Done.
::created-thread{threadId="thread-123"}
::code-comment{title="Review" body="Fix this." file="/repo/App.swift" start=12 priority=2}
"""

        #expect(CompletionMessageSanitizer.textForDisplay(source) == "Done.")
    }

    @Test
    func preservesDirectiveExamplesInsideCodeFences() {
        let source = """
Example:
```text
::git-push{cwd="/repo" branch="main"}
```
"""

        #expect(CompletionMessageSanitizer.textForDisplay(source) == source)
    }

    @Test
    func preservesInlineAndIndentedDirectiveExamples() {
        let source = "Use `::git-push{...}` in Codex.\n    ::git-push{cwd=\"/example\"}"

        #expect(CompletionMessageSanitizer.textForDisplay(source) == source)
    }

    @Test
    func returnsEmptyTextWhenMessageContainsOnlyDirectives() {
        let source = "::git-commit{cwd=\"/repo\"}\n::git-push{cwd=\"/repo\" branch=\"main\"}"

        #expect(CompletionMessageSanitizer.textForDisplay(source).isEmpty)
    }
}

struct CompletionMessageParserTests {
    @Test
    func leavesPlainMarkdownUntouched() {
        let source = "Implemented **three fixes** and updated `price = $5`."

        #expect(CompletionMessageParser.segments(in: source) == [.markdown(source)])
    }

    @Test
    func extractsInlineAndDisplayMath() {
        let source = "Euler wrote $e^{i\\pi} + 1 = 0$.\n\n$$\\int_0^1 x^2 dx$$"

        #expect(CompletionMessageParser.segments(in: source) == [
            .markdown("Euler wrote "),
            .math("e^{i\\pi} + 1 = 0", display: false),
            .markdown(".\n\n"),
            .math("\\int_0^1 x^2 dx", display: true),
        ])
    }

    @Test
    func supportsLatexStyleDelimiters() {
        let source = "Solve \\(x^2 = 4\\), then show:\n\\[x = \\pm 2\\]"

        #expect(CompletionMessageParser.segments(in: source) == [
            .markdown("Solve "),
            .math("x^2 = 4", display: false),
            .markdown(", then show:\n"),
            .math("x = \\pm 2", display: true),
        ])
    }

    @Test
    func supportsMathCodeFences() {
        let source = "Result:\n```math\n\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}\n```\nDone."

        #expect(CompletionMessageParser.segments(in: source) == [
            .markdown("Result:\n"),
            .math("\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", display: true),
            .markdown("\nDone."),
        ])
    }

    @Test
    func ignoresMathDelimitersInsideCodeAndEscapedDollars() {
        let source = "Use `$x$`, then:\n```swift\nlet value = \"$$x$$\"\n```\nCost: \\$5"

        #expect(CompletionMessageParser.segments(in: source) == [.markdown(source)])
    }

    @Test
    func leavesMalformedAndMultilineInlineMathUntouched() {
        let source = "Unclosed $x and invalid $x\ny$ remain prose."

        #expect(CompletionMessageParser.segments(in: source) == [.markdown(source)])
    }

    @Test
    func keepsMarkdownTableWholeWhenCellsContainLatex() {
        let source = """
| Metric | Formula |
|:---|---:|
| Circle area | $\\pi r^2$ |
| Growth | $e^{rt}$ |

Outside the table: $$\\int_0^1 x^2 dx$$
"""

        #expect(CompletionMessageParser.segments(in: source) == [
            .markdown("""
| Metric | Formula |
|:---|---:|
| Circle area | $\\pi r^2$ |
| Growth | $e^{rt}$ |

Outside the table:
""" + " "),
            .math("\\int_0^1 x^2 dx", display: true),
        ])
    }
}
