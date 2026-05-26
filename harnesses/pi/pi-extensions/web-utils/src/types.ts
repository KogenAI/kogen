export type SearchEngineKind = "google" | "duckduckgo" | "searxng" | "custom";

export type ResponseFormat = "auto" | "json" | "html";

export interface SearchEngineConfig {
  id: string;
  kind?: SearchEngineKind;
  enabled?: boolean;
  baseUrl?: string;
  queryParam?: string;
  queryParams?: Record<string, string>;
  headers?: Record<string, string>;
  responseFormat?: ResponseFormat;
  timeoutMs?: number;
}

export interface SearchConfig {
  includeBuiltins?: boolean;
  engines?: SearchEngineConfig[];
  fallbackOrder?: string[];
  maxResults?: number;
  timeoutMs?: number;
  userAgent?: string;
}

export interface MarkdownNewConfig {
  enabled?: boolean;
  baseUrl?: string;
  timeoutMs?: number;
}

export interface FetchConfig {
  timeoutMs?: number;
  maxBodyChars?: number;
  userAgent?: string;
  markdownNew?: MarkdownNewConfig;
}

export interface GitHubConfig {
  enabled?: boolean;
  clonePath?: string;
  cloneTimeoutMs?: number;
  maxRepoSizeMB?: number;
  maxTreeEntries?: number;
  maxInlineFileChars?: number;
}

export interface LocalSearchConfig {
  defaultMaxMatches?: number;
  maxMatches?: number;
  previewChars?: number;
  timeoutMs?: number;
}

export interface WebToolsConfig {
  search?: SearchConfig;
  fetch?: FetchConfig;
  github?: GitHubConfig;
  localSearch?: LocalSearchConfig;
}

export interface ResolvedSearchEngineConfig {
  id: string;
  kind: SearchEngineKind;
  baseUrl: string;
  queryParam: string;
  queryParams: Record<string, string>;
  headers: Record<string, string>;
  responseFormat: ResponseFormat;
  timeoutMs: number;
}

export interface ResolvedSearchConfig {
  engines: ResolvedSearchEngineConfig[];
  fallbackOrder: string[];
  maxResults: number;
  timeoutMs: number;
  userAgent: string;
}

export interface ResolvedFetchConfig {
  timeoutMs: number;
  maxBodyChars: number;
  userAgent: string;
  markdownNew: {
    enabled: boolean;
    baseUrl: string;
    timeoutMs: number;
  };
}

export interface ResolvedGitHubConfig {
  enabled: boolean;
  clonePath: string;
  cloneTimeoutMs: number;
  maxRepoSizeMB: number;
  maxTreeEntries: number;
  maxInlineFileChars: number;
}

export interface ResolvedLocalSearchConfig {
  defaultMaxMatches: number;
  maxMatches: number;
  previewChars: number;
  timeoutMs: number;
}

export interface ResolvedWebToolsConfig {
  search: ResolvedSearchConfig;
  fetch: ResolvedFetchConfig;
  github: ResolvedGitHubConfig;
  localSearch: ResolvedLocalSearchConfig;
}

export interface SearchHit {
  title: string;
  url: string;
  snippet?: string;
}

export interface SearchAttempt {
  engineId: string;
  ok: boolean;
  status?: number;
  error?: string;
  resultCount?: number;
}
