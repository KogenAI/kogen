import { Type, type Static } from "@sinclair/typebox";
import type { ToolDefinition } from "@mariozechner/pi-coding-agent";
import { parseHTML } from "linkedom";
import { loadConfig } from "../config.js";
import type { SearchAttempt, SearchHit, SearchEngineKind } from "../types.js";
import { htmlToMarkdown, htmlToStructuredJson } from "../utils/formatters.js";
import { buildUrl, fetchText, isProbablyHtml, isProbablyJson, truncateText } from "../utils/http.js";

const SearchParamsSchema = Type.Object({
	query: Type.String({ description: "Search query" }),
	engineId: Type.Optional(Type.String({ description: "Preferred engine id from config.search.engines" })),
	fallbackOrder: Type.Optional(
		Type.Array(Type.String(), { description: "Override fallback order for this call" }),
	),
	maxResults: Type.Optional(Type.Integer({ minimum: 1, maximum: 50, description: "Maximum number of results" })),
	extraParams: Type.Optional(
		Type.Record(Type.String(), Type.String(), {
			description: "Extra query params appended to the selected engine request",
		}),
	),
	allowFallback: Type.Optional(Type.Boolean({ description: "Try next configured engines if preferred engine fails" })),
	rawHtmlFormat: Type.Optional(
		Type.Union([Type.Literal("none"), Type.Literal("markdown"), Type.Literal("json")], {
			description: "If engine returns HTML, optionally format raw HTML using webpage fetch formatter",
		}),
	),
	includeRawResponse: Type.Optional(
		Type.Boolean({ description: "Include raw engine response (truncated) in details" }),
	),
});

type SearchParams = Static<typeof SearchParamsSchema>;

interface EngineSearchResult {
	hits: SearchHit[];
	formattedHtml?: string;
	rawResponse?: string;
	status: number;
}

function normalizeResultUrl(href: string, baseUrl: string): string | null {
	if (!href) return null;
	try {
		const absolute = new URL(href, baseUrl);
		if (absolute.hostname.includes("google.") && absolute.pathname === "/url") {
			const q = absolute.searchParams.get("q");
			if (q) return q;
		}
		if (absolute.protocol !== "http:" && absolute.protocol !== "https:") return null;
		return absolute.toString();
	} catch {
		return null;
	}
}

function collectUnique(hits: SearchHit[], maxResults: number): SearchHit[] {
	const out: SearchHit[] = [];
	const seen = new Set<string>();
	for (const hit of hits) {
		const key = hit.url;
		if (!key || seen.has(key)) continue;
		seen.add(key);
		out.push(hit);
		if (out.length >= maxResults) break;
	}
	return out;
}

function parseDuckDuckGoHtml(html: string, baseUrl: string, maxResults: number): SearchHit[] {
	const { document } = parseHTML(html);
	const hits: SearchHit[] = [];

	for (const node of Array.from(document.querySelectorAll(".result"))) {
		const titleNode = node.querySelector("a.result__a") ?? node.querySelector("h2 a") ?? node.querySelector("a");
		const href = titleNode?.getAttribute("href") ?? "";
		const url = normalizeResultUrl(href, baseUrl);
		if (!url) continue;
		const title = titleNode?.textContent?.trim() || url;
		const snippet = node.querySelector(".result__snippet")?.textContent?.trim() ?? undefined;
		hits.push({ title, url, snippet });
		if (hits.length >= maxResults) break;
	}

	return collectUnique(hits, maxResults);
}

function parseGoogleHtml(html: string, baseUrl: string, maxResults: number): SearchHit[] {
	const { document } = parseHTML(html);
	const hits: SearchHit[] = [];

	for (const block of Array.from(document.querySelectorAll("div.g"))) {
		const anchor = block.querySelector("a[href]");
		const href = anchor?.getAttribute("href") ?? "";
		const url = normalizeResultUrl(href, baseUrl);
		if (!url) continue;
		if (url.includes("google.com/search")) continue;
		const title = block.querySelector("h3")?.textContent?.trim() || anchor?.textContent?.trim() || url;
		const snippet = block.querySelector("div.VwiC3b")?.textContent?.trim() ?? undefined;
		hits.push({ title, url, snippet });
		if (hits.length >= maxResults) break;
	}

	return collectUnique(hits, maxResults);
}

function parseGenericHtml(html: string, baseUrl: string, maxResults: number): SearchHit[] {
	const { document } = parseHTML(html);
	const hits: SearchHit[] = [];

	for (const anchor of Array.from(document.querySelectorAll("a[href]"))) {
		const href = anchor.getAttribute("href") ?? "";
		const url = normalizeResultUrl(href, baseUrl);
		if (!url) continue;
		const title = anchor.textContent?.replace(/\s+/g, " ").trim() || url;
		if (title.length < 3) continue;
		hits.push({ title, url });
		if (hits.length >= maxResults * 3) break;
	}

	return collectUnique(hits, maxResults);
}

function readPath(value: unknown, path: string[]): unknown {
	let current = value;
	for (const key of path) {
		if (typeof current !== "object" || current === null || !(key in current)) return undefined;
		current = (current as Record<string, unknown>)[key];
	}
	return current;
}

function parseJsonHits(json: unknown, maxResults: number): SearchHit[] {
	const candidates: unknown[] = [];
	const paths = [
		["results"],
		["items"],
		["webPages", "value"],
		["organic_results"],
		["data"],
	];
	for (const path of paths) {
		const value = readPath(json, path);
		if (Array.isArray(value)) candidates.push(...value);
	}
	if (Array.isArray(json)) candidates.push(...json);

	const hits: SearchHit[] = [];
	for (const item of candidates) {
		if (typeof item !== "object" || item === null) continue;
		const record = item as Record<string, unknown>;
		const url =
			(typeof record.url === "string" && record.url) ||
			(typeof record.link === "string" && record.link) ||
			(typeof record.href === "string" && record.href) ||
			"";
		if (!url) continue;
		const title =
			(typeof record.title === "string" && record.title) ||
			(typeof record.name === "string" && record.name) ||
			url;
		const snippet =
			(typeof record.content === "string" && record.content) ||
			(typeof record.snippet === "string" && record.snippet) ||
			(typeof record.description === "string" && record.description) ||
			undefined;
		hits.push({ title, url, snippet });
		if (hits.length >= maxResults * 3) break;
	}

	return collectUnique(hits, maxResults);
}

function parseHtmlHits(kind: SearchEngineKind, html: string, baseUrl: string, maxResults: number): SearchHit[] {
	if (kind === "duckduckgo") return parseDuckDuckGoHtml(html, baseUrl, maxResults);
	if (kind === "google") return parseGoogleHtml(html, baseUrl, maxResults);
	return parseGenericHtml(html, baseUrl, maxResults);
}

function buildSearchUrl(baseUrl: string, queryParam: string, query: string, params: Record<string, string>): string {
	if (baseUrl.includes("{query}")) {
		const replaced = baseUrl.replaceAll("{query}", encodeURIComponent(query));
		return buildUrl(replaced, params);
	}
	return buildUrl(baseUrl, { ...params, [queryParam]: query });
}

async function searchWithEngine(
	query: string,
	maxResults: number,
	engine: {
		id: string;
		kind: SearchEngineKind;
		baseUrl: string;
		queryParam: string;
		queryParams: Record<string, string>;
		headers: Record<string, string>;
		responseFormat: "auto" | "json" | "html";
		timeoutMs: number;
	},
	params: SearchParams,
	signal: AbortSignal | undefined,
): Promise<EngineSearchResult> {
	const config = loadConfig();
	const finalUrl = buildSearchUrl(engine.baseUrl, engine.queryParam, query, {
		...engine.queryParams,
		...(params.extraParams ?? {}),
	});

	const response = await fetchText(finalUrl, {
		headers: {
			"user-agent": config.search.userAgent,
			"accept": "text/html,application/json;q=0.9,*/*;q=0.5",
			...engine.headers,
		},
		timeoutMs: engine.timeoutMs,
		signal,
	});

	if (!response.ok) {
		throw new Error(`${engine.id} responded with HTTP ${response.status}`);
	}

	let mode: "json" | "html";
	if (engine.responseFormat === "auto") {
		mode = isProbablyJson(response.contentType, response.body) ? "json" : "html";
	} else {
		mode = engine.responseFormat;
	}

	let hits: SearchHit[] = [];
	if (mode === "json") {
		try {
			hits = parseJsonHits(JSON.parse(response.body), maxResults);
		} catch {
			hits = [];
		}
		if (hits.length === 0 && isProbablyHtml(response.contentType, response.body)) {
			hits = parseHtmlHits(engine.kind, response.body, response.url, maxResults);
		}
	} else {
		hits = parseHtmlHits(engine.kind, response.body, response.url, maxResults);
	}

	let formattedHtml: string | undefined;
	if (mode === "html" && params.rawHtmlFormat && params.rawHtmlFormat !== "none") {
		if (params.rawHtmlFormat === "markdown") {
			formattedHtml = htmlToMarkdown(response.body, response.url).markdown;
		} else {
			formattedHtml = JSON.stringify(htmlToStructuredJson(response.body, response.url), null, 2);
		}
		formattedHtml = truncateText(formattedHtml, 25000);
	}

	return {
		hits: collectUnique(hits, maxResults),
		formattedHtml,
		rawResponse: params.includeRawResponse ? truncateText(response.body, 12000) : undefined,
		status: response.status,
	};
}

function formatHits(query: string, engineId: string, hits: SearchHit[]): string {
	const lines: string[] = [];
	lines.push(`## Search Results`);
	lines.push("");
	lines.push(`Query: \`${query}\``);
	lines.push(`Engine: \`${engineId}\``);
	lines.push("");

	if (hits.length === 0) {
		lines.push("No parsed results found.");
		return lines.join("\n");
	}

	for (let index = 0; index < hits.length; index += 1) {
		const hit = hits[index];
		lines.push(`${index + 1}. [${hit.title}](${hit.url})`);
		if (hit.snippet) lines.push(`   ${hit.snippet.replace(/\s+/g, " ").trim()}`);
	}

	return lines.join("\n");
}

export function createSearchTool(): ToolDefinition<typeof SearchParamsSchema> {
	return {
		name: "web_search",
		label: "Web Search",
		description:
			"Search via configurable engines (Google, DuckDuckGo, SearXNG, or custom) with ordered fallback. Supports per-call query params and optional formatting of raw HTML responses into markdown or structured JSON.",
		parameters: SearchParamsSchema,

		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			const config = loadConfig();
			const enginesById = new Map(config.search.engines.map((engine) => [engine.id, engine]));

			if (enginesById.size === 0) {
				return {
					content: [{ type: "text", text: "No search engines configured. Add search.engines to ~/.pi/web-tools.json." }],
					details: { error: "No search engines configured" },
				};
			}

			const allowFallback = params.allowFallback ?? true;
			const requestedOrder = params.fallbackOrder?.filter((id) => enginesById.has(id)) ?? [];
			const fallbackOrder = requestedOrder.length > 0 ? requestedOrder : config.search.fallbackOrder;

			let candidateIds: string[] = [];
			if (params.engineId) {
				if (!enginesById.has(params.engineId)) {
					return {
						content: [{ type: "text", text: `Unknown engineId \"${params.engineId}\".` }],
						details: { error: "Unknown engineId", availableEngines: [...enginesById.keys()] },
					};
				}
				candidateIds = [params.engineId];
				if (allowFallback) {
					for (const id of fallbackOrder) {
						if (!candidateIds.includes(id)) candidateIds.push(id);
					}
				}
			} else {
				candidateIds = [...fallbackOrder];
			}

			if (candidateIds.length === 0) {
				return {
					content: [{ type: "text", text: "No candidate engines available after filtering." }],
					details: { error: "No candidate engines" },
				};
			}

			const maxResults = params.maxResults ?? config.search.maxResults;
			const attempts: SearchAttempt[] = [];
			let formattedHtml: string | undefined;
			let rawResponse: string | undefined;

			for (let index = 0; index < candidateIds.length; index += 1) {
				const engineId = candidateIds[index];
				const engine = enginesById.get(engineId);
				if (!engine) continue;
				onUpdate?.({
					content: [{ type: "text", text: `Searching with ${engine.id} (${index + 1}/${candidateIds.length})...` }],
					details: { phase: "search", engineId: engine.id, progress: index / candidateIds.length },
				});
				try {
					const result = await searchWithEngine(params.query, maxResults, engine, params, signal);
					attempts.push({
						engineId,
						ok: true,
						status: result.status,
						resultCount: result.hits.length,
					});
					formattedHtml = result.formattedHtml;
					rawResponse = result.rawResponse;

					if (result.hits.length > 0 || !allowFallback) {
						let output = formatHits(params.query, engineId, result.hits);
						if (formattedHtml) {
							output += `\n\n---\n\n## Raw HTML (${params.rawHtmlFormat})\n\n${formattedHtml}`;
						}
						return {
							content: [{ type: "text", text: output }],
							details: {
								query: params.query,
								engineUsed: engineId,
								resultCount: result.hits.length,
								attempts,
								rawResponse,
							},
						};
					}
				} catch (error) {
					attempts.push({
						engineId,
						ok: false,
						error: error instanceof Error ? error.message : String(error),
					});
				}
			}

			const attemptSummary = attempts
				.map((attempt) => `- ${attempt.engineId}: ${attempt.ok ? `ok (${attempt.resultCount ?? 0} results)` : attempt.error}`)
				.join("\n");

			return {
				content: [
					{
						type: "text",
						text:
							`Search failed or returned no usable results for \`${params.query}\`.\n\nAttempts:\n${attemptSummary}` +
							(formattedHtml ? `\n\nFormatted raw HTML:\n\n${formattedHtml}` : ""),
					},
				],
				details: { query: params.query, attempts, rawResponse },
			};
		},
	};
}
