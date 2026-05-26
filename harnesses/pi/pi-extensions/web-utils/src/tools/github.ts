import { Type, type Static } from "@sinclair/typebox";
import type {
  ExtensionContext,
  ToolDefinition,
} from "@mariozechner/pi-coding-agent";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  openSync,
  closeSync,
  readSync,
} from "node:fs";
import {
  basename,
  extname,
  isAbsolute,
  join,
  normalize,
  relative,
  resolve,
} from "node:path";
import { loadConfig } from "../config.js";
import { execFileAsync, isRgAvailable } from "../utils/process.js";

const CloneRepoParamsSchema = Type.Object({
  url: Type.String({ description: "GitHub URL to clone or inspect" }),
  forceClone: Type.Optional(
    Type.Boolean({ description: "Clone even when repo exceeds maxRepoSizeMB" }),
  ),
  refresh: Type.Optional(
    Type.Boolean({ description: "Delete existing cached clone and reclone" }),
  ),
  maxTreeEntries: Type.Optional(
    Type.Integer({
      minimum: 20,
      maximum: 2000,
      description: "Tree/listing limit",
    }),
  ),
});

const LocalSearchParamsSchema = Type.Object({
  query: Type.String({ description: "Text or regex to search for" }),
  repo: Type.Optional(
    Type.String({
      description:
        "Repo key from clone_github_repo, e.g. owner/repo or owner/repo@branch",
    }),
  ),
  path: Type.Optional(
    Type.String({
      description:
        "Directory path to search. Relative paths resolve from selected repo root (or current cwd).",
    }),
  ),
  glob: Type.Optional(
    Type.String({ description: "Optional include glob, passed to rg -g" }),
  ),
  maxMatches: Type.Optional(
    Type.Integer({
      minimum: 1,
      maximum: 1000,
      description: "Maximum matches to return",
    }),
  ),
  caseSensitive: Type.Optional(
    Type.Boolean({ description: "Use case-sensitive matching" }),
  ),
});

type CloneRepoParams = Static<typeof CloneRepoParamsSchema>;
type LocalSearchParams = Static<typeof LocalSearchParamsSchema>;

interface GitHubUrlInfo {
  owner: string;
  repo: string;
  ref?: string;
  refIsFullSha: boolean;
  path?: string;
  type: "root" | "blob" | "tree";
}

interface CloneRecord {
  key: string;
  owner: string;
  repo: string;
  ref?: string;
  localPath: string;
}

interface SearchMatch {
  file: string;
  line: number;
  column: number;
  text: string;
}

const NOISE_DIRS = new Set([
  ".git",
  "node_modules",
  "dist",
  "build",
  ".next",
  "target",
  "vendor",
  "__pycache__",
  "venv",
  ".venv",
]);

const BINARY_EXTENSIONS = new Set([
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".bmp",
  ".ico",
  ".webp",
  ".svg",
  ".pdf",
  ".zip",
  ".gz",
  ".tar",
  ".mp4",
  ".mov",
  ".mkv",
  ".avi",
  ".woff",
  ".woff2",
  ".ttf",
  ".otf",
  ".jar",
  ".class",
  ".exe",
  ".dll",
  ".so",
  ".dylib",
]);

const NON_CODE_SEGMENTS = new Set([
  "issues",
  "pull",
  "pulls",
  "discussions",
  "releases",
  "wiki",
  "actions",
  "settings",
  "security",
  "projects",
  "graphs",
  "compare",
  "commit",
  "commits",
  "tags",
  "branches",
  "stargazers",
  "watchers",
  "network",
  "forks",
  "milestone",
  "labels",
  "packages",
  "codespaces",
  "insights",
]);

function cacheKey(owner: string, repo: string, ref?: string): string {
  return ref ? `${owner}/${repo}@${ref}` : `${owner}/${repo}`;
}

function safeRef(ref?: string): string {
  if (!ref) return "default";
  return ref.replaceAll(/[^a-zA-Z0-9._-]/g, "_");
}

function clonePathFor(
  owner: string,
  repo: string,
  ref: string | undefined,
): string {
  const config = loadConfig();
  const repoSegment = ref ? `${repo}@${safeRef(ref)}` : repo;
  return join(config.github.clonePath, owner, repoSegment);
}

function parseGitHubUrl(url: string): GitHubUrlInfo | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }

  if (parsed.hostname !== "github.com") return null;
  const segments = parsed.pathname.split("/").filter(Boolean);
  if (segments.length < 2) return null;

  const owner = segments[0];
  const repo = segments[1].replace(/\.git$/, "");
  if (!owner || !repo) return null;
  if (NON_CODE_SEGMENTS.has((segments[2] ?? "").toLowerCase())) return null;

  if (segments.length === 2) {
    return { owner, repo, type: "root", refIsFullSha: false };
  }

  const action = segments[2];
  if (action !== "blob" && action !== "tree") {
    return { owner, repo, type: "root", refIsFullSha: false };
  }
  if (segments.length < 4) return null;

  const ref = segments[3];
  const refIsFullSha = /^[0-9a-f]{40}$/i.test(ref);
  const path = segments.slice(4).join("/");
  return {
    owner,
    repo,
    ref,
    refIsFullSha,
    type: action as "blob" | "tree",
    path,
  };
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function isBinaryFile(filePath: string): boolean {
  if (BINARY_EXTENSIONS.has(extname(filePath).toLowerCase())) return true;

  let fd: number;
  try {
    fd = openSync(filePath, "r");
  } catch {
    return false;
  }
  try {
    const buffer = Buffer.alloc(512);
    const bytesRead = readSync(fd, buffer, 0, buffer.length, 0);
    for (let index = 0; index < bytesRead; index += 1) {
      if (buffer[index] === 0) return true;
    }
  } catch {
    return false;
  } finally {
    closeSync(fd);
  }

  return false;
}

function resolveInsideRoot(
  root: string,
  relPath: string | undefined,
): string | null {
  const relativePath = relPath ?? "";
  const resolvedRoot = resolve(root);
  const fullPath = resolve(resolvedRoot, relativePath);
  const rel = relative(resolvedRoot, fullPath);
  if (rel.startsWith("..") || isAbsolute(rel)) return null;
  return fullPath;
}

function readReadme(localPath: string): string | null {
  const names = [
    "README.md",
    "README",
    "README.txt",
    "readme.md",
    "README.rst",
  ];
  for (const name of names) {
    const readmePath = join(localPath, name);
    if (!existsSync(readmePath)) continue;
    try {
      const content = readFileSync(readmePath, "utf-8");
      return content.length > 12000
        ? `${content.slice(0, 12000)}\n\n[README truncated]`
        : content;
    } catch {
      return null;
    }
  }
  return null;
}

function buildTree(rootPath: string, maxEntries: number): string {
  const entries: string[] = [];

  function walk(current: string, rel: string): void {
    if (entries.length >= maxEntries) return;
    let names: string[];
    try {
      names = readdirSync(current).sort();
    } catch {
      return;
    }

    for (const name of names) {
      if (entries.length >= maxEntries) break;
      if (name === ".git") continue;
      const full = join(current, name);
      let stats;
      try {
        stats = statSync(full);
      } catch {
        continue;
      }
      const nextRel = rel ? `${rel}/${name}` : name;
      if (stats.isDirectory()) {
        if (NOISE_DIRS.has(name)) {
          entries.push(`${nextRel}/  [skipped]`);
          continue;
        }
        entries.push(`${nextRel}/`);
        walk(full, nextRel);
      } else {
        entries.push(nextRel);
      }
    }
  }

  walk(rootPath, "");
  if (entries.length >= maxEntries)
    entries.push(`... (truncated at ${maxEntries} entries)`);
  return entries.join("\n");
}

function buildDirListing(
  rootPath: string,
  dirPath: string,
  maxEntries: number,
): string {
  const full = resolveInsideRoot(rootPath, dirPath);
  if (!full || !existsSync(full)) return "(directory not found)";

  const lines: string[] = [];
  let names: string[];
  try {
    names = readdirSync(full).sort();
  } catch {
    return "(directory unreadable)";
  }

  for (const name of names.slice(0, maxEntries)) {
    if (name === ".git") continue;
    const itemPath = join(full, name);
    try {
      const stats = statSync(itemPath);
      if (stats.isDirectory()) lines.push(`${name}/`);
      else lines.push(`${name} (${formatSize(stats.size)})`);
    } catch {
      lines.push(`${name} (unreadable)`);
    }
  }

  if (names.length > maxEntries)
    lines.push(`... (${names.length - maxEntries} more entries)`);
  return lines.map((line) => `  ${line}`).join("\n");
}

function renderClonePreview(
  localPath: string,
  info: GitHubUrlInfo,
  maxTreeEntries: number,
): string {
  const config = loadConfig();
  const lines: string[] = [];
  lines.push(`Repository cloned to: ${localPath}`);
  lines.push("");

  if (info.type === "root") {
    lines.push("## Structure");
    lines.push(buildTree(localPath, maxTreeEntries));
    lines.push("");
    const readme = readReadme(localPath);
    if (readme) {
      lines.push("## README");
      lines.push(readme);
      lines.push("");
    }
    lines.push("Use read/bash/search_local_repo tools for deeper inspection.");
    return lines.join("\n");
  }

  if (info.type === "tree") {
    const subPath = info.path ?? "";
    lines.push(`## ${subPath || "/"}`);
    lines.push(buildDirListing(localPath, subPath, maxTreeEntries));
    lines.push("");
    lines.push("Use read/bash/search_local_repo tools for deeper inspection.");
    return lines.join("\n");
  }

  const subPath = info.path ?? "";
  const filePath = resolveInsideRoot(localPath, subPath);
  if (!filePath || !existsSync(filePath)) {
    lines.push(`Path \`${subPath}\` not found in clone.`);
    lines.push("");
    lines.push("## Structure");
    lines.push(buildTree(localPath, maxTreeEntries));
    return lines.join("\n");
  }

  const stats = statSync(filePath);
  if (stats.isDirectory()) {
    lines.push(`## ${subPath}/`);
    lines.push(buildDirListing(localPath, subPath, maxTreeEntries));
    lines.push("");
    lines.push("Use read/bash/search_local_repo tools for deeper inspection.");
    return lines.join("\n");
  }

  if (isBinaryFile(filePath)) {
    lines.push(`## ${subPath}`);
    lines.push(
      `Binary file (${formatSize(stats.size)}). Inspect with read or bash if needed.`,
    );
    return lines.join("\n");
  }

  let content = "";
  try {
    content = readFileSync(filePath, "utf-8");
  } catch {
    content = "(file unreadable)";
  }
  if (content.length > config.github.maxInlineFileChars) {
    content = `${content.slice(0, config.github.maxInlineFileChars)}\n\n[file truncated]`;
  }
  lines.push(`## ${subPath}`);
  lines.push(content);
  lines.push("");
  lines.push("Use read/bash/search_local_repo tools for deeper inspection.");
  return lines.join("\n");
}

async function githubApi(
  path: string,
  signal?: AbortSignal,
): Promise<unknown | null> {
  const response = await fetch(`https://api.github.com${path}`, {
    headers: {
      accept: "application/vnd.github+json",
      "user-agent": "pi-web-utils",
    },
    signal,
  });
  if (!response.ok) return null;
  try {
    return await response.json();
  } catch {
    return null;
  }
}

async function fetchRepoSizeMB(
  owner: string,
  repo: string,
  signal?: AbortSignal,
): Promise<number | null> {
  const data = await githubApi(`/repos/${owner}/${repo}`, signal);
  if (!data || typeof data !== "object") return null;
  const sizeKb = (data as Record<string, unknown>).size;
  if (typeof sizeKb !== "number") return null;
  return sizeKb / 1024;
}

async function fetchDefaultBranch(
  owner: string,
  repo: string,
  signal?: AbortSignal,
): Promise<string | null> {
  const data = await githubApi(`/repos/${owner}/${repo}`, signal);
  if (!data || typeof data !== "object") return null;
  const branch = (data as Record<string, unknown>).default_branch;
  return typeof branch === "string" && branch ? branch : null;
}

function decodeBase64(value: string): string {
  return Buffer.from(value.replaceAll("\n", ""), "base64").toString("utf-8");
}

async function fetchViaApiPreview(
  url: string,
  info: GitHubUrlInfo,
  signal: AbortSignal | undefined,
  note?: string,
): Promise<{ text: string; details: Record<string, unknown> } | null> {
  const config = loadConfig();
  const ref =
    info.ref || (await fetchDefaultBranch(info.owner, info.repo, signal));
  if (!ref) return null;

  const lines: string[] = [];
  if (note) {
    lines.push(note);
    lines.push("");
  }

  if (info.type === "blob" && info.path) {
    const file = await githubApi(
      `/repos/${info.owner}/${info.repo}/contents/${info.path}?ref=${encodeURIComponent(ref)}`,
      signal,
    );
    if (!file || typeof file !== "object") return null;
    const fileRecord = file as Record<string, unknown>;
    if (typeof fileRecord.content !== "string") return null;
    let decoded = decodeBase64(fileRecord.content);
    if (decoded.length > config.github.maxInlineFileChars) {
      decoded = `${decoded.slice(0, config.github.maxInlineFileChars)}\n\n[file truncated]`;
    }
    lines.push(`## ${info.path}`);
    lines.push(decoded);
    return {
      text: lines.join("\n"),
      details: { source: "github-api", ref, url },
    };
  }

  const tree = await githubApi(
    `/repos/${info.owner}/${info.repo}/git/trees/${encodeURIComponent(ref)}?recursive=1`,
    signal,
  );
  if (!tree || typeof tree !== "object") return null;
  const treeItems = (tree as Record<string, unknown>).tree;
  if (!Array.isArray(treeItems)) return null;

  lines.push("## Structure");
  const paths: string[] = [];
  for (const item of treeItems) {
    if (typeof item !== "object" || item === null) continue;
    const path = (item as Record<string, unknown>).path;
    if (typeof path !== "string") continue;
    paths.push(path);
    if (paths.length >= config.github.maxTreeEntries) break;
  }
  lines.push(paths.join("\n") || "(no paths)");

  const readme = await githubApi(
    `/repos/${info.owner}/${info.repo}/readme?ref=${encodeURIComponent(ref)}`,
    signal,
  );
  if (
    readme &&
    typeof readme === "object" &&
    typeof (readme as Record<string, unknown>).content === "string"
  ) {
    lines.push("");
    lines.push("## README");
    lines.push(
      decodeBase64((readme as Record<string, unknown>).content as string),
    );
  }

  lines.push("");
  lines.push(
    "API preview only. Use forceClone: true to clone the repository locally.",
  );

  return {
    text: lines.join("\n"),
    details: { source: "github-api", ref, url },
  };
}

export class GitHubToolState {
  private clones = new Map<string, CloneRecord>();
  private latestCloneKey: string | undefined;

  clear(): void {
    for (const clone of this.clones.values()) {
      try {
        rmSync(clone.localPath, { recursive: true, force: true });
      } catch {
        // best effort
      }
    }
    this.clones.clear();
    this.latestCloneKey = undefined;
  }

  private pickClone(repo?: string): CloneRecord | undefined {
    if (!repo) {
      if (!this.latestCloneKey) return undefined;
      return this.clones.get(this.latestCloneKey);
    }

    const direct = this.clones.get(repo);
    if (direct) return direct;

    for (const clone of this.clones.values()) {
      if (clone.key === repo) return clone;
      if (`${clone.owner}/${clone.repo}` === repo) return clone;
    }
    return undefined;
  }

  private rememberClone(record: CloneRecord): void {
    this.clones.set(record.key, record);
    this.latestCloneKey = record.key;
  }

  async cloneFromUrl(
    params: CloneRepoParams,
    signal: AbortSignal | undefined,
  ): Promise<{ text: string; details: Record<string, unknown> }> {
    const config = loadConfig();
    if (!config.github.enabled) {
      return {
        text: "GitHub cloning is disabled in config.github.enabled.",
        details: { error: "github cloning disabled" },
      };
    }

    const info = parseGitHubUrl(params.url);
    if (!info) {
      return {
        text: "URL is not a supported GitHub repository/tree/blob URL.",
        details: { error: "invalid github url" },
      };
    }

    const key = cacheKey(info.owner, info.repo, info.ref);
    const localPath = clonePathFor(info.owner, info.repo, info.ref);
    const maxTreeEntries =
      params.maxTreeEntries ?? config.github.maxTreeEntries;

    if (!params.refresh) {
      const cached = this.clones.get(key);
      if (cached && existsSync(cached.localPath)) {
        this.latestCloneKey = key;
        return {
          text: renderClonePreview(cached.localPath, info, maxTreeEntries),
          details: { key, localPath: cached.localPath, cached: true },
        };
      }
    }

    if (!params.forceClone) {
      const sizeMb = await fetchRepoSizeMB(info.owner, info.repo, signal);
      if (sizeMb !== null && sizeMb > config.github.maxRepoSizeMB) {
        const preview = await fetchViaApiPreview(
          params.url,
          info,
          signal,
          `Repository is ${Math.round(sizeMb)}MB (limit ${config.github.maxRepoSizeMB}MB). Returning API preview instead of cloning.`,
        );
        if (preview) return preview;
        return {
          text: `Repository is ${Math.round(sizeMb)}MB and API preview failed. Retry with forceClone: true if you want to clone anyway.`,
          details: { error: "repo too large", sizeMb },
        };
      }
    }

    if (info.refIsFullSha) {
      const preview = await fetchViaApiPreview(
        params.url,
        info,
        signal,
        "Commit SHA URLs are served via GitHub API preview.",
      );
      if (preview) return preview;
      return {
        text: "Commit SHA URL detected and API preview failed.",
        details: { error: "sha preview failed" },
      };
    }

    mkdirSync(join(config.github.clonePath, info.owner), { recursive: true });
    rmSync(localPath, { recursive: true, force: true });

    const args = ["clone", "--depth", "1", "--single-branch"];
    if (info.ref) args.push("--branch", info.ref);
    args.push(`https://github.com/${info.owner}/${info.repo}.git`, localPath);

    const result = await execFileAsync("git", args, {
      timeoutMs: config.github.cloneTimeoutMs,
      signal,
    });

    if (result.code !== 0 || !existsSync(localPath)) {
      const preview = await fetchViaApiPreview(
        params.url,
        info,
        signal,
        `Clone failed (${result.stderr.trim() || "unknown error"}). Returning API preview instead.`,
      );
      if (preview) return preview;
      return {
        text: `Clone failed: ${result.stderr || result.stdout || "unknown error"}`,
        details: {
          error: "clone failed",
          stderr: result.stderr,
          stdout: result.stdout,
        },
      };
    }

    const record: CloneRecord = {
      key,
      owner: info.owner,
      repo: info.repo,
      ref: info.ref,
      localPath,
    };
    this.rememberClone(record);

    return {
      text: renderClonePreview(localPath, info, maxTreeEntries),
      details: { key, localPath, cached: false, cloned: true },
    };
  }

  async searchLocal(
    params: LocalSearchParams,
    ctx: ExtensionContext,
    signal: AbortSignal | undefined,
  ): Promise<{ text: string; details: Record<string, unknown> }> {
    const config = loadConfig();
    const selectedClone = this.pickClone(params.repo);

    let root = selectedClone?.localPath ?? ctx.cwd;
    if (params.path) {
      if (isAbsolute(params.path)) {
        root = params.path;
      } else {
        root = resolve(root, params.path);
      }
    }

    if (!existsSync(root)) {
      return {
        text: `Search path does not exist: ${root}`,
        details: { error: "missing path", root },
      };
    }

    const stats = statSync(root);
    if (!stats.isDirectory()) {
      return {
        text: `Search path is not a directory: ${root}`,
        details: { error: "not a directory", root },
      };
    }

    const maxMatches = Math.min(
      params.maxMatches ?? config.localSearch.defaultMaxMatches,
      config.localSearch.maxMatches,
    );
    const caseSensitive = params.caseSensitive ?? false;
    const rgResults = await this.searchWithRg(
      params.query,
      root,
      maxMatches,
      caseSensitive,
      params.glob,
      signal,
    );

    let matches: SearchMatch[] = [];
    let engine = "rg";
    if (rgResults.kind === "ok") {
      matches = rgResults.matches;
    } else if (rgResults.kind === "unavailable") {
      engine = "grep";
      matches = await this.searchWithGrep(
        params.query,
        root,
        maxMatches,
        caseSensitive,
        signal,
      );
    } else {
      return {
        text: rgResults.error,
        details: { error: rgResults.error, root },
      };
    }

    const lines: string[] = [];
    lines.push("## Local Search Results");
    lines.push("");
    lines.push(`Query: \`${params.query}\``);
    lines.push(`Root: \`${root}\``);
    if (selectedClone) lines.push(`Repo: \`${selectedClone.key}\``);
    lines.push(`Engine: \`${engine}\``);
    lines.push(
      `Matches: ${matches.length}${matches.length >= maxMatches ? ` (truncated to ${maxMatches})` : ""}`,
    );
    lines.push("");

    if (matches.length === 0) {
      lines.push("No matches found.");
    } else {
      for (let index = 0; index < matches.length; index += 1) {
        const match = matches[index];
        const file = match.file.startsWith(root)
          ? relative(root, match.file) || basename(match.file)
          : match.file;
        lines.push(`${index + 1}. \`${file}:${match.line}:${match.column}\``);
        lines.push(`   ${match.text}`);
      }
    }

    return {
      text: lines.join("\n"),
      details: {
        root,
        query: params.query,
        matchCount: matches.length,
        repo: selectedClone?.key,
        engine,
      },
    };
  }

  private async searchWithRg(
    query: string,
    root: string,
    maxMatches: number,
    caseSensitive: boolean,
    glob: string | undefined,
    signal: AbortSignal | undefined,
  ): Promise<
    | { kind: "ok"; matches: SearchMatch[] }
    | { kind: "unavailable" }
    | { kind: "error"; error: string }
  > {
    if (!(await isRgAvailable())) return { kind: "unavailable" };

    const config = loadConfig();
    const args = [
      "--json",
      "--line-number",
      "--column",
      "--max-count",
      String(maxMatches),
    ];
    if (caseSensitive) args.push("--case-sensitive");
    else args.push("--smart-case");
    if (glob) args.push("-g", glob);
    args.push(query, root);

    const result = await execFileAsync("rg", args, {
      timeoutMs: config.localSearch.timeoutMs,
      signal,
      maxBuffer: 20 * 1024 * 1024,
    });

    if (result.code !== 0 && result.code !== 1) {
      return {
        kind: "error",
        error: `rg failed: ${result.stderr || result.stdout}`,
      };
    }

    const previewChars = config.localSearch.previewChars;
    const matches: SearchMatch[] = [];
    for (const line of result.stdout.split("\n")) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line) as Record<string, unknown>;
        if (event.type !== "match") continue;
        const data = event.data as Record<string, unknown>;
        const pathObj = data.path as { text?: string };
        const linesObj = data.lines as { text?: string };
        const submatches = Array.isArray(data.submatches)
          ? (data.submatches as Array<{ start?: number }>)
          : [];
        const lineNumber =
          typeof data.line_number === "number" ? data.line_number : 0;
        matches.push({
          file: pathObj?.text ?? "",
          line: lineNumber,
          column: (submatches[0]?.start ?? 0) + 1,
          text: (linesObj?.text ?? "").trim().slice(0, previewChars),
        });
        if (matches.length >= maxMatches) break;
      } catch {
        // skip malformed lines
      }
    }
    return { kind: "ok", matches };
  }

  private async searchWithGrep(
    query: string,
    root: string,
    maxMatches: number,
    caseSensitive: boolean,
    signal: AbortSignal | undefined,
  ): Promise<SearchMatch[]> {
    const config = loadConfig();
    const args = ["-RIn", "--exclude-dir=.git", "--binary-files=without-match"];
    if (!caseSensitive) args.push("-i");
    args.push("--", query, root);

    const result = await execFileAsync("grep", args, {
      timeoutMs: config.localSearch.timeoutMs,
      signal,
      maxBuffer: 20 * 1024 * 1024,
    });
    if (result.code !== 0 && result.code !== 1) return [];

    const matches: SearchMatch[] = [];
    for (const line of result.stdout.split("\n")) {
      if (!line.trim()) continue;
      const first = line.indexOf(":");
      if (first < 0) continue;
      const second = line.indexOf(":", first + 1);
      if (second < 0) continue;
      const file = line.slice(0, first);
      const lineNumber = Number.parseInt(line.slice(first + 1, second), 10);
      const text = line
        .slice(second + 1)
        .trim()
        .slice(0, config.localSearch.previewChars);
      matches.push({
        file,
        line: Number.isFinite(lineNumber) ? lineNumber : 0,
        column: 1,
        text,
      });
      if (matches.length >= maxMatches) break;
    }

    return matches;
  }
}

export function createCloneGitHubTool(
  state: GitHubToolState,
): ToolDefinition<typeof CloneRepoParamsSchema> {
  return {
    name: "clone_github_repo",
    label: "Clone GitHub Repo",
    description:
      "Clone and inspect GitHub repositories from root/tree/blob URLs. Returns local path plus a preview so the agent can continue exploration with read/bash/local search.",
    parameters: CloneRepoParamsSchema,
    async execute(_toolCallId, params, signal, onUpdate) {
      onUpdate?.({
        content: [
          { type: "text", text: "Resolving GitHub URL and cloning..." },
        ],
        details: { phase: "clone" },
      });
      const result = await state.cloneFromUrl(params, signal);
      return {
        content: [{ type: "text", text: result.text }],
        details: result.details,
      };
    },
  };
}

export function createLocalRepoSearchTool(
  state: GitHubToolState,
): ToolDefinition<typeof LocalSearchParamsSchema> {
  return {
    name: "search_local_repo",
    label: "Search Local Repo",
    description:
      "Search cloned repositories (or any local directory) with ripgrep and return file/line matches. Defaults to the latest cloned repository.",
    parameters: LocalSearchParamsSchema,
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      onUpdate?.({
        content: [{ type: "text", text: "Searching local repository..." }],
        details: { phase: "search" },
      });
      const result = await state.searchLocal(params, ctx, signal);
      return {
        content: [{ type: "text", text: result.text }],
        details: result.details,
      };
    },
  };
}
