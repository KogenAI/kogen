import { afterEach, describe, expect, it, vi } from "vitest";
import type { Question, Result } from "../src/schema.ts";

// Minimal mock of the ExtensionAPI surface used by the extension
function makePi(activeTools: string[] = ["ask_user_question"]) {
  const tools = [...activeTools];
  let registeredTool: {
    name: string;
    execute: (
      id: string,
      params: { questions: Question[] },
      signal: AbortSignal,
      onUpdate: () => void,
      ctx: {
        hasUI: boolean;
        ui?: { custom: <T>(...args: unknown[]) => Promise<T | null> };
      },
    ) => Promise<{
      content: { type: string; text: string }[];
      details: Result;
    }>;
  } | null = null;

  const pi = {
    registerTool: vi.fn((spec: typeof registeredTool) => {
      registeredTool = spec;
    }),
    getActiveTools: vi.fn(() => [...tools]),
    setActiveTools: vi.fn((updated: string[]) => {
      tools.length = 0;
      tools.push(...updated);
    }),
    _getRegistered: () => registeredTool,
  };
  return pi;
}

const q = (text: string): Question => ({
  question: text,
  header: text.slice(0, 12),
  multiSelect: false,
  options: [{ label: "Option A" }, { label: "Option B" }],
});

async function loadExtension(pi: ReturnType<typeof makePi>) {
  const mod = await import("../index.ts");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (mod.default as (pi: any) => void)(pi);
}

describe("ask_user_question extension — hasUI=false (headless backstop)", () => {
  it("(a) hasUI:false → returns cancelled:true with 'requires an interactive session' text", async () => {
    const pi = makePi();
    await loadExtension(pi);

    const tool = pi._getRegistered();
    expect(tool).not.toBeNull();

    const result = await tool!.execute(
      "call-1",
      { questions: [q("What approach?")] },
      new AbortController().signal,
      () => {},
      { hasUI: false },
    );

    expect(result.details.cancelled).toBe(true);
    expect(result.content[0].text).toContain("requires an interactive session");
  });

  it("(a) hasUI:false → setActiveTools called removing 'ask_user_question'", async () => {
    const pi = makePi(["ask_user_question", "other_tool"]);
    await loadExtension(pi);

    const tool = pi._getRegistered();
    await tool!.execute(
      "call-2",
      { questions: [q("Pick one?"), q("Pick two?")] },
      new AbortController().signal,
      () => {},
      { hasUI: false },
    );

    expect(pi.setActiveTools).toHaveBeenCalled();
    const updatedTools: string[] = pi.setActiveTools.mock
      .calls[0][0] as string[];
    expect(updatedTools).not.toContain("ask_user_question");
    expect(updatedTools).toContain("other_tool");
  });

  it("(b) hasUI:true with ctx.ui.custom returning null → cancelled path", async () => {
    const pi = makePi();
    await loadExtension(pi);

    const tool = pi._getRegistered();
    const result = await tool!.execute(
      "call-3",
      { questions: [q("Direction?")] },
      new AbortController().signal,
      () => {},
      {
        hasUI: true,
        ui: {
          custom: async () => null,
        },
      },
    );

    expect(result.details.cancelled).toBe(true);
  });

  it("(a) hasUI:false → details.answers is empty object", async () => {
    const pi = makePi();
    await loadExtension(pi);

    const tool = pi._getRegistered();
    const result = await tool!.execute(
      "call-4",
      { questions: [q("Scope?")] },
      new AbortController().signal,
      () => {},
      { hasUI: false },
    );

    expect(result.details.answers).toEqual({});
  });
});

describe("ask_user_question extension — role-aware description", () => {
  const ORIGINAL_CLAUDE_ROLE = process.env["CLAUDE_ROLE"];
  const ORIGINAL_PI_ROLE = process.env["PI_ROLE"];

  afterEach(() => {
    if (ORIGINAL_CLAUDE_ROLE === undefined) {
      delete process.env["CLAUDE_ROLE"];
    } else {
      process.env["CLAUDE_ROLE"] = ORIGINAL_CLAUDE_ROLE;
    }
    if (ORIGINAL_PI_ROLE === undefined) {
      delete process.env["PI_ROLE"];
    } else {
      process.env["PI_ROLE"] = ORIGINAL_PI_ROLE;
    }
  });

  it("PI_ROLE=shape → description permits only product/UX forks, forbids tooling/placement", async () => {
    delete process.env["CLAUDE_ROLE"];
    process.env["PI_ROLE"] = "shape";
    const pi = makePi();
    await loadExtension(pi);

    const tool = pi._getRegistered();
    expect(tool).not.toBeNull();
    const desc = (pi.registerTool.mock.calls[0][0] as { description: string })
      .description;
    expect(desc).toContain("genuine product/UX fork");
    expect(desc).toContain("FORBIDDEN uses");
    expect(desc).toContain("auto-decide");
  });

  it("CLAUDE_ROLE=shape → same shape description (Claude role signal also honored)", async () => {
    delete process.env["PI_ROLE"];
    process.env["CLAUDE_ROLE"] = "shape";
    const pi = makePi();
    await loadExtension(pi);

    const desc = (pi.registerTool.mock.calls[0][0] as { description: string })
      .description;
    expect(desc).toContain("genuine product/UX fork");
  });

  it("PI_ROLE unset (non-shape mode) → default description, no shape-only restrictions", async () => {
    delete process.env["CLAUDE_ROLE"];
    delete process.env["PI_ROLE"];
    const pi = makePi();
    await loadExtension(pi);

    const desc = (pi.registerTool.mock.calls[0][0] as { description: string })
      .description;
    expect(desc).not.toContain("genuine product/UX fork");
    expect(desc).toContain("Make decisions on implementation choices");
  });

  it("PI_ROLE=debug (non-shape) → default description even when a role is set", async () => {
    delete process.env["CLAUDE_ROLE"];
    process.env["PI_ROLE"] = "debug";
    const pi = makePi();
    await loadExtension(pi);

    const desc = (pi.registerTool.mock.calls[0][0] as { description: string })
      .description;
    expect(desc).not.toContain("genuine product/UX fork");
  });

  it("headless (hasUI:false) shape session still gets shape description on registration", async () => {
    process.env["PI_ROLE"] = "shape";
    const pi = makePi();
    await loadExtension(pi);

    const tool = pi._getRegistered();
    const result = await tool!.execute(
      "call-5",
      { questions: [q("Fork?")] },
      new AbortController().signal,
      () => {},
      { hasUI: false },
    );
    expect(result.details.cancelled).toBe(true);
    const desc = (pi.registerTool.mock.calls[0][0] as { description: string })
      .description;
    expect(desc).toContain("genuine product/UX fork");
  });
});
