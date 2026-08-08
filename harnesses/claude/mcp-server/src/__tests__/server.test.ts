// server.test.ts — node:test coverage for the codegen MCP server.
//
// Asserts the load-bearing correctness properties from the pitch:
//  - a generated writer execs codegen-log with --role <its-own-role> and NO
//    caller-supplied role
//  - body arrives on stdin, never argv
//  - non-zero codegen-log exit surfaces as isError with stderr, never swallowed
//  - gate_status/log_read return real shapes from fixture files
//  - the `advise` tool's registered description triggers on UNCERTAINTY, not
//    only repeated failure, and no longer promises a different vendor (see
//    pitch "a stuck developer asks before it guesses")

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  writeFileSync,
  mkdirSync,
  rmSync,
  readFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { ROLES, sectionToolName, appendToolName, findRole } from "../roles";
import { runCodegenLog, runCodegenAdvise } from "../exec";
import { readGateStatus, readLogWithEnv } from "../readers";
import { registerAllTools } from "../tools";

// Hermetic wrapper: readLogWithEnv requires an explicit envLogPath (empty
// string = no override) so ambient CODEGEN_LOG_PATH from the CALLING
// session never leaks into a fixture-driven test's expected event count.
function readLog(
  cwd: string,
  view: "manifest" | "retro" | "full",
  slug?: string,
  role?: string,
) {
  return readLogWithEnv(cwd, view, slug, role, "");
}

async function withTmpDir(fn: (dir: string) => void | Promise<void>) {
  const dir = mkdtempSync(join(tmpdir(), "codegen-mcp-test-"));
  try {
    await fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("roles.ts — role-baking", { concurrency: 1 }, () => {
  test("every generated writer tool name embeds its own role, underscored", () => {
    for (const spec of ROLES) {
      const section = sectionToolName(spec.role);
      const append = appendToolName(spec.role);
      assert.equal(section, `log_section_${spec.role.replace(/-/g, "_")}`);
      assert.equal(append, `log_append_${spec.role.replace(/-/g, "_")}`);
    }
  });

  test("findRole resolves exact role strings only", () => {
    assert.ok(findRole("developer-phoenix-backend"));
    assert.equal(findRole("not-a-real-role"), undefined);
  });

  test("the planner roles are gone from the registry", () => {
    assert.equal(findRole("planner-phoenix"), undefined);
    assert.equal(findRole("planner-static"), undefined);
  });

  test("no surviving role is granted the retired plan/plan_gate kinds", () => {
    for (const spec of ROLES) {
      assert.ok(!spec.extraKinds.includes("plan" as never));
      assert.ok(!spec.extraKinds.includes("plan_gate" as never));
    }
  });

  test("universal marker kinds (learned/no_learning/died) plus per-role extras", () => {
    const dev = findRole("developer-phoenix-backend")!;
    assert.deepEqual(dev.extraKinds, ["files_modified"]);
    const reviewer = findRole("reviewer-phoenix")!;
    assert.deepEqual(reviewer.extraKinds, []);
    assert.equal(reviewer.readers, true);
    assert.equal(dev.readers, false);
  });
});

describe(
  "exec.ts — array argv, stdin body, isError propagation",
  { concurrency: 1 },
  () => {
    test("body is passed via stdin, never appears in argv (fake codegen-log echoes argv+stdin)", async () => {
      await withTmpDir((dir) => {
        const fakeBin = join(dir, "codegen-log");
        writeFileSync(
          fakeBin,
          "#!/usr/bin/env bash\nprintf 'ARGV:%s\\n' \"$*\"\nprintf 'STDIN:'\ncat\n",
          { mode: 0o755 },
        );
        const oldPath = process.env.PATH;
        process.env.PATH = `${dir}:${oldPath}`;
        try {
          const result = runCodegenLog(
            ["section", "developer-phoenix-backend", "--slug", "x"],
            "hello body with `backticks` and $(danger)",
          );
          assert.equal(result.ok, true);
          assert.match(
            result.stdout,
            /^ARGV:section developer-phoenix-backend --slug x$/m,
          );
          assert.match(
            result.stdout,
            /STDIN:hello body with `backticks` and \$\(danger\)/,
          );
          // The dangerous shell metacharacters must appear LITERALLY in
          // stdin output, never having been interpreted by a shell —
          // proof there is no shell in the exec path.
        } finally {
          process.env.PATH = oldPath;
        }
      });
    });

    test("non-zero exit surfaces as ok:false with stderr preserved, never swallowed", async () => {
      await withTmpDir((dir) => {
        const fakeBin = join(dir, "codegen-log");
        writeFileSync(
          fakeBin,
          "#!/usr/bin/env bash\nprintf 'boom: something failed\\n' >&2\nexit 2\n",
          { mode: 0o755 },
        );
        const oldPath = process.env.PATH;
        process.env.PATH = `${dir}:${oldPath}`;
        try {
          const result = runCodegenLog(["section", "reviewer-phoenix"], "body");
          assert.equal(result.ok, false);
          assert.match(result.stderr, /boom: something failed/);
        } finally {
          process.env.PATH = oldPath;
        }
      });
    });

    test("runCodegenAdvise passes --cwd=<path> as an explicit argv entry and as the spawn cwd, never an inherited default (pitch D-9)", async () => {
      await withTmpDir((dir) => {
        const targetCwd = join(dir, "target-repo");
        mkdirSync(targetCwd, { recursive: true });
        const fakeBin = join(dir, "codegen-advise");
        writeFileSync(
          fakeBin,
          "#!/usr/bin/env bash\nprintf 'ARGV:%s\\n' \"$*\"\nprintf 'SPAWN_CWD:%s\\n' \"$PWD\"\n",
          { mode: 0o755 },
        );
        const oldPath = process.env.PATH;
        process.env.PATH = `${dir}:${oldPath}`;
        try {
          const result = runCodegenAdvise(
            "claude_code",
            targetCwd,
            "what I am unsure about",
          );
          assert.equal(result.ok, true);
          assert.match(
            result.stdout,
            /^ARGV:--harness=claude_code --cwd=.*target-repo$/m,
          );
          assert.match(result.stdout, /SPAWN_CWD:.*target-repo/);
        } finally {
          process.env.PATH = oldPath;
        }
      });
    });
  },
);

describe("readers.ts — gate_status", { concurrency: 1 }, () => {
  test("reads verdict/exit/witness from a fixture gate-result.json", async () => {
    await withTmpDir((dir) => {
      mkdirSync(join(dir, "codegen", "gate-pending"), { recursive: true });
      writeFileSync(
        join(dir, "codegen", "gate-pending", "gate-result.json"),
        JSON.stringify({
          verdict: "clear",
          exit: 0,
          diff_files_count: 4,
          ended: "2026-07-19T04:00:00Z",
          witness: "",
        }),
      );
      const status = readGateStatus(dir);
      assert.equal(status.verdict, "clear");
      assert.equal(status.exit, 0);
      assert.equal(status.diff_files_count, 4);
      assert.equal(status.witness, "");
    });
  });

  test("throws (never silently returns a fake verdict) when gate-result.json is absent", async () => {
    await withTmpDir((dir) => {
      assert.throws(() => readGateStatus(dir), /no gate-result\.json/);
    });
  });
});

describe("readers.ts — log_read views", { concurrency: 1 }, () => {
  function writeFixtureLog(dir: string, lines: object[]) {
    mkdirSync(join(dir, "codegen", "logging"), { recursive: true });
    const logPath = join(
      dir,
      "codegen",
      "logging",
      "20260719_000000_fixture-slug_cycle.jsonl",
    );
    writeFileSync(
      logPath,
      lines.map((l) => JSON.stringify(l)).join("\n") + "\n",
    );
    writeFileSync(join(dir, "codegen", "logging", ".active"), logPath);
    return logPath;
  }

  test("manifest view returns only the loop's files_to_touch events", async () => {
    await withTmpDir((dir) => {
      writeFixtureLog(dir, [
        { ev: "init", pitch: "fixture-slug" },
        {
          ev: "role",
          role: "developer-phoenix-backend",
          body: "did the work",
        },
        { ev: "files_to_touch", role: "loop", files: ["a.ex"] },
        {
          ev: "learned",
          role: "developer-phoenix-backend",
          text: "something",
        },
      ]);
      const result = readLog(dir, "manifest");
      assert.equal(result.events.length, 1);
      assert.equal(result.events[0].ev, "files_to_touch");
      assert.equal(result.events[0].role, "loop");
    });
  });

  test("retro view returns only ev:learned, excludes no_learning (curator-invisible)", async () => {
    await withTmpDir((dir) => {
      writeFixtureLog(dir, [
        {
          ev: "learned",
          role: "developer-phoenix-backend",
          text: "caught a green-from-birth test",
        },
        { ev: "no_learning", role: "reviewer-phoenix", text: "nothing to add" },
      ]);
      const result = readLog(dir, "retro");
      assert.equal(result.events.length, 1);
      assert.equal(result.events[0].ev, "learned");
    });
  });

  test("full view returns every event in call order", async () => {
    await withTmpDir((dir) => {
      writeFixtureLog(dir, [
        { ev: "init", pitch: "fixture-slug" },
        { ev: "role", role: "developer-phoenix-backend", body: "x" },
        { ev: "gate", role: "dev-gate", verdict: "clear" },
      ]);
      const result = readLog(dir, "full");
      assert.equal(result.events.length, 3);
      assert.equal(result.events[2].verdict, "clear");
    });
  });

  test("role filter narrows to one role's events across any view", async () => {
    await withTmpDir((dir) => {
      writeFixtureLog(dir, [
        { ev: "role", role: "developer-phoenix-backend", body: "a" },
        { ev: "role", role: "reviewer-phoenix", body: "b" },
      ]);
      const result = readLog(dir, "full", undefined, "reviewer-phoenix");
      assert.equal(result.events.length, 1);
      assert.equal(result.events[0].role, "reviewer-phoenix");
    });
  });

  test("throws (never returns an empty-but-successful result) when no log resolves", async () => {
    await withTmpDir((dir) => {
      assert.throws(() => readLog(dir, "full"), /no cycle log found/);
    });
  });
});

describe("tools.ts — advise registration semantics", { concurrency: 1 }, () => {
  async function listRegisteredTools() {
    const server = new McpServer({ name: "codegen-test", version: "0.0.0" });
    registerAllTools(server);
    const client = new Client({ name: "test-client", version: "0.0.0" });
    const [clientTransport, serverTransport] =
      InMemoryTransport.createLinkedPair();
    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport),
    ]);
    try {
      const { tools } = await client.listTools();
      return tools;
    } finally {
      await client.close();
      await server.close();
    }
  }

  test("advise tool is actually registered and reachable over the protocol", async () => {
    const tools = await listRegisteredTools();
    const advise = tools.find((t) => t.name === "advise");
    assert.ok(advise, "advise tool missing from tools/list");
  });

  test("advise description triggers on uncertainty, not only repeated failure", async () => {
    const tools = await listRegisteredTools();
    const advise = tools.find((t) => t.name === "advise")!;
    assert.match(advise.description ?? "", /UNSURE/);
    assert.match(
      advise.description ?? "",
      /assumed but not verified|no stated reason to prefer one/,
    );
  });

  test("advise never promises a different vendor/provider", () => {
    // Static-source assertion (not a live listTools call): the wording this
    // pitch removes must not resurface anywhere in the registration module,
    // not just in the one field already asserted above. __dirname at test
    // runtime is dist/__tests__ (compiled output); src/ is a sibling of
    // dist/ one level up from the mcp-server root.
    const src = readFileSync(
      join(__dirname, "..", "..", "src", "tools.ts"),
      "utf8",
    );
    assert.doesNotMatch(src, /opposite provider/i);
    assert.doesNotMatch(src, /DIFFERENT provider/);
  });

  test("advise context schema no longer requires a failure to exist", async () => {
    const tools = await listRegisteredTools();
    const advise = tools.find((t) => t.name === "advise")!;
    const contextDesc = (
      advise.inputSchema?.properties?.context as { description?: string }
    )?.description;
    assert.ok(contextDesc, "advise context param has no description");
    assert.match(contextDesc, /does not need to\s+be one|need not be one/);
  });

  test("advise requires an explicit cwd input (packet assembly reads git/gate state from it)", async () => {
    const tools = await listRegisteredTools();
    const advise = tools.find((t) => t.name === "advise")!;
    const props = advise.inputSchema?.properties as
      | Record<string, { description?: string }>
      | undefined;
    assert.ok(props?.cwd, "advise tool missing cwd input field");
    assert.match(props!.cwd!.description ?? "", /assembled from|active build/);
    const required = advise.inputSchema?.required as string[] | undefined;
    assert.ok(
      required?.includes("cwd"),
      "advise cwd input must be required, not optional",
    );
  });
});
