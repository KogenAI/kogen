import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { Key, matchesKey } from "@earendil-works/pi-tui";
import type { SubagentState } from "../shared/types.ts";

export interface ParsedLoop {
  stop: boolean;
  intervalMs: number | null; // null = self-paced default (DEFAULT_INTERVAL_MS)
  prompt: string;
  assumedDefault: boolean; // true when a leading token looked like an interval but didn't parse
}

const DEFAULT_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes

export function parseLoopArgs(raw: string): ParsedLoop {
  const input = raw.trim();
  if (input === "stop") {
    return { stop: true, intervalMs: null, prompt: "", assumedDefault: false };
  }
  if (input === "") {
    return { stop: false, intervalMs: null, prompt: "", assumedDefault: false };
  }
  const firstSpace = input.indexOf(" ");
  const head = firstSpace === -1 ? input : input.slice(0, firstSpace);
  const rest = firstSpace === -1 ? "" : input.slice(firstSpace + 1).trim();
  const m = head.match(/^(\d+)(s|m)$/);
  if (m) {
    const n = Number(m[1]);
    const intervalMs = m[2] === "s" ? n * 1000 : n * 60_000;
    return { stop: false, intervalMs, prompt: rest, assumedDefault: false };
  }
  // Leading token is not an interval — whole input is the prompt; use self-paced default.
  return {
    stop: false,
    intervalMs: null,
    prompt: input,
    assumedDefault: false,
  };
}

export interface LoopDeps {
  setInterval: (fn: () => void, ms: number) => ReturnType<typeof setInterval>;
  clearInterval: (id: ReturnType<typeof setInterval>) => void;
}

const LOOP_KEY = "loop";

export function registerLoopCommand(
  pi: ExtensionAPI,
  state: SubagentState,
  deps: LoopDeps = { setInterval, clearInterval },
): void {
  pi.registerCommand("loop", {
    description:
      "Self-firing interval poll (interactive only): /loop [5m|30s] <prompt> | /loop stop",
    handler: async (args: string, ctx: ExtensionContext) => {
      const parsed = parseLoopArgs(args);

      // "/loop stop" — cancel active loop
      if (parsed.stop) {
        const existing = state.loopTimers.get(LOOP_KEY);
        if (existing !== undefined) {
          deps.clearInterval(existing);
          state.loopTimers.delete(LOOP_KEY);
        }
        if (ctx.hasUI) {
          ctx.ui.notify("Loop stopped.", "info");
        }
        return;
      }

      // "/loop" alone — usage error
      if (!parsed.prompt) {
        if (ctx.hasUI) {
          ctx.ui.notify(
            "Usage: /loop [interval] <prompt> | /loop stop\nExample: /loop 5m check build status",
            "error",
          );
        }
        return;
      }

      // Headless: cannot self-fire; emit detect-and-tell message.
      if (!ctx.hasUI) {
        await pi.sendMessage(
          {
            customType: "loop-headless-detect",
            content:
              "/loop requires an idle interactive session — it cannot self-fire in a headless (--print / CLAUDE_NONINTERACTIVE=1) run. " +
              "Re-run the launcher interactively (without CLAUDE_NONINTERACTIVE=1) to use /loop. " +
              "For headless recurring polls, use an external cron job that re-invokes the launcher per tick.",
            display: true,
          },
          {},
        );
        return;
      }

      // Cancel any previously running loop before arming a new one.
      const existing = state.loopTimers.get(LOOP_KEY);
      if (existing !== undefined) {
        deps.clearInterval(existing);
        state.loopTimers.delete(LOOP_KEY);
      }

      const intervalMs = parsed.intervalMs ?? DEFAULT_INTERVAL_MS;
      const prompt = parsed.prompt;
      const intervalLabel =
        intervalMs >= 60_000
          ? `${intervalMs / 60_000}m`
          : `${intervalMs / 1000}s`;

      ctx.ui.notify(
        `Loop armed: sending "${prompt}" every ${intervalLabel}. Use /loop stop or Esc to cancel.`,
        "info",
      );

      const sendTick = () => {
        void pi.sendMessage(
          {
            customType: "loop-tick",
            content: prompt,
            display: true,
          },
          { triggerTurn: true },
        );
      };

      // Fire first tick immediately.
      sendTick();

      // Arm recurring interval.
      const timerId = deps.setInterval(sendTick, intervalMs);
      state.loopTimers.set(LOOP_KEY, timerId);

      // Esc cancels the loop (mirrors slash-commands.ts Esc-cancel pattern).
      ctx.ui.onTerminalInput((input) => {
        if (!matchesKey(input, Key.escape)) return undefined;
        const t = state.loopTimers.get(LOOP_KEY);
        if (t !== undefined) {
          deps.clearInterval(t);
          state.loopTimers.delete(LOOP_KEY);
          ctx.ui.notify("Loop cancelled.", "info");
        }
        return { consume: true };
      });
    },
  });
}
