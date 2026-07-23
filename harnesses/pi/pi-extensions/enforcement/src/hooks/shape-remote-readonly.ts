/**
 * shape-remote-readonly.ts — Pi enforcement twin of shape-remote-readonly.sh.
 *
 * Classifies every top-level `ssh` invocation in shape-mode bash against a
 * closed read-only remote grammar; denies BEFORE ssh ever executes on any
 * unclassified, mutating, or malformed remote payload.
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * GENERATED FROM shared/enforcement/registry.yaml (kind: registration) —
 * header only; this body is hand-authored — see harnesses/claude/hooks/
 * shape-remote-readonly.sh for the full contract this mirrors.
 */

import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, splitCommandSegments, commandWordOfSegment, segmentArgvOf } from "../lib/hook-helpers";
import { resolveRole } from "./_role";

export const HANDLER_META = {
  name: "shape-remote-readonly",
  event: "tool_call",
  matcher: "bash",
} as const;

const REMOTE_ALLOWED_WORD_RE =
  /^(pwd|uname|hostname|id|whoami|date|uptime|getconf|df|du|free|vm_stat|ls|find|stat|file|readlink|realpath|wc|grep|rg|awk|cut|sort|uniq|head|tail|tr|sed|printf|echo|test|ps|pgrep|lsof|ss|netstat|git|dpkg|rpm|apt-cache|brew|npm|pip|pip3|gem|systemctl|journalctl|launchctl|docker|podman|curl|wget|node|python|python3|ruby|elixir|mix|java|go)$/;

function gitIsReadonly(segment: string): boolean {
  // Strip a leading `-C <dir>` / global opt run the same way hooks-lib does:
  // approximate by scanning argv for the first non-flag, non-value token.
  const argv = segmentArgvOf(segment);
  const tokens = argv.split(/\s+/).filter((t) => t.length > 0);
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "-C" || t === "-c") {
      i += 2;
      continue;
    }
    if (t.startsWith("-")) {
      i += 1;
      continue;
    }
    break;
  }
  const sub = tokens[i] ?? "";
  return /^(status|diff|log|show|rev-parse|ls-files|grep)$/.test(sub);
}

function findIsReadonly(segment: string): boolean {
  const argv = segmentArgvOf(segment);
  return !/-delete|-exec|-execdir|-ok\b/.test(argv);
}

function curlIsReadonly(segment: string): boolean {
  const argv = segmentArgvOf(segment);
  if (/-d|--data|--upload-file|-T\b|-o\s|--output|-X\s*(POST|PUT|PATCH|DELETE)/.test(argv)) {
    return false;
  }
  return true;
}

function wgetIsReadonly(segment: string): boolean {
  const argv = segmentArgvOf(segment);
  return /--spider\b/.test(argv);
}

function sedIsReadonly(segment: string): boolean {
  const argv = segmentArgvOf(segment);
  if (/(^|\s)-i\b/.test(argv)) return false;
  return /(^|\s)-n\b/.test(argv);
}

function packageIsQuery(word: string, segment: string): boolean {
  const argv = segmentArgvOf(segment);
  switch (word) {
    case "dpkg":
      return /(^|\s)-l|-s\b/.test(argv);
    case "rpm":
      return /(^|\s)-q/.test(argv);
    case "apt-cache":
      return true;
    case "brew":
      return /^(info|list)\b/.test(argv);
    case "npm":
      return /^(view|list)\b/.test(argv);
    case "pip":
    case "pip3":
      return /^(show|list)\b/.test(argv);
    case "gem":
      return /^list\b/.test(argv);
    default:
      return false;
  }
}

function serviceIsStatus(word: string, segment: string): boolean {
  const argv = segmentArgvOf(segment);
  switch (word) {
    case "systemctl":
      return /^(status|show|is-active|is-enabled)\b/.test(argv);
    case "journalctl":
      return true;
    case "launchctl":
      return /^(print|list)\b/.test(argv);
    case "docker":
    case "podman":
      return /^(ps|inspect|logs|version|info)\b/.test(argv);
    default:
      return false;
  }
}

function runtimeIsVersionOrHelp(segment: string): boolean {
  const argv = segmentArgvOf(segment);
  return argv.length === 0 || /(^|\s)(--version|-v|--help|-h|version)\b/.test(argv);
}

function procNetIsReadonly(word: string, segment: string): boolean {
  const argv = segmentArgvOf(segment);
  switch (word) {
    case "ps":
    case "pgrep":
      return !/(^|\s)(-9|--signal)\b/.test(argv);
    case "lsof":
    case "ss":
    case "netstat":
      return true;
    default:
      return false;
  }
}

/**
 * isRemoteCommandSafe(segment) — classify ONE shell-chain segment of the
 * remote payload against the closed grammar. Tokenizes explicitly (never
 * via commandWordOfSegment's implicit wrapper-eating) so `sudo` WITHOUT
 * `-n` is denied rather than silently unwrapped.
 */
function isRemoteCommandSafe(segment: string): boolean {
  const toks = segment.split(/\s+/).filter((t) => t.length > 0);
  let idx = 0;
  let iterations = 0;
  while (iterations < 5 && idx < toks.length) {
    if (toks[idx] === "sudo") {
      if (toks[idx + 1] !== "-n") return false;
      idx += 2;
    } else if (toks[idx] === "command") {
      idx += 1;
    } else {
      break;
    }
    iterations += 1;
  }
  if (idx >= toks.length) return false;

  const word = toks[idx];
  const rest = toks.slice(idx).join(" ");
  if (!word) return false;

  if (/^(sh|bash|zsh|eval|source|\.)$/.test(word)) {
    return false;
  }

  if (!REMOTE_ALLOWED_WORD_RE.test(word)) {
    return false;
  }

  switch (word) {
    case "git":
      return gitIsReadonly(rest);
    case "find":
      return findIsReadonly(rest);
    case "curl":
      return curlIsReadonly(rest);
    case "wget":
      return wgetIsReadonly(rest);
    case "sed":
      return sedIsReadonly(rest);
    case "dpkg":
    case "rpm":
    case "apt-cache":
    case "brew":
    case "npm":
    case "pip":
    case "pip3":
    case "gem":
      return packageIsQuery(word, rest);
    case "systemctl":
    case "journalctl":
    case "launchctl":
    case "docker":
    case "podman":
      return serviceIsStatus(word, rest);
    case "node":
    case "python":
    case "python3":
    case "ruby":
    case "elixir":
    case "mix":
    case "java":
    case "go":
      return runtimeIsVersionOrHelp(rest);
    case "ps":
    case "pgrep":
    case "lsof":
    case "ss":
    case "netstat":
      return procNetIsReadonly(word, rest);
    default:
      return true;
  }
}

function isRemotePayloadSafe(payload: string): boolean {
  if (payload.trim().length === 0) return false;

  const segments = splitCommandSegments(payload);
  if (segments === null) return false;

  for (const seg of segments) {
    if (seg.trim().length === 0) continue;
    // Redirects, heredocs, backgrounding, command substitution: deny before
    // per-command classification.
    if (/(^|[^><])[<>]|<<|&\s*$|\$\(/.test(seg)) {
      return false;
    }
    if (!isRemoteCommandSafe(seg)) {
      return false;
    }
  }
  return true;
}

function stripOneQuoteLayer(payload: string): string {
  let p = payload.trimStart();
  if (p.startsWith("'") && p.endsWith("'") && p.length >= 2) {
    p = p.slice(1, -1);
  } else if (p.startsWith('"') && p.endsWith('"') && p.length >= 2) {
    p = p.slice(1, -1);
  }
  return p;
}

const sshConfigPath = (): string =>
  process.env["SHAPE_REMOTE_SSH_CONFIG"] ?? path.join(os.homedir(), ".ssh", "config");

function hostIsConfiguredAlias(host: string): boolean {
  const cfgPath = sshConfigPath();
  let content: string;
  try {
    content = fs.readFileSync(cfgPath, "utf8");
  } catch {
    return false;
  }
  const re = new RegExp(`^\\s*Host\\s+${host.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(\\s|$)`, "im");
  return re.test(content);
}

function resolveHostConfig(host: string): { ok: true; config: string } | { ok: false } {
  const cfgPath = sshConfigPath();
  try {
    const out = execFileSync("ssh", ["-F", cfgPath, "-G", host], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    return { ok: true, config: out };
  } catch {
    return { ok: false };
  }
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const role = resolveRole();
    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("shape-remote-readonly", `role=${role} cmd=${command}`);

    if (role !== "shape") return;

    const segments = splitCommandSegments(command);
    if (segments === null) {
      if (/(^|[\s;&|])ssh\b/.test(command)) {
        return deny(
          "BLOCKED by shape-remote-readonly: unbalanced quoting in a command containing ssh — cannot classify, denying closed",
        );
      }
      return;
    }

    for (const seg of segments) {
      if (seg.trim().length === 0) continue;
      const word = commandWordOfSegment(seg);
      if (word !== "ssh") continue;

      const argv = segmentArgvOf(seg);
      const tokens = argv.split(/\s+/).filter((t) => t.length > 0);

      let host = "";
      const payloadTokens: string[] = [];
      let ok = true;
      let i = 0;
      while (i < tokens.length) {
        const tok = tokens[i];
        if (!host) {
          if (tok === "-n" || tok === "-T") {
            i += 1;
            continue;
          }
          if (tok === "-o") {
            const next = tokens[i + 1] ?? "";
            if (next === "BatchMode=yes") {
              // ok
            } else if (next.startsWith("ConnectTimeout=")) {
              const val = Number(next.slice("ConnectTimeout=".length));
              if (!(val >= 1 && val <= 30)) ok = false;
            } else if (next.startsWith("ServerAliveInterval=")) {
              const val = Number(next.slice("ServerAliveInterval=".length));
              if (!(val >= 1 && val <= 30)) ok = false;
            } else if (next.startsWith("ServerAliveCountMax=")) {
              const val = Number(next.slice("ServerAliveCountMax=".length));
              if (!(val >= 1 && val <= 3)) ok = false;
            } else {
              ok = false;
            }
            i += 2;
            continue;
          }
          if (tok.startsWith("-")) {
            ok = false;
            i += 1;
            continue;
          }
          host = tok;
          i += 1;
          continue;
        }
        payloadTokens.push(tok);
        i += 1;
      }

      if (!ok || !host) {
        return deny(
          "BLOCKED by shape-remote-readonly: unrecognized SSH flag, malformed option value, or missing host — denying closed",
        );
      }

      if (/[*?]/.test(host)) {
        return deny(`BLOCKED by shape-remote-readonly: wildcard host pattern not permitted: ${host}`);
      }
      if (!hostIsConfiguredAlias(host)) {
        return deny(`BLOCKED by shape-remote-readonly: host is not a literal alias declared in ~/.ssh/config: ${host}`);
      }
      const resolved = resolveHostConfig(host);
      if (!resolved.ok) {
        return deny(`BLOCKED by shape-remote-readonly: ssh -G failed to resolve host config for ${host} — denying closed`);
      }
      if (/^proxycommand\s+\S/im.test(resolved.config)) {
        return deny(`BLOCKED by shape-remote-readonly: resolved host config declares a ProxyCommand — denying closed: ${host}`);
      }

      const payload = stripOneQuoteLayer(payloadTokens.join(" "));
      if (!isRemotePayloadSafe(payload)) {
        return deny(
          `BLOCKED by shape-remote-readonly: remote command payload is not in the closed read-only grammar — denying closed before ssh executes: ${payload}`,
        );
      }
    }
  });
}
