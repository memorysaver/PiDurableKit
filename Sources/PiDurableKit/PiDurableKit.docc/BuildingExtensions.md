# Building Extensions

Tools, prompt sections, hooks, wraps, and durable tasks, bundled under a name.

## Overview

An ``Extension`` is pi-durable's unit of behavior. Install extensions when opening a harness, or later with
``Harness/install(_:)``; a conversation selects extensions by name (by default every installed one) and can change its
selection with ``AgentChange``.

```swift
let assistant = Extension("assistant") {
    PromptSection("preamble", tag: false, text: "You are a concise assistant on an iPhone.")
    Tool("get_weather", description: "Weather in a city", parameters: .object(["city": .string("City")])) {
        (arguments: Weather, call) in "Sunny in \(arguments.city)"
    }
    Hook.beforeTool { call, _ in call.name == "delete_note" ? .block("Needs approval") : .allow }
}
```

## Tools

Each tool call runs as its own durable task. ``ToolCallContext`` is pi-durable's tool API: stream output, report
details and diagnostics, commit transactions, create and await tasks, drive other conversations (subagents), keep memos
that survive reruns, and read or watch documents.

## Hooks and wraps

``Hook`` observes or adjusts the built-in generation, tool, and compaction tasks, and your own task types. ``Wrap``
decorates a tool or section of any extension by name.

## Approval gates and signals

A ``Hook/beforeTool(_:)`` gate can park a call until a person answers: return ``ToolDecision/sleep(signals:until:)``
with the key of a ``Signal``. The call holds no process meanwhile and survives a restart; its slot is
``LiveState/ToolSlot/Status/sleeping``, and ``ConversationView/parkedCalls`` lists it with its task and the
``SignalKey``s it waits for. Deliver the answer with ``Harness/signal(taskId:_:key:value:)``, which answers a
``SignalResult``. Every wake runs the gates again, so the gate reads the answer with
``HookContext/readSignal(_:key:)`` and allows the call or blocks it:

```swift
let approval = Signal<Decision>("app.approval", version: 1, schema: .object(["allow": .boolean]))

Hook.beforeTool { call, context in
    guard call.name == "write" else { return .allow }
    switch try await context.readSignal(approval, key: call.id) {
    case nil: return .sleep(signals: [approval.key(call.id)])
    case .expired?: return .block("No answer in time")
    case .value(let decision)?: return decision.allow ? .allow : .block("Declined by the owner")
    }
}

// Where the question is shown:
try await harness.signal(taskId: parked.taskId, approval, key: parked.callId, value: Decision(allow: true))
```
