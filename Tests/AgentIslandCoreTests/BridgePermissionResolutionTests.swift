import Foundation
import Testing
@testable import AgentIslandCore

@Suite(.serialized)
struct BridgePermissionResolutionTests {
    @Test
    func replacedAndReplayedPermissionIdentitiesFailClosed() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))
        var iterator = stream.makeAsyncIterator()

        let firstHook = LocalBridgeClient(socketURL: socketURL)
        let firstHookStream = try firstHook.connect()
        defer { firstHook.disconnect() }
        _ = firstHookStream
        try await firstHook.send(
            .processCodexHook(
                codexPermissionPayload(
                    sessionID: "replaced-permission",
                    toolUseID: "first"
                )
            )
        )
        let firstRequest = try await nextPermissionRequest(from: &iterator)

        let replacementHook = LocalBridgeClient(socketURL: socketURL)
        let replacementHookStream = try replacementHook.connect()
        defer { replacementHook.disconnect() }
        _ = replacementHookStream
        try await replacementHook.send(
            .processCodexHook(
                codexPermissionPayload(
                    sessionID: "replaced-permission",
                    toolUseID: "replacement"
                )
            )
        )
        let replacementRequest =
            try await nextPermissionRequest(from: &iterator)

        #expect(firstRequest.id != replacementRequest.id)
        #expect(
            server.resolvePermission(
                sessionID: "replaced-permission",
                requestID: firstRequest.id,
                resolution: .allowOnce()
            ) == .requestIdentityMismatch
        )
        #expect(
            server.resolvePermission(
                sessionID: "replaced-permission",
                requestID: replacementRequest.id,
                resolution: .allowOnce()
            ) == .resolved
        )
        #expect(
            server.resolvePermission(
                sessionID: "replaced-permission",
                requestID: replacementRequest.id,
                resolution: .allowOnce()
            ) == .requestNotActive
        )
    }

    @Test
    func questionCannotBeResolvedAsPermission() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))
        var iterator = stream.makeAsyncIterator()

        let hook = LocalBridgeClient(socketURL: socketURL)
        let hookStream = try hook.connect()
        defer { hook.disconnect() }
        _ = hookStream
        try await hook.send(
            .processClaudeHook(
                ClaudeHookPayload(
                    cwd: "/tmp/worktree",
                    hookEventName: .permissionRequest,
                    sessionID: "question-session",
                    toolName: "AskUserQuestion",
                    toolInput: .object([
                        "questions": .array([
                            .object([
                                "question": .string("Which environment?"),
                                "header": .string("Environment"),
                                "options": .array([
                                    .object([
                                        "label": .string("Staging"),
                                        "description": .string(
                                            "Use staging"
                                        ),
                                    ]),
                                ]),
                                "multiSelect": .boolean(false),
                            ]),
                        ]),
                    ])
                )
            )
        )
        let prompt = try await nextQuestionPrompt(from: &iterator)

        #expect(
            server.resolvePermission(
                sessionID: "question-session",
                requestID: prompt.id,
                resolution: .allowOnce()
            ) == .notPermissionRequest
        )

        try await observer.send(
            .answerQuestion(
                sessionID: "question-session",
                response: QuestionPromptResponse(answer: "Staging")
            )
        )
    }

    @Test
    func disconnectedHookMakesPermissionIdentityInactive() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))
        var iterator = stream.makeAsyncIterator()

        let hook = LocalBridgeClient(socketURL: socketURL)
        let hookStream = try hook.connect()
        _ = hookStream
        try await hook.send(
            .processCodexHook(
                codexPermissionPayload(
                    sessionID: "disconnected-permission",
                    toolUseID: "disconnect"
                )
            )
        )
        let request = try await nextPermissionRequest(from: &iterator)
        hook.disconnect()
        _ = try await nextActionableResolution(from: &iterator)

        #expect(
            server.resolvePermission(
                sessionID: "disconnected-permission",
                requestID: request.id,
                resolution: .allowOnce()
            ) == .requestNotActive
        )
    }

    private func codexPermissionPayload(
        sessionID: String,
        toolUseID: String
    ) -> CodexHookPayload {
        CodexHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .permissionRequest,
            model: "gpt-5-codex",
            permissionMode: .default,
            sessionID: sessionID,
            transcriptPath: nil,
            turnID: "turn-\(toolUseID)",
            toolName: "apply_patch",
            toolUseID: toolUseID,
            toolInput: CodexHookToolInput(
                description: "Apply \(toolUseID) patch"
            )
        )
    }
}

private enum BridgePermissionResolutionTestError: Error {
    case streamEnded
    case matchingEventNotFound
}

private func nextPermissionRequest(
    from iterator: inout AsyncThrowingStream<
        AgentEvent,
        Error
    >.AsyncIterator
) async throws -> PermissionRequest {
    for _ in 0..<12 {
        guard let event = try await iterator.next() else {
            throw BridgePermissionResolutionTestError.streamEnded
        }
        if case let .permissionRequested(payload) = event {
            return payload.request
        }
    }
    throw BridgePermissionResolutionTestError.matchingEventNotFound
}

private func nextQuestionPrompt(
    from iterator: inout AsyncThrowingStream<
        AgentEvent,
        Error
    >.AsyncIterator
) async throws -> QuestionPrompt {
    for _ in 0..<12 {
        guard let event = try await iterator.next() else {
            throw BridgePermissionResolutionTestError.streamEnded
        }
        if case let .questionAsked(payload) = event {
            return payload.prompt
        }
    }
    throw BridgePermissionResolutionTestError.matchingEventNotFound
}

private func nextActionableResolution(
    from iterator: inout AsyncThrowingStream<
        AgentEvent,
        Error
    >.AsyncIterator
) async throws -> ActionableStateResolved {
    for _ in 0..<12 {
        guard let event = try await iterator.next() else {
            throw BridgePermissionResolutionTestError.streamEnded
        }
        if case let .actionableStateResolved(payload) = event {
            return payload
        }
    }
    throw BridgePermissionResolutionTestError.matchingEventNotFound
}
