import Foundation
import os
import Testing
@testable import PiDurableKit

/// The owner's answer to a parked write.
private struct Decision: Codable, Sendable, Equatable {
    var allow: Bool
}

private let approval = Signal<Decision>("test.approval", version: 1, schema: .object(["allow": .boolean]))

private struct GateNote: Codable, Sendable { var text: String }

/// A write tool behind an approval gate keyed by the call's ID, as pi-durable's example 44 keys by the arguments.
private final class Gated: Sendable {
    let runs = OSAllocatedUnfairLock<[String]>(initialState: [])
    let wakes = OSAllocatedUnfairLock<[WakeReason?]>(initialState: [])
    let clock = OSAllocatedUnfairLock<[Date]>(initialState: [])
    /// While false, the tool holds its call open after it starts, so the call's task is still live.
    let released = OSAllocatedUnfairLock<Bool>(initialState: true)

    var `extension`: Extension {
        let runs = runs, wakes = wakes, clock = clock, released = released
        let write = Tool("write_note", description: "Write a note", parameters: .object(["text": .string("The note")])) {
            (note: GateNote, _) -> String in
            runs.withLock { $0.append(note.text) }
            while !released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
            return "Wrote \(note.text)"
        }
        return Extension("approvals") {
            write
            Hook.beforeTool { call, context in
                guard call.name == "write_note" else { return .allow }
                wakes.withLock { $0.append(nil) }
                let wake = try await context.wake()
                wakes.withLock { $0[$0.count - 1] = wake }
                clock.withLock { $0.append(Date()) }
                _ = try await context.now()
                switch try await context.readSignal(approval, key: call.id) {
                case nil: return .sleep(signals: [approval.key(call.id)])
                case .expired?: return .block("No answer in time")
                case .value(let decision)?: return decision.allow ? .allow : .block("Declined by the owner")
                }
            }
        }
    }
}

/// The first parked call of the conversation's views.
private func parked(_ conversation: Conversation) async throws -> ParkedToolCall {
    try await withTimeout(30) {
        for try await view in conversation.views() {
            if let call = view.parkedCalls.first { return call }
        }
        throw TimeoutError()
    }
}

@Suite struct GateSignalTests {
    @Test func anApprovedCallRunsOnceAndASecondSignalIsADuplicate() async throws {
        let gated = Gated()
        let setup = try await FauxSetup.make(extensions: [gated.extension])
        try await setup.faux.append(.toolCall("write_note", ["text": "hello"]))
        try await setup.faux.append(.text("Written."))
        let root = try await setup.root()
        let submission = try await root.submit("Write hello")

        let call = try await parked(root)
        #expect(gated.runs.withLock { $0 } == [])
        #expect(call.status == .sleeping)
        #expect(call.signals == [approval.key(call.callId)])

        gated.released.withLock { $0 = false }
        #expect(try await setup.harness.signal(taskId: call.taskId, approval, key: call.callId, value: Decision(allow: true)) == .delivered)
        try await eventually(30) { gated.runs.withLock { $0 } == ["hello"] }
        // The key holds a value and the call's task is live: a retried tap is a duplicate.
        #expect(try await setup.harness.signal(taskId: call.taskId, approval, key: call.callId, value: Decision(allow: true)) == .duplicate)
        gated.released.withLock { $0 = true }

        let answer = try await withTimeout(30) { try await answer(of: submission) }
        #expect(answer.text == "Written.")
        #expect(gated.runs.withLock { $0 } == ["hello"])
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError == false)
        #expect(result.text == "Wrote hello")
        // The gate ran on the first pass, then again on the signal's wake.
        #expect(gated.wakes.withLock { $0 } == [nil, .signal(signal: approval.name, key: call.callId)])
        // Once the call ended, a signal to it is closed.
        #expect(try await setup.harness.signal(taskId: call.taskId, approval, key: call.callId, value: Decision(allow: true)) == .closed)
        #expect(try await setup.harness.signal(taskId: 999_999, approval, key: "x", value: Decision(allow: true)) == .notFound)
        try await setup.harness.close()
    }

    @Test func aDeclinedCallEndsWithoutRunningAndTheModelSeesWhy() async throws {
        let gated = Gated()
        let setup = try await FauxSetup.make(extensions: [gated.extension])
        try await setup.faux.append(.toolCall("write_note", ["text": "secret"]))
        try await setup.faux.append(.text("Understood."))
        let root = try await setup.root()
        let submission = try await root.submit("Write secret")

        let call = try await parked(root)
        // A value that does not match the schema is refused and leaves the key free.
        let untyped = Signal<JSONValue>(approval.name, schema: approval.schema)
        #expect(try await setup.harness.signal(taskId: call.taskId, untyped, key: call.callId, value: ["allow": "yes"]) == .invalid)
        #expect(try await setup.harness.signal(taskId: call.taskId, approval, key: call.callId, value: Decision(allow: false)) == .delivered)
        _ = try await withTimeout(30) { try await answer(of: submission) }

        #expect(gated.runs.withLock { $0 } == [])
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError)
        #expect(result.text.contains("Declined by the owner"))
        // The result is in the model's context.
        let context = try await root.context()
        #expect(context.messages.contains { message in
            if case .toolResult(let result) = message { return result.text.contains("Declined by the owner") }
            return false
        })
        try await setup.harness.close()
    }

    @Test func aParkedCallSurvivesAReopenAndRunsOnceOnApproval() async throws {
        let gated = Gated()
        let url = temporaryDirectory().appending(path: "gates.sqlite")
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        var harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [gated.extension])
        try await faux.append(.toolCall("write_note", ["text": "durable"]))
        try await faux.append(.text("Saved."))
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        let submission = try await root.submit("Write durable")
        let call = try await parked(root)
        try await harness.close()
        #expect(gated.runs.withLock { $0 } == [])

        harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [gated.extension])
        let reopened = try await harness.root()
        // The reopen runs the gate again; it parks on the same key, which served no wait yet.
        let again = try await parked(reopened)
        #expect(again.taskId == call.taskId)
        #expect(again.signals == [approval.key(call.callId)])
        // The reopen ran the gate a second time, which parked again without a wake reason.
        try await eventually(30) { gated.wakes.withLock { $0 } == [nil, nil] }
        #expect(gated.runs.withLock { $0 } == [])

        #expect(try await harness.signal(taskId: again.taskId, approval, key: again.callId, value: Decision(allow: true)) == .delivered)
        let reopenedHarness = harness
        let settled = try await withTimeout(30) { try await reopenedHarness.submission(submission.id)!.wait() }
        guard case .done = settled.status else { throw Unanswered(record: settled) }
        #expect(gated.runs.withLock { $0 } == ["durable"])
        let result = try #require(try await reopened.view().entries.compactMap(\.toolResult).first)
        #expect(result.text == "Wrote durable")
        try await harness.close()
    }

    @Test func theParkedCallIsInTheViewWithItsKeysAndTask() async throws {
        let gated = Gated()
        let setup = try await FauxSetup.make(extensions: [gated.extension])
        try await setup.faux.append(.toolCall("write_note", ["text": "shown"]))
        try await setup.faux.append(.text("Done."))
        let root = try await setup.root()
        let submission = try await root.submit("Write shown")

        let call = try await parked(root)
        let view = try await root.view()
        let slot = try #require(view.live.tools.first)
        #expect(slot.status == .sleeping)
        #expect(slot.name == "write_note")
        let parkedCall = try #require(view.parkedCalls.first)
        #expect(parkedCall == call)
        #expect(parkedCall.callId == slot.callId)
        #expect(parkedCall.taskId == slot.taskId)
        #expect(parkedCall.name == "write_note")
        #expect(parkedCall.signals == [SignalKey(signal: "test.approval", key: slot.callId)])
        #expect(parkedCall.until == nil)
        #expect(parkedCall.parentCallId == nil)
        // The same, from the task record.
        let record = try #require(try await setup.harness.task(call.taskId))
        #expect(record.kind == "pi.tool")
        #expect(record.status == .sleeping(until: nil))
        #expect(record.signals == call.signals)
        // A parked call holds no process.
        #expect(view.isBusy)

        #expect(try await setup.harness.signal(taskId: call.taskId, approval, key: call.callId, value: Decision(allow: true)) == .delivered)
        _ = try await withTimeout(30) { try await answer(of: submission) }
        #expect(try await root.view().parkedCalls.isEmpty)
        try await setup.harness.close()
    }

    @Test func aDeadlineExpiresTheGate() async throws {
        let expiring = Extension("expiring") {
            Tool("write_note", description: "Write a note", parameters: .object(["text": .string])) { (_: GateNote, _) in "written" }
            Hook.beforeTool { call, context in
                let now = try await context.now()
                let until = try await context.memo("until.\(call.id)", default: now.addingTimeInterval(0.2))
                switch try await context.readSignal(approval, key: call.id) {
                case nil: return .sleep(signals: [approval.key(call.id)], until: until)
                case .expired?: return .block("No answer in time (\(try await context.wake().map { "\($0)" } ?? "none"))")
                case .value?: return .allow
                }
            }
        }
        let setup = try await FauxSetup.make(extensions: [expiring])
        try await setup.faux.append(.toolCall("write_note", ["text": "late"]))
        try await setup.faux.append(.text("Too late."))
        let root = try await setup.root()
        _ = try await withTimeout(30) { try await ask(root, "Write late") }
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError)
        #expect(result.text.contains("No answer in time (expired)"), "\(result.text)")
        try await setup.harness.close()
    }

    @Test func abortingAParkedCallEndsItWithoutRunning() async throws {
        let gated = Gated()
        let setup = try await FauxSetup.make(extensions: [gated.extension])
        try await setup.faux.append(.toolCall("write_note", ["text": "never"]))
        let root = try await setup.root()
        let submission = try await root.submit("Write never")
        let call = try await parked(root)

        try await root.abort()
        try await withTimeout(30) { try await root.waitForIdle() }
        let settled = try await submission.wait()
        #expect(gated.runs.withLock { $0 } == [])
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError)
        #expect(try await setup.harness.signal(taskId: call.taskId, approval, key: call.callId, value: Decision(allow: true)) == .closed)
        #expect(try await root.view().parkedCalls.isEmpty)
        #expect("\(settled.status)".contains("aborted"), "\(settled.status)")
        try await setup.harness.close()
    }
}
