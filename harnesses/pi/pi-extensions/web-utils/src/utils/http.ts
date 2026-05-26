export interface FetchTextOptions {
	headers?: Record<string, string>;
	method?: "GET" | "POST";
	body?: string;
	timeoutMs?: number;
	signal?: AbortSignal;
}

export interface FetchTextResult {
	url: string;
	status: number;
	ok: boolean;
	contentType: string;
	body: string;
}

function combinedSignal(signal: AbortSignal | undefined, timeoutMs: number | undefined): AbortSignal | undefined {
	const parts: AbortSignal[] = [];
	if (signal) parts.push(signal);
	if (timeoutMs && timeoutMs > 0) parts.push(AbortSignal.timeout(timeoutMs));
	if (parts.length === 0) return undefined;
	if (parts.length === 1) return parts[0];
	if (typeof AbortSignal.any === "function") return AbortSignal.any(parts);

	const controller = new AbortController();
	for (const item of parts) {
		if (item.aborted) {
			controller.abort();
			return controller.signal;
		}
		item.addEventListener("abort", () => controller.abort(), { once: true });
	}
	return controller.signal;
}

export async function fetchText(url: string, options: FetchTextOptions = {}): Promise<FetchTextResult> {
	const response = await fetch(url, {
		method: options.method ?? "GET",
		headers: options.headers,
		body: options.body,
		signal: combinedSignal(options.signal, options.timeoutMs),
		redirect: "follow",
	});
	const body = await response.text();

	return {
		url: response.url,
		status: response.status,
		ok: response.ok,
		contentType: response.headers.get("content-type") ?? "",
		body,
	};
}

export function buildUrl(baseUrl: string, params: Record<string, string | undefined>): string {
	const url = new URL(baseUrl);
	for (const [key, value] of Object.entries(params)) {
		if (value === undefined) continue;
		url.searchParams.set(key, value);
	}
	return url.toString();
}

export function truncateText(value: string, maxChars: number): string {
	if (value.length <= maxChars) return value;
	return `${value.slice(0, maxChars)}\n\n[truncated at ${maxChars} characters]`;
}

export function isProbablyJson(contentType: string, body: string): boolean {
	if (contentType.toLowerCase().includes("json")) return true;
	const trimmed = body.trim();
	return trimmed.startsWith("{") || trimmed.startsWith("[");
}

export function isProbablyHtml(contentType: string, body: string): boolean {
	if (contentType.toLowerCase().includes("html")) return true;
	const sample = body.slice(0, 512).toLowerCase();
	return sample.includes("<html") || sample.includes("<!doctype html") || sample.includes("<body");
}
