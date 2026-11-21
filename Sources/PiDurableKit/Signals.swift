import Foundation

/// A kind of signal: a typed JSON value delivered to a live task from outside, such as a person's answer or a
/// webhook's result (pi-durable `defineSignal`).
///
/// A task, or a ``Hook/beforeTool(_:)`` gate, sleeps on one of the signal's keys and holds no process meanwhile;
/// ``Harness/signal(taskId:_:key:value:)`` delivers a value under the key, which wakes it. The definition is data: the
/// same name, version, and schema define the same signal in every process, so define it once (a `static let`) and use it
/// both where the gate sleeps and where the answer is delivered. Nothing needs to be installed.
///
/// ```swift
/// struct Decision: Codable, Sendable { var allow: Bool }
/// let approval = Signal<Decision>("app.approval", version: 1, schema: .object(["allow": .boolean]))
/// ```
public struct Signal<Value: Codable & Sendable>: Sendable, Hashable {
    /// Unique like a task or document kind; must not contain `/`.
    public let name: String
    /// The positive integer version of the value's shape. A value stored by an older version can't be read without a
    /// migration, which PiDurableKit does not offer yet: a new shape gets a new signal name.
    public let version: Int
    /// The JSON schema delivered values must match (pi-durable checks every delivery against it).
    public let schema: JSONSchema

    public init(_ name: String, version: Int = 1, schema: JSONSchema) {
        self.name = name
        self.version = version
        self.schema = schema
    }

    /// The key of one wait for this signal (pi-durable `token.key(key)`). A key serves one wait: the wake that uses it
    /// consumes it, so a second wait needs another key.
    public func key(_ key: String) -> SignalKey {
        SignalKey(signal: name, key: key)
    }

    var specification: BridgeArguments {
        ["name": name, "version": version, "schema": schema]
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.version == rhs.version && lhs.schema == rhs.schema
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(version)
    }
}

/// The key of one wait for a signal (pi-durable `SignalKey`): the signal's name and the key within it.
public struct SignalKey: Codable, Sendable, Hashable {
    /// The ``Signal/name`` of the signal.
    public let signal: String
    public let key: String

    public init(signal: String, key: String) {
        self.signal = signal
        self.key = key
    }
}

/// A key's committed state in a task (pi-durable `SignalState`).
public enum SignalState<Value: Sendable>: Sendable {
    /// The value delivered under the key.
    case value(Value)
    /// The sleep's deadline came before a value did.
    case expired
}

extension SignalState: Equatable where Value: Equatable {}
extension SignalState: Hashable where Value: Hashable {}

/// What ``Harness/signal(taskId:_:key:value:)`` did (pi-durable `SignalResult`). Answer `duplicate` and `closed` to
/// the sender as final.
public enum SignalResult: String, Decodable, Sendable, Hashable {
    /// Durably kept in the task, not necessarily used yet; a value that arrives before the sleep wakes it at once.
    case delivered
    /// The key already holds a value, as for a retried webhook or a second tap.
    case duplicate
    /// Not matching the signal's schema.
    case invalid
    /// The task ended, holds its outcome, is marked to abort, or the key expired.
    case closed
    /// No such task.
    case notFound = "not_found"
}

/// Why parked work runs again (pi-durable `WakeReason`), kept while the task runs at the checkpoint it woke at.
public enum WakeReason: Sendable, Hashable, Decodable {
    /// The sleep's deadline came, and it listed no signals.
    case time
    /// The sleep's deadline came before any listed signal.
    case expired
    /// A value arrived under this key; read it with `readSignal`.
    case signal(signal: String, key: String)
    /// These tasks of the wait ended.
    case tasks(ended: [TaskID])

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        switch json["reason"]?.stringValue {
        case "time": self = .time
        case "expired": self = .expired
        case "signal": self = .signal(signal: json["signal"]?.stringValue ?? "", key: json["key"]?.stringValue ?? "")
        default: self = .tasks(ended: (try? (json["ended"] ?? []).decode(as: [TaskID].self)) ?? [])
        }
    }
}

/// A tool call that does not run yet: a ``Hook/beforeTool(_:)`` gate parked it, or the tool itself did (pi-durable 1.6). Its
/// slot in ``LiveState`` shows `sleeping` or `waiting`; this adds what its task waits for, from the task's committed
/// state, and what delivering a signal to it needs.
///
/// ```swift
/// for call in view.parkedCalls where call.signals.contains(approval.key(call.callId)) {
///     // Show Approve / Decline; on a tap:
///     try await harness.signal(taskId: call.taskId, approval, key: call.callId, value: Decision(allow: true))
/// }
/// ```
public struct ParkedToolCall: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { callId }
    /// The call's ID; for a nested call `<parentCallId>/<key>`.
    public let callId: String
    /// The tool.
    public let name: String
    /// The call's tool task: where signals for it are delivered.
    public let taskId: TaskID
    /// The calling tool call of a nested call.
    public let parentCallId: String?
    /// ``LiveState/ToolSlot/Status/sleeping`` or ``LiveState/ToolSlot/Status/waiting``.
    public let status: LiveState.ToolSlot.Status
    /// The keys a sleeping call waits for; any one of them wakes it.
    public let signals: [SignalKey]
    /// The sleep's deadline on the harness clock, if any.
    public let until: Date?
    /// The tasks a waiting call waits for.
    public let waitingOn: [TaskID]

    private enum CodingKeys: String, CodingKey { case callId, name, taskId, parentCallId, status, signals, until, on }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callId = try container.decode(String.self, forKey: .callId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        taskId = try container.decode(TaskID.self, forKey: .taskId)
        parentCallId = try container.decodeIfPresent(String.self, forKey: .parentCallId)
        status = try container.decode(LiveState.ToolSlot.Status.self, forKey: .status)
        signals = try container.decodeIfPresent([SignalKey].self, forKey: .signals) ?? []
        until = try container.decodeIfPresent(Double.self, forKey: .until).map { Date(timeIntervalSince1970: $0 / 1000) }
        waitingOn = try container.decodeIfPresent([TaskID].self, forKey: .on) ?? []
    }
}

extension ScopeHandle {
    func readSignal<Value>(_ signal: Signal<Value>, key: String) async throws -> SignalState<Value>? {
        let json: JSONValue = try await call("scope.readSignal", ["signal": signal.specification, "key": key])
        if json.isNull { return nil }
        if json["expired"]?.boolValue == true { return .expired }
        return .value(try (json["value"] ?? .null).decode(as: Value.self))
    }

    func wake() async throws -> WakeReason? {
        let json: JSONValue = try await call("scope.wake")
        return json.isNull ? nil : try json.decode(as: WakeReason.self)
    }

    func now() async throws -> Date {
        let milliseconds: Double = try await call("scope.now")
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

extension Harness {
    /// Delivers `value` to task `taskId` under `key` (pi-durable `harness.signal()`), in a commit of its own.
    ///
    /// The value is kept in the task until a sleep on the key wakes on it, also when the task does not sleep on it yet.
    /// For a parked tool call, `taskId` is ``ParkedToolCall/taskId`` (the call's slot's task). Nothing checks who sends
    /// a signal: authenticate senders in your app.
    @discardableResult
    public func signal<Value>(taskId: TaskID, _ signal: Signal<Value>, key: String, value: Value) async throws -> SignalResult {
        try await call(
            "harness.signal",
            ["task": taskId, "signal": signal.specification, "key": key, "value": try JSONValue(encoding: value)])
    }
}
