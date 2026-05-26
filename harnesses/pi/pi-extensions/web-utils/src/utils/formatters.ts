import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import TurndownService from "turndown";

const turndown = new TurndownService({
	headingStyle: "atx",
	codeBlockStyle: "fenced",
	emDelimiter: "_",
});

function collapseMarkdown(markdown: string): string {
	return markdown
		.replace(/\r\n/g, "\n")
		.replace(/\n{3,}/g, "\n\n")
		.trim();
}

function toAbsoluteUrl(href: string, baseUrl: string): string {
	try {
		return new URL(href, baseUrl).toString();
	} catch {
		return href;
	}
}

export interface MarkdownExtraction {
	title: string;
	markdown: string;
	method: "readability" | "turndown";
}

export interface StructuredPageData {
	url: string;
	title: string;
	description?: string;
	headings: string[];
	paragraphs: string[];
	links: Array<{ title: string; url: string }>;
}

export function htmlToMarkdown(html: string, url: string): MarkdownExtraction {
	const { document } = parseHTML(html);
	const reader = new Readability(document as unknown as Document, { charThreshold: 80 });
	const parsed = reader.parse();

	if (parsed?.content) {
		const markdown = collapseMarkdown(turndown.turndown(parsed.content));
		if (markdown.length > 0) {
			return {
				title: parsed.title?.trim() || document.title || url,
				markdown,
				method: "readability",
			};
		}
	}

	const fallbackHtml = document.body?.innerHTML || html;
	const markdown = collapseMarkdown(turndown.turndown(fallbackHtml));
	return {
		title: document.title || url,
		markdown,
		method: "turndown",
	};
}

export function htmlToStructuredJson(html: string, url: string): StructuredPageData {
	const { document } = parseHTML(html);
	const title = document.title?.trim() || url;
	const description =
		document.querySelector('meta[name="description"]')?.getAttribute("content")?.trim() || undefined;

	const headingSet = new Set<string>();
	for (const node of Array.from(document.querySelectorAll("h1, h2, h3"))) {
		const text = node.textContent?.trim();
		if (text) headingSet.add(text);
		if (headingSet.size >= 30) break;
	}

	const paragraphs: string[] = [];
	for (const node of Array.from(document.querySelectorAll("p"))) {
		const text = node.textContent?.replace(/\s+/g, " ").trim();
		if (!text || text.length < 40) continue;
		paragraphs.push(text);
		if (paragraphs.length >= 40) break;
	}

	const links: Array<{ title: string; url: string }> = [];
	const seen = new Set<string>();
	for (const anchor of Array.from(document.querySelectorAll("a[href]"))) {
		const href = anchor.getAttribute("href")?.trim();
		if (!href) continue;
		const absolute = toAbsoluteUrl(href, url);
		if (!absolute.startsWith("http://") && !absolute.startsWith("https://")) continue;
		if (seen.has(absolute)) continue;
		seen.add(absolute);
		links.push({ title: anchor.textContent?.trim() || absolute, url: absolute });
		if (links.length >= 120) break;
	}

	return {
		url,
		title,
		description,
		headings: [...headingSet],
		paragraphs,
		links,
	};
}
