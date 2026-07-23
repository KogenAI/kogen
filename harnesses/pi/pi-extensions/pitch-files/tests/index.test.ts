import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

let repoRoot: string;
let originalCwd: string;

function makePi() {
  let registered: {
    execute: (
      id: string,
      params: { source: string; destination: string },
    ) => Promise<{
      content: { type: string; text: string }[];
      details?: unknown;
    }>;
  } | null = null;
  const pi = {
    registerTool: vi.fn((spec: typeof registered) => {
      registered = spec;
    }),
    _getRegistered: () => registered,
  };
  return pi;
}

async function loadExtension(pi: ReturnType<typeof makePi>) {
  const mod = await import("../index.ts");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (mod.default as (pi: any) => void)(pi);
}

beforeEach(() => {
  repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), "pitch-files-index-"));
  fs.mkdirSync(path.join(repoRoot, "codegen", "pitches", "draft"), {
    recursive: true,
  });
  originalCwd = process.cwd();
  process.chdir(repoRoot);
});

afterEach(() => {
  process.chdir(originalCwd);
  fs.rmSync(repoRoot, { recursive: true, force: true });
});

describe("pitch_move tool — end to end via registered execute()", () => {
  it("renames a draft pitch successfully", async () => {
    fs.writeFileSync(
      path.join(repoRoot, "codegen/pitches/draft/old-slug.md"),
      "# X\n",
    );
    const pi = makePi();
    await loadExtension(pi);
    const tool = pi._getRegistered();
    expect(tool).not.toBeNull();

    const result = await tool!.execute("call-1", {
      source: "codegen/pitches/draft/old-slug.md",
      destination: "codegen/pitches/draft/new-slug.md",
    });

    expect(result.content[0].text).toMatch(/^OK: moved/);
    expect(
      fs.existsSync(path.join(repoRoot, "codegen/pitches/draft/old-slug.md")),
    ).toBe(false);
    expect(
      fs.existsSync(path.join(repoRoot, "codegen/pitches/draft/new-slug.md")),
    ).toBe(true);
  });

  it("archives a draft pitch successfully", async () => {
    fs.writeFileSync(
      path.join(repoRoot, "codegen/pitches/draft/to-archive.md"),
      "# Y\n",
    );
    const pi = makePi();
    await loadExtension(pi);
    const tool = pi._getRegistered();

    const result = await tool!.execute("call-2", {
      source: "codegen/pitches/draft/to-archive.md",
      destination: "codegen/pitches/archive/to-archive.md",
    });

    expect(result.content[0].text).toMatch(/^OK: moved/);
    expect(
      fs.existsSync(
        path.join(repoRoot, "codegen/pitches/archive/to-archive.md"),
      ),
    ).toBe(true);
  });

  it("returns a loud error (no mutation) for a lifecycle-directory violation", async () => {
    fs.mkdirSync(path.join(repoRoot, "codegen/pitches/ready"), {
      recursive: true,
    });
    fs.writeFileSync(
      path.join(repoRoot, "codegen/pitches/ready/x.md"),
      "# Z\n",
    );
    const pi = makePi();
    await loadExtension(pi);
    const tool = pi._getRegistered();

    const result = await tool!.execute("call-3", {
      source: "codegen/pitches/ready/x.md",
      destination: "codegen/pitches/draft/x.md",
    });

    expect(result.content[0].text).toMatch(/^Error:/);
    expect(
      fs.existsSync(path.join(repoRoot, "codegen/pitches/ready/x.md")),
    ).toBe(true);
    expect(
      fs.existsSync(path.join(repoRoot, "codegen/pitches/draft/x.md")),
    ).toBe(false);
  });

  it("returns a loud error for a symlinked source without mutating anything", async () => {
    fs.writeFileSync(
      path.join(repoRoot, "codegen/pitches/draft/real.md"),
      "# R\n",
    );
    fs.symlinkSync(
      path.join(repoRoot, "codegen/pitches/draft/real.md"),
      path.join(repoRoot, "codegen/pitches/draft/link.md"),
    );
    const pi = makePi();
    await loadExtension(pi);
    const tool = pi._getRegistered();

    const result = await tool!.execute("call-4", {
      source: "codegen/pitches/draft/link.md",
      destination: "codegen/pitches/draft/out.md",
    });

    expect(result.content[0].text).toMatch(/symlink/);
    expect(
      fs.existsSync(path.join(repoRoot, "codegen/pitches/draft/link.md")),
    ).toBe(true);
  });
});
