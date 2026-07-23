import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { resolveRepoRoot, validateMove } from "../src/paths.ts";

let repoRoot: string;

beforeEach(() => {
  repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), "pitch-files-paths-"));
  fs.mkdirSync(path.join(repoRoot, "codegen", "pitches", "draft"), {
    recursive: true,
  });
});

afterEach(() => {
  fs.rmSync(repoRoot, { recursive: true, force: true });
});

function writePitch(relPath: string, content = "# Pitch\n"): string {
  const abs = path.join(repoRoot, relPath);
  fs.writeFileSync(abs, content);
  return abs;
}

describe("resolveRepoRoot", () => {
  it("realpath-resolves the given cwd", () => {
    const resolved = resolveRepoRoot(repoRoot);
    expect(fs.realpathSync(repoRoot)).toBe(resolved);
  });
});

describe("validateMove — happy paths", () => {
  it("draft -> draft rename validates", () => {
    writePitch("codegen/pitches/draft/my-slug.md");
    const v = validateMove(
      "codegen/pitches/draft/my-slug.md",
      "codegen/pitches/draft/renamed-slug.md",
      repoRoot,
    );
    expect(v.sourceReal).toContain("my-slug.md");
    expect(v.destinationReal).toContain("renamed-slug.md");
  });

  it("draft -> archive validates even when archive/ does not yet exist", () => {
    writePitch("codegen/pitches/draft/my-slug.md");
    const v = validateMove(
      "codegen/pitches/draft/my-slug.md",
      "codegen/pitches/archive/my-slug.md",
      repoRoot,
    );
    expect(v.destinationReal).toContain(path.join("archive", "my-slug.md"));
  });

  it("accepts cwd-prefixed absolute paths", () => {
    writePitch("codegen/pitches/draft/abs-slug.md");
    const v = validateMove(
      path.join(repoRoot, "codegen/pitches/draft/abs-slug.md"),
      path.join(repoRoot, "codegen/pitches/draft/abs-slug-renamed.md"),
      repoRoot,
    );
    expect(v.sourceReal).toContain("abs-slug.md");
  });
});

describe("validateMove — collision", () => {
  it("refuses when destination already exists", () => {
    writePitch("codegen/pitches/draft/a.md");
    writePitch("codegen/pitches/draft/b.md");
    expect(() =>
      validateMove(
        "codegen/pitches/draft/a.md",
        "codegen/pitches/draft/b.md",
        repoRoot,
      ),
    ).toThrow(/already exists/);
  });
});

describe("validateMove — traversal", () => {
  it("refuses a source basename with traversal-shaped slug", () => {
    // basename must match the slug regex; ".." fails the shape check before
    // any directory resolution is attempted.
    expect(() =>
      validateMove(
        "codegen/pitches/draft/../../etc/passwd",
        "codegen/pitches/draft/x.md",
        repoRoot,
      ),
    ).toThrow();
  });

  it("refuses a destination escaping to a sibling directory via ..", () => {
    writePitch("codegen/pitches/draft/a.md");
    expect(() =>
      validateMove(
        "codegen/pitches/draft/a.md",
        "codegen/pitches/draft/../ready/a.md",
        repoRoot,
      ),
    ).toThrow();
  });
});

describe("validateMove — symlink source", () => {
  it("refuses a symlinked source", () => {
    writePitch("codegen/pitches/draft/real.md");
    fs.symlinkSync(
      path.join(repoRoot, "codegen/pitches/draft/real.md"),
      path.join(repoRoot, "codegen/pitches/draft/link.md"),
    );
    expect(() =>
      validateMove(
        "codegen/pitches/draft/link.md",
        "codegen/pitches/draft/out.md",
        repoRoot,
      ),
    ).toThrow(/symlink/);
  });
});

describe("validateMove — lifecycle directory confinement", () => {
  it("refuses source outside draft/", () => {
    fs.mkdirSync(path.join(repoRoot, "codegen", "pitches", "ready"), {
      recursive: true,
    });
    writePitch("codegen/pitches/ready/x.md");
    expect(() =>
      validateMove(
        "codegen/pitches/ready/x.md",
        "codegen/pitches/draft/x.md",
        repoRoot,
      ),
    ).toThrow(/direct child of codegen\/pitches\/draft/);
  });

  it("refuses destination outside draft/ or archive/ (e.g. shipped/)", () => {
    writePitch("codegen/pitches/draft/a.md");
    expect(() =>
      validateMove(
        "codegen/pitches/draft/a.md",
        "codegen/pitches/shipped/a.md",
        repoRoot,
      ),
    ).toThrow(/must be codegen\/pitches\/draft|codegen\/pitches\/archive/);
  });

  it("refuses a non-direct-child destination (nested subdirectory)", () => {
    writePitch("codegen/pitches/draft/a.md");
    expect(() =>
      validateMove(
        "codegen/pitches/draft/a.md",
        "codegen/pitches/draft/nested/a.md",
        repoRoot,
      ),
    ).toThrow();
  });
});

describe("validateMove — same path / invalid slug", () => {
  it("refuses identical source and destination", () => {
    writePitch("codegen/pitches/draft/same.md");
    expect(() =>
      validateMove(
        "codegen/pitches/draft/same.md",
        "codegen/pitches/draft/same.md",
        repoRoot,
      ),
    ).toThrow(/same path/);
  });

  it("refuses an invalid slug shape (uppercase)", () => {
    writePitch("codegen/pitches/draft/a.md");
    expect(() =>
      validateMove(
        "codegen/pitches/draft/a.md",
        "codegen/pitches/draft/Invalid.md",
        repoRoot,
      ),
    ).toThrow(/slug/);
  });

  it("refuses a non-regular source (directory)", () => {
    fs.mkdirSync(path.join(repoRoot, "codegen/pitches/draft/adir.md"));
    expect(() =>
      validateMove(
        "codegen/pitches/draft/adir.md",
        "codegen/pitches/draft/b.md",
        repoRoot,
      ),
    ).toThrow(/regular file|does not exist/);
  });
});
