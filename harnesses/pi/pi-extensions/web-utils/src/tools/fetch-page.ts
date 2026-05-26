import { Type, type Static } from "@sinclair/typebox";
import type { ToolDefinition } from "@mariozechner/pi-coding-agent";
import { loadConfig } from "../config.js";
import { htmlToMarkdown, htmlToStructuredJson } from "../utils/formatters.js";
import {
  fetchText,
  isProbablyHtml,
  isProbablyJson,
  truncateText,
} from "../utils/http.js";

const FetchPageParamsSchema = Type.Object({
  url: Type.String({ description: "HTTP(S) URL to fetch" }),
  output: Type.Optional(
    Type.Union([Type.Literal("markdown"), Type.Literal("json")], {
      description: "Output format (default: markdown)",
    }),
  ),
  preferMarkdownNew: Type.Optional(
    Type.Boolean({
      description:
        "Try markdown.new first (https://markdown.new/<url>) before local HTML processing",
    }),
  ),
  maxChars: Type.Optional(
    Type.Integer({
      minimum: 1000,
      maximum: 500000,
      description: "Max output size",
    }),
  ),
  includeRawHtml: Type.Optional(
    Type.Boolean({ description: "Include truncated raw HTML in details" }),
  ),
});

type FetchPageParams = Static<typeof FetchPageParamsSchema>;

interface FetchOutcome {
  text: string;
  details: Record<string, unknown>;
}

function isHttpUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}

async function tryMarkdownNew(
  targetUrl: string,
  params: FetchPageParams,
  signal: AbortSignal | undefined,
): Promise<FetchOutcome | null> {
  const config = loadConfig();
  if (!(params.preferMarkdownNew ?? true)) return null;
  if (!config.fetch.markdownNew.enabled) return null;

  const endpoint = `${config.fetch.markdownNew.baseUrl}${targetUrl}`;
  try {
    const result = await fetchText(endpoint, {
      headers: {
        accept: "text/markdown,text/plain;q=0.9,*/*;q=0.5",
        "user-agent": config.fetch.userAgent,
      },
      timeoutMs: config.fetch.markdownNew.timeoutMs,
      signal,
    });

    if (!result.ok) return null;
    const body = result.body.trim();
    if (body.length < 40) return null;
    if (body.startsWith("{") || body.toLowerCase().startsWith("error:"))
      return null;

    if ((params.output ?? "markdown") === "json") {
      const json = {
        url: targetUrl,
        title: targetUrl,
        source: "markdown.new",
        markdown: body,
      };
      return {
        text: JSON.stringify(json, null, 2),
        details: {
          source: "markdown.new",
          via: endpoint,
          contentLength: body.length,
        },
      };
    }

    return {
      text: body,
      details: {
        source: "markdown.new",
        via: endpoint,
        contentLength: body.length,
      },
    };
  } catch {
    return null;
  }
}

async function fetchAndConvert(
  targetUrl: string,
  params: FetchPageParams,
  signal: AbortSignal | undefined,
): Promise<FetchOutcome> {
  const config = loadConfig();
  const output = params.output ?? "markdown";
  const response = await fetchText(targetUrl, {
    headers: {
      accept: "text/html,application/xhtml+xml,application/json,text/plain,*/*",
      "user-agent": config.fetch.userAgent,
    },
    timeoutMs: config.fetch.timeoutMs,
    signal,
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }

  const maxChars = params.maxChars ?? config.fetch.maxBodyChars;
  const details: Record<string, unknown> = {
    source: "direct",
    finalUrl: response.url,
    contentType: response.contentType,
    status: response.status,
  };

  if (output === "json") {
    if (isProbablyJson(response.contentType, response.body)) {
      let json: unknown;
      try {
        json = JSON.parse(response.body);
      } catch {
        json = { url: response.url, content: response.body };
      }
      return {
        text: truncateText(JSON.stringify(json, null, 2), maxChars),
        details,
      };
    }
    if (isProbablyHtml(response.contentType, response.body)) {
      const json = htmlToStructuredJson(response.body, response.url);
      return {
        text: truncateText(JSON.stringify(json, null, 2), maxChars),
        details: { ...details, extraction: "htmlToStructuredJson" },
      };
    }
    return {
      text: truncateText(
        JSON.stringify(
          {
            url: response.url,
            contentType: response.contentType,
            content: response.body,
          },
          null,
          2,
        ),
        maxChars,
      ),
      details,
    };
  }

  if (isProbablyHtml(response.contentType, response.body)) {
    const extracted = htmlToMarkdown(response.body, response.url);
    const markdown = `# ${extracted.title}\n\n${extracted.markdown}`;
    const finalMarkdown = truncateText(markdown, maxChars);
    return {
      text: finalMarkdown,
      details: {
        ...details,
        extraction: extracted.method,
        rawHtml: params.includeRawHtml
          ? truncateText(response.body, 12000)
          : undefined,
      },
    };
  }

  if (isProbablyJson(response.contentType, response.body)) {
    let formatted = response.body;
    try {
      formatted = `\`\`\`json\n${JSON.stringify(JSON.parse(response.body), null, 2)}\n\`\`\``;
    } catch {
      formatted = `\`\`\`json\n${response.body}\n\`\`\``;
    }
    return {
      text: truncateText(formatted, maxChars),
      details,
    };
  }

  return {
    text: truncateText(response.body, maxChars),
    details,
  };
}

export function createFetchWebpageTool(): ToolDefinition<
  typeof FetchPageParamsSchema
> {
  return {
    name: "fetch_webpage",
    label: "Fetch Webpage",
    description:
      "Fetch a webpage as markdown (default) or structured JSON. Tries markdown.new first using https://markdown.new/<url>, then falls back to local HTML processing (Readability + Turndown).",
    parameters: FetchPageParamsSchema,

    async execute(_toolCallId, params, signal, onUpdate) {
      if (!isHttpUrl(params.url)) {
        return {
          content: [{ type: "text", text: "URL must be absolute HTTP(S)." }],
          details: { error: "Invalid URL" },
        };
      }

      onUpdate?.({
        content: [{ type: "text", text: "Fetching webpage..." }],
        details: { phase: "fetch" },
      });

      const fromMarkdownNew = await tryMarkdownNew(params.url, params, signal);
      if (fromMarkdownNew) {
        return {
          content: [{ type: "text", text: fromMarkdownNew.text }],
          details: fromMarkdownNew.details,
        };
      }

      onUpdate?.({
        content: [
          {
            type: "text",
            text: "markdown.new unavailable, using local HTML conversion...",
          },
        ],
        details: { phase: "fallback" },
      });

      try {
        const outcome = await fetchAndConvert(params.url, params, signal);
        return {
          content: [{ type: "text", text: outcome.text }],
          details: outcome.details,
        };
      } catch (error) {
        return {
          content: [
            {
              type: "text",
              text: `Failed to fetch webpage: ${error instanceof Error ? error.message : String(error)}`,
            },
          ],
          details: {
            error: error instanceof Error ? error.message : String(error),
          },
        };
      }
    },
  };
}
