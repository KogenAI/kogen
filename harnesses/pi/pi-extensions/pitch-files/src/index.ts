import type { AgentToolResult } from "@mariozechner/pi-agent-core";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { TruncatedText } from "@mariozechner/pi-tui";
import { Type } from "@sinclair/typebox";
import { executeMove } from "./transaction.ts";
import { resolveRepoRoot, validateMove } from "./paths.ts";

const InputSchema = Type.Object({
  source: Type.String({
    description:
      "Repo-relative or cwd-prefixed absolute path to a direct .md child of codegen/pitches/draft/.",
  }),
  destination: Type.String({
    description:
      "Repo-relative or cwd-prefixed absolute path to a direct .md child of codegen/pitches/draft/ (rename) or codegen/pitches/archive/ (archive). Must not already exist.",
  }),
});

export type PitchMoveDetails = {
  ok: boolean;
  source?: string;
  destination?: string;
  recovered?: boolean;
  error?: string;
};

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "pitch_move",
    label: "Pitch Move",
    description: `Rename a draft pitch or move a draft pitch to archive — no-clobber, confined to codegen/pitches/.
Source MUST be a direct .md child of codegen/pitches/draft/.
Destination MUST be a direct .md child of codegen/pitches/draft/ (rename) or codegen/pitches/archive/ (archive) and MUST NOT already exist.
Refuses (loud error, no mutation) on: symlinked source, non-regular source, traversal, same path, invalid slug shape, any other lifecycle directory (ready/shipped/studio/transcripts), or an existing destination that is not the recognized interrupted-retry shape.
Never use bash mv for pitch files — this tool is the sanctioned confined path.`,

    parameters: InputSchema,

    async execute(
      _toolCallId,
      params,
    ): Promise<AgentToolResult<PitchMoveDetails>> {
      const { source, destination } = params as {
        source: string;
        destination: string;
      };

      let repoRoot: string;
      try {
        repoRoot = resolveRepoRoot(process.cwd());
      } catch (err) {
        const msg = `pitch_move: failed to resolve repo root: ${(err as Error).message}`;
        return {
          content: [{ type: "text", text: `Error: ${msg}` }],
          details: { ok: false, error: msg },
        };
      }

      let validated: { sourceReal: string; destinationReal: string };
      try {
        validated = validateMove(source, destination, repoRoot);
      } catch (err) {
        const msg = (err as Error).message;
        return {
          content: [{ type: "text", text: `Error: ${msg}` }],
          details: { ok: false, error: msg },
        };
      }

      const result = executeMove(
        validated.sourceReal,
        validated.destinationReal,
      );
      if (!result.ok) {
        return {
          content: [{ type: "text", text: `Error: ${result.error}` }],
          details: { ok: false, error: result.error },
        };
      }

      const verb = result.recovered ? "completed interrupted move" : "moved";
      return {
        content: [
          {
            type: "text",
            text: `OK: ${verb} ${result.source} -> ${result.destination}`,
          },
        ],
        details: {
          ok: true,
          source: result.source,
          destination: result.destination,
          recovered: result.recovered,
        },
      };
    },

    renderCall(args, theme) {
      const a = args as { source?: string; destination?: string };
      return new TruncatedText(
        theme.fg("toolTitle", theme.bold("pitch_move ")) +
          theme.fg("muted", `${a.source ?? "?"} -> ${a.destination ?? "?"}`),
        0,
        0,
      );
    },

    renderResult(result, _options, theme) {
      const details = result.details as PitchMoveDetails | undefined;
      if (!details || !details.ok) {
        const t = result.content[0];
        return new TruncatedText(
          theme.fg("error", t?.type === "text" ? t.text : "pitch_move failed"),
          0,
          0,
        );
      }
      return new TruncatedText(
        theme.fg("success", "✓ ") +
          theme.fg("text", `${details.source} -> ${details.destination}`),
        0,
        0,
      );
    },
  });
}
