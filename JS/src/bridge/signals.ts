// Signals (pi-durable 1.6): typed JSON values delivered to a live task from outside. Swift defines a signal as data
// (`Signal`: name, version, JSON schema); pi-durable only accepts tokens its own `defineSignal()` built, so the bridge
// builds one token per definition and reuses it.
import type { Context } from "@earendil-works/chord/context";
import { defineSignal, type SignalState, type SignalToken, type TaskId } from "@earendil-works/pi-durable";
import { type Args, register } from "./core.ts";
import { harnessState } from "./state.ts";

const tokens = new Map<string, SignalToken<unknown>>();

/** The pi-durable token of a Swift `Signal` specification (`{ name, version, schema }`). */
export function signalToken(spec: Args): SignalToken<unknown> {
	const id = `${spec.name}\u0000${spec.version}\u0000${JSON.stringify(spec.schema ?? {})}`;
	let token = tokens.get(id);
	if (token === undefined) {
		token = defineSignal({ name: spec.name as string, version: spec.version as number, schema: (spec.schema ?? {}) as object }) as SignalToken<unknown>;
		tokens.set(id, token);
	}
	return token;
}

/** A key's state for Swift: `{ value }`, `{ expired: true }`, or null while nothing came. */
export function describeSignalState(state: SignalState<unknown> | undefined): Args | null {
	if (state === undefined) return null;
	return "expired" in state ? { expired: true } : { value: state.value ?? null };
}

/** The signal reader of a scope (`HookApi`, `ToolExecutionApi`, `TaskRuntime`). */
export type SignalReader = {
	readSignal<T>(token: SignalToken<T>, key: string, context: Context): Promise<SignalState<T> | undefined>;
};

register({
	/** `harness.signal(taskId, token, key, value, context)`. */
	"harness.signal": (args, context) =>
		harnessState(args.harness).harness.signal(args.task as TaskId, signalToken(args.signal), args.key as string, args.value ?? null, context),
});
