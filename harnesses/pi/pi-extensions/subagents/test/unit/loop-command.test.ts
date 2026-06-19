import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  parseLoopArgs,
  registerLoopCommand,
} from "../../src/slash/loop-command.ts";
import type { SubagentState } from "../../src/shared/types.ts";

// ── Minimal fake state ────────────────────────────────────────────────────────

function makeState(): Pick<SubagentState, "loopTimers"> & SubagentState {
  return {
    baseCwd: "",
    currentSessionId: null,
    asyncJobs: new Map(),
    foregroundRuns: new Map(),
    foregroundControls: new Map(),
    lastForegroundControlId: null,
    pendingForegroundControlNotices: new Map(),
    cleanupTimers: new Map(),
    loopTimers: new Map(),
    lastUiContext: null,
    poller: null,
    completionSeen: new Map(),
    watcher: null,
    watcherRestartTimer: null,
    resultFileCoalescer: { schedule: () => false, clear: () => {} },
  } as unknown as SubagentState;
}

// ── Fake deps (timer stubs) ───────────────────────────────────────────────────

function makeFakeDeps() {
  let nextId = 1;
  const active = new Map<ReturnType<typeof setInterval>, boolean>();
  const calls: { fn: () => void; ms: number }[] = [];

  const fakeSetInterval = (fn: () => void, ms: number) => {
    const id = nextId++ as unknown as ReturnType<typeof setInterval>;
    active.set(id, true);
    calls.push({ fn, ms });
    return id;
  };

  const fakeClearInterval = (id: ReturnType<typeof setInterval>) => {
    active.delete(id);
  };

  return { fakeSetInterval, fakeClearInterval, active, calls };
}

// ── Fake pi/ctx builders ──────────────────────────────────────────────────────

type HandlerFn = (args: string, ctx: unknown) => Promise<void>;

function makeUIPi() {
  const messages: { customType?: string; content: string; opts?: unknown }[] =
    [];
  const notifications: { text: string; level: string }[] = [];
  const handlers = new Map<string, HandlerFn>();

  const pi = {
    registerCommand(
      name: string,
      opts: { description: string; handler: HandlerFn },
    ) {
      handlers.set(name, opts.handler);
    },
    async sendMessage(
      msg: { customType?: string; content: string; display?: boolean },
      opts: unknown,
    ) {
      messages.push({ customType: msg.customType, content: msg.content, opts });
    },
  };

  const ctx = {
    hasUI: true,
    ui: {
      notify(text: string, level: string) {
        notifications.push({ text, level });
      },
      onTerminalInput(_cb: (input: unknown) => unknown) {
        // no-op in tests
      },
    },
  };

  return { pi, ctx, messages, notifications, handlers };
}

function makeHeadlessPi() {
  const messages: { customType?: string; content: string; opts?: unknown }[] =
    [];
  const handlers = new Map<string, HandlerFn>();

  const pi = {
    registerCommand(
      name: string,
      opts: { description: string; handler: HandlerFn },
    ) {
      handlers.set(name, opts.handler);
    },
    async sendMessage(
      msg: { customType?: string; content: string; display?: boolean },
      opts: unknown,
    ) {
      messages.push({ customType: msg.customType, content: msg.content, opts });
    },
  };

  const ctx = {
    hasUI: false,
    // No ui property — headless has no TUI.
  };

  return { pi, ctx, messages, handlers };
}

// ── parseLoopArgs tests ───────────────────────────────────────────────────────

describe("parseLoopArgs", () => {
  it("parses 5m interval with prompt", () => {
    const result = parseLoopArgs("5m check build");
    assert.equal(result.stop, false);
    assert.equal(result.intervalMs, 300_000);
    assert.equal(result.prompt, "check build");
    assert.equal(result.assumedDefault, false);
  });

  it("parses 30s interval with prompt", () => {
    const result = parseLoopArgs("30s tail log");
    assert.equal(result.stop, false);
    assert.equal(result.intervalMs, 30_000);
    assert.equal(result.prompt, "tail log");
  });

  it("folds unparseable leading token into prompt (self-paced)", () => {
    const result = parseLoopArgs("7x do thing");
    assert.equal(result.stop, false);
    assert.equal(result.intervalMs, null); // self-paced default
    assert.equal(result.prompt, "7x do thing");
    assert.equal(result.assumedDefault, false);
  });

  it("handles plain prompt (no interval token)", () => {
    const result = parseLoopArgs("just a prompt");
    assert.equal(result.stop, false);
    assert.equal(result.intervalMs, null);
    assert.equal(result.prompt, "just a prompt");
  });

  it("returns stop=true for 'stop'", () => {
    const result = parseLoopArgs("stop");
    assert.equal(result.stop, true);
    assert.equal(result.prompt, "");
  });

  it("returns stop=false and empty prompt for empty string (usage path)", () => {
    const result = parseLoopArgs("");
    assert.equal(result.stop, false);
    assert.equal(result.prompt, "");
  });

  it("parses 10m interval", () => {
    const result = parseLoopArgs("10m check disk");
    assert.equal(result.intervalMs, 600_000);
    assert.equal(result.prompt, "check disk");
  });
});

// ── registerLoopCommand handler tests ────────────────────────────────────────

describe("registerLoopCommand — UI mode (ctx.hasUI=true)", () => {
  it("arms ONE interval and fires first tick immediately when hasUI=true", async () => {
    const state = makeState();
    const { fakeSetInterval, fakeClearInterval, active, calls } =
      makeFakeDeps();
    const { pi, ctx, messages } = makeUIPi();

    registerLoopCommand(pi as never, state, {
      setInterval: fakeSetInterval,
      clearInterval: fakeClearInterval,
    });

    const handler =
      (pi as unknown as {
        registerCommand: (n: string, o: { handler: HandlerFn }) => void;
      }) &&
      // access via the fake pi's handlers map via our wrapper
      null; // unused; we registered via our fake pi above

    // Trigger handler via the stored handlers map on our custom pi.
    // Our makeUIPi stores handlers — trigger the loop handler.
    const fakePiObj = pi as unknown as { handlers?: Map<string, HandlerFn> };
    // The fake pi stores handlers inline; retrieve via the map we built.
    // Re-use the `handlers` from makeUIPi scope — re-run to access it cleanly.
    const { pi: pi2, ctx: ctx2, messages: msgs2, handlers: h2 } = makeUIPi();
    const state2 = makeState();
    const {
      fakeSetInterval: si2,
      fakeClearInterval: ci2,
      calls: c2,
      active: a2,
    } = makeFakeDeps();

    registerLoopCommand(pi2 as never, state2, {
      setInterval: si2,
      clearInterval: ci2,
    });

    const loopHandler = h2.get("loop");
    assert.ok(loopHandler, "loop command should be registered");

    await loopHandler("5m check status", ctx2);

    // First tick fires immediately → sendMessage called once.
    assert.equal(msgs2.length, 1, "sendMessage called once for first tick");
    assert.equal(msgs2[0].customType, "loop-tick");
    assert.equal(msgs2[0].content, "check status");

    // Interval armed once.
    assert.equal(c2.length, 1, "setInterval called once");
    assert.equal(c2[0].ms, 300_000); // 5m

    // Timer stored in state.loopTimers.
    assert.equal(state2.loopTimers.size, 1);
  });

  it("does NOT arm interval in headless mode (ctx.hasUI=false)", async () => {
    const state = makeState();
    const { fakeSetInterval, fakeClearInterval, calls } = makeFakeDeps();
    const { pi, ctx, messages, handlers } = makeHeadlessPi();

    registerLoopCommand(pi as never, state, {
      setInterval: fakeSetInterval,
      clearInterval: fakeClearInterval,
    });

    const loopHandler = handlers.get("loop");
    assert.ok(loopHandler, "loop command should be registered");

    await loopHandler("5m check status", ctx);

    // No interval armed.
    assert.equal(
      calls.length,
      0,
      "setInterval must NOT be called in headless mode",
    );
    assert.equal(
      state.loopTimers.size,
      0,
      "loopTimers must be empty in headless mode",
    );

    // Detect-and-tell message emitted.
    assert.equal(messages.length, 1, "detect-and-tell message must be emitted");
    assert.equal(messages[0].customType, "loop-headless-detect");
    assert.ok(
      messages[0].content.includes("interactive session"),
      "detect-and-tell message should mention interactive session",
    );
  });

  it("/loop stop clears the active timer", async () => {
    const state = makeState();
    const { fakeSetInterval, fakeClearInterval, active } = makeFakeDeps();
    const { pi, ctx, handlers } = makeUIPi();

    registerLoopCommand(pi as never, state, {
      setInterval: fakeSetInterval,
      clearInterval: fakeClearInterval,
    });

    const loopHandler = handlers.get("loop");
    assert.ok(loopHandler);

    // Arm the loop.
    await loopHandler("30s ping", ctx);
    assert.equal(state.loopTimers.size, 1, "timer should be armed");

    // Stop it.
    await loopHandler("stop", ctx);
    assert.equal(
      state.loopTimers.size,
      0,
      "timer should be cleared after stop",
    );
    assert.equal(active.size, 0, "clearInterval should have been called");
  });

  it("/loop alone emits a usage error and does not arm interval", async () => {
    const state = makeState();
    const { fakeSetInterval, fakeClearInterval, calls } = makeFakeDeps();
    const { pi, ctx, notifications, handlers } = makeUIPi();

    registerLoopCommand(pi as never, state, {
      setInterval: fakeSetInterval,
      clearInterval: fakeClearInterval,
    });

    const loopHandler = handlers.get("loop");
    assert.ok(loopHandler);

    await loopHandler("", ctx);

    assert.equal(
      calls.length,
      0,
      "setInterval must not be called for empty args",
    );
    assert.equal(state.loopTimers.size, 0, "no timer should be stored");
    assert.ok(
      notifications.some((n) => n.level === "error"),
      "usage error notification should be emitted",
    );
  });
});
