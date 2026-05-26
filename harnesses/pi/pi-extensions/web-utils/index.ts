import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { getConfigPathForDisplay } from "./src/config.js";
import { createFetchWebpageTool } from "./src/tools/fetch-page.js";
import {
  createCloneGitHubTool,
  createLocalRepoSearchTool,
  GitHubToolState,
} from "./src/tools/github.js";
import { createSearchTool } from "./src/tools/search.js";

export default function install(pi: ExtensionAPI): void {
  const githubState = new GitHubToolState();

  pi.registerTool(createSearchTool());
  pi.registerTool(createFetchWebpageTool());
  pi.registerTool(createCloneGitHubTool(githubState));
  pi.registerTool(createLocalRepoSearchTool(githubState));

  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.setStatus("pi-web-utils", `config: ${getConfigPathForDisplay()}`);
  });

  const clearState = () => {
    githubState.clear();
  };

  pi.on("session_switch", clearState);
  pi.on("session_fork", clearState);
  pi.on("session_tree", clearState);
  pi.on("session_shutdown", clearState);
}
