// server.test.ts — node:test coverage for the codegen MCP server.
//
// Asserts the load-bearing correctness properties from the pitch:
//  - a generated writer execs codegen-log with --role <its-own-role> and NO
//    caller-supplied role
//  - body arrives on stdin, never argv
//  - non-zero codegen-log exit surfaces as isError with stderr, never swallowed
//  - gate_status/log_read return real shapes from fixture files

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

import { ROLES, sectionToolName, appendToolName, findRole } from "../roles";
import { runCodegenLog } from "../exec";
import { readGateStatus, readLogWithEnv } from "../readers";

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

  test("universal marker kinds (learned/no_learning/died) plus per-role extras", () => {
    const planner = findRole("planner-phoenix")!;
    assert.deepEqual(planner.extraKinds, [
      "plan",
      "plan_gate",
      "files_to_touch",
    ]);
    const dev = findRole("developer-phoenix-backend")!;
    assert.deepEqual(dev.extraKinds, ["files_modified"]);
    const reviewer = findRole("reviewer-phoenix")!;
    assert.deepEqual(reviewer.extraKinds, []);
    assert.equal(reviewer.readers, true);
    assert.equal(planner.readers, false);
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

  test("manifest view returns only plan/plan_gate/files_to_touch events", async () => {
    await withTmpDir((dir) => {
      writeFixtureLog(dir, [
        { ev: "init", pitch: "fixture-slug" },
        { ev: "role", role: "planner-phoenix", body: "did planning" },
        { ev: "plan", role: "planner-phoenix", plan: "the plan text" },
        { ev: "files_to_touch", role: "planner-phoenix", files: ["a.ex"] },
        { ev: "learned", role: "planner-phoenix", text: "something" },
      ]);
      const result = readLog(dir, "manifest");
      assert.equal(result.events.length, 2);
      assert.ok(
        result.events.every((e) => ["plan", "files_to_touch"].includes(e.ev)),
      );
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
        { ev: "role", role: "planner-phoenix", body: "x" },
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
        { ev: "role", role: "planner-phoenix", body: "a" },
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
