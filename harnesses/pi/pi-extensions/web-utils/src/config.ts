import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  ResolvedFetchConfig,
  ResolvedGitHubConfig,
  ResolvedLocalSearchConfig,
  ResolvedSearchConfig,
  ResolvedSearchEngineConfig,
  ResolvedWebToolsConfig,
  SearchEngineConfig,
  SearchEngineKind,
  WebToolsConfig,
} from "./types.js";

const DEFAULT_CONFIG_PATH = join(homedir(), ".pi", "web-tools.json");

const DEFAULT_USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36";

const BUILTIN_ENGINES: Record<
  Exclude<SearchEngineKind, "custom">,
  Omit<ResolvedSearchEngineConfig, "id">
> = {
  searxng: {
    kind: "searxng",
    baseUrl: "https://searx.be/search",
    queryParam: "q",
    queryParams: { format: "json", language: "en-US" },
    headers: {},
    responseFormat: "json",
    timeoutMs: 15000,
  },
  duckduckgo: {
    kind: "duckduckgo",
    baseUrl: "https://duckduckgo.com/html/",
    queryParam: "q",
    queryParams: {},
    headers: {},
    responseFormat: "html",
    timeoutMs: 15000,
  },
  google: {
    kind: "google",
    baseUrl: "https://www.google.com/search",
    queryParam: "q",
    queryParams: { hl: "en" },
    headers: {},
    responseFormat: "html",
    timeoutMs: 15000,
  },
};

function toPositiveInt(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value) && value > 0)
    return Math.floor(value);
  return fallback;
}

function ensureTrailingSlash(value: string): string {
  return value.endsWith("/") ? value : `${value}/`;
}

function inferEngineKind(engine: SearchEngineConfig): SearchEngineKind {
  if (engine.kind) return engine.kind;
  const id = engine.id.trim().toLowerCase();
  if (id === "google") return "google";
  if (id === "duckduckgo") return "duckduckgo";
  if (id === "searxng") return "searxng";
  if (engine.baseUrl?.includes("duckduckgo.com")) return "duckduckgo";
  if (engine.baseUrl?.includes("google.")) return "google";
  if (engine.baseUrl?.toLowerCase().includes("searx")) return "searxng";
  return "custom";
}

function mergeEngine(
  base: SearchEngineConfig | undefined,
  update: SearchEngineConfig,
): SearchEngineConfig {
  return {
    ...base,
    ...update,
    queryParams: {
      ...(base?.queryParams ?? {}),
      ...(update.queryParams ?? {}),
    },
    headers: { ...(base?.headers ?? {}), ...(update.headers ?? {}) },
  };
}

function sanitizeEngine(
  engine: SearchEngineConfig,
): ResolvedSearchEngineConfig | null {
  const kind = inferEngineKind(engine);
  const builtin = kind === "custom" ? undefined : BUILTIN_ENGINES[kind];
  const baseUrl = engine.baseUrl ?? builtin?.baseUrl;
  if (!baseUrl) return null;

  return {
    id: engine.id,
    kind,
    baseUrl,
    queryParam: engine.queryParam ?? builtin?.queryParam ?? "q",
    queryParams: {
      ...(builtin?.queryParams ?? {}),
      ...(engine.queryParams ?? {}),
    },
    headers: { ...(builtin?.headers ?? {}), ...(engine.headers ?? {}) },
    responseFormat: engine.responseFormat ?? builtin?.responseFormat ?? "auto",
    timeoutMs: toPositiveInt(engine.timeoutMs, builtin?.timeoutMs ?? 15000),
  };
}

function resolveSearchConfig(raw: WebToolsConfig): ResolvedSearchConfig {
  const user = raw.search ?? {};
  const includeBuiltins = user.includeBuiltins ?? true;
  const merged = new Map<string, SearchEngineConfig>();

  if (includeBuiltins) {
    for (const [id, defaults] of Object.entries(BUILTIN_ENGINES)) {
      merged.set(id, {
        id,
        kind: defaults.kind,
        baseUrl: defaults.baseUrl,
        queryParam: defaults.queryParam,
        queryParams: { ...defaults.queryParams },
        headers: { ...defaults.headers },
        responseFormat: defaults.responseFormat,
        timeoutMs: defaults.timeoutMs,
      });
    }
  }

  for (const engine of user.engines ?? []) {
    if (!engine?.id || typeof engine.id !== "string") continue;
    const id = engine.id.trim();
    if (!id) continue;
    const existing = merged.get(id);
    merged.set(id, mergeEngine(existing, { ...engine, id }));
  }

  const engines = [...merged.values()]
    .filter((engine) => engine.enabled !== false)
    .map(sanitizeEngine)
    .filter((engine): engine is ResolvedSearchEngineConfig => engine !== null);

  const available = new Set(engines.map((engine) => engine.id));
  let fallbackOrder = (user.fallbackOrder ?? []).filter((id) =>
    available.has(id),
  );
  if (fallbackOrder.length === 0)
    fallbackOrder = engines.map((engine) => engine.id);
  for (const engine of engines) {
    if (!fallbackOrder.includes(engine.id)) fallbackOrder.push(engine.id);
  }

  return {
    engines,
    fallbackOrder,
    maxResults: toPositiveInt(user.maxResults, 8),
    timeoutMs: toPositiveInt(user.timeoutMs, 15000),
    userAgent: user.userAgent ?? DEFAULT_USER_AGENT,
  };
}

function resolveFetchConfig(raw: WebToolsConfig): ResolvedFetchConfig {
  const user = raw.fetch ?? {};
  const markdownNewBase = ensureTrailingSlash(
    user.markdownNew?.baseUrl ?? "https://markdown.new/",
  );

  return {
    timeoutMs: toPositiveInt(user.timeoutMs, 30000),
    maxBodyChars: toPositiveInt(user.maxBodyChars, 120000),
    userAgent: user.userAgent ?? DEFAULT_USER_AGENT,
    markdownNew: {
      enabled: user.markdownNew?.enabled ?? true,
      baseUrl: markdownNewBase,
      timeoutMs: toPositiveInt(user.markdownNew?.timeoutMs, 20000),
    },
  };
}

function resolveGitHubConfig(raw: WebToolsConfig): ResolvedGitHubConfig {
  const user = raw.github ?? {};
  return {
    enabled: user.enabled ?? true,
    clonePath: user.clonePath ?? "/tmp/pi-web-utils/repos",
    cloneTimeoutMs: toPositiveInt(user.cloneTimeoutMs, 30000),
    maxRepoSizeMB: toPositiveInt(user.maxRepoSizeMB, 350),
    maxTreeEntries: toPositiveInt(user.maxTreeEntries, 200),
    maxInlineFileChars: toPositiveInt(user.maxInlineFileChars, 100000),
  };
}

function resolveLocalSearchConfig(
  raw: WebToolsConfig,
): ResolvedLocalSearchConfig {
  const user = raw.localSearch ?? {};
  const maxMatches = toPositiveInt(user.maxMatches, 300);
  const defaultMaxMatches = Math.min(
    toPositiveInt(user.defaultMaxMatches, 80),
    maxMatches,
  );
  return {
    defaultMaxMatches,
    maxMatches,
    previewChars: toPositiveInt(user.previewChars, 220),
    timeoutMs: toPositiveInt(user.timeoutMs, 15000),
  };
}

function configPath(): string {
  const envPath = process.env.PI_WEB_TOOLS_CONFIG?.trim();
  return envPath ? envPath : DEFAULT_CONFIG_PATH;
}

export function loadRawConfig(): WebToolsConfig {
  const path = configPath();
  if (!existsSync(path)) return {};

  try {
    const content = readFileSync(path, "utf-8");
    const parsed = JSON.parse(content);
    if (typeof parsed === "object" && parsed !== null) {
      return parsed as WebToolsConfig;
    }
  } catch {
    // Invalid config should not block tool execution.
  }

  return {};
}

export function loadConfig(): ResolvedWebToolsConfig {
  const raw = loadRawConfig();
  return {
    search: resolveSearchConfig(raw),
    fetch: resolveFetchConfig(raw),
    github: resolveGitHubConfig(raw),
    localSearch: resolveLocalSearchConfig(raw),
  };
}

export function getConfigPathForDisplay(): string {
  return configPath();
}
