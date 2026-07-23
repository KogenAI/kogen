import * as fs from "node:fs";
import * as path from "node:path";

/**
 * Validated, canonicalized move targets. Both paths already confirmed to be
 * direct children of the correct lifecycle directories, non-symlink, and
 * (for source) an existing regular file.
 */
export type ValidatedMove = {
  sourceReal: string;
  destinationReal: string;
};

const SLUG_RE = /^[a-z0-9]+(-[a-z0-9]+)*\.md$/;

function isDirectChildSlug(basename: string): boolean {
  return SLUG_RE.test(basename);
}

/**
 * Validate a pitch_move(source, destination) request against the confined
 * lifecycle-directory contract. Throws (never returns a partial/ambiguous
 * result) on any violation — traversal, non-draft source dir, non-draft/
 * non-archive destination dir, symlink, non-regular source, same path,
 * invalid slug shape, or canonical-parent escape.
 *
 * repoRoot MUST be the canonical (realpath'd) repository root — the caller
 * resolves this once from the launcher-normalized cwd.
 */
export function validateMove(
  source: string,
  destination: string,
  repoRoot: string,
): ValidatedMove {
  const draftDir = path.join(repoRoot, "codegen", "pitches", "draft");
  const archiveDir = path.join(repoRoot, "codegen", "pitches", "archive");

  let draftDirReal: string;
  try {
    draftDirReal = fs.realpathSync(draftDir);
  } catch {
    throw new Error(`pitch_move: draft directory does not exist: ${draftDir}`);
  }

  // Source: must be a direct .md child of draft/, real, regular, not a symlink.
  const sourceAbs = path.isAbsolute(source)
    ? source
    : path.join(repoRoot, source);
  const sourceDirRaw = path.dirname(sourceAbs);
  const sourceBase = path.basename(sourceAbs);

  if (!isDirectChildSlug(sourceBase)) {
    throw new Error(
      `pitch_move: source basename is not a lowercase-kebab .md slug: ${sourceBase}`,
    );
  }

  let sourceDirReal: string;
  try {
    sourceDirReal = fs.realpathSync(sourceDirRaw);
  } catch {
    throw new Error(
      `pitch_move: source parent directory does not exist: ${sourceDirRaw}`,
    );
  }
  if (sourceDirReal !== draftDirReal) {
    throw new Error(
      `pitch_move: source must be a direct child of codegen/pitches/draft/ — got parent ${sourceDirReal}`,
    );
  }

  const sourceReal = path.join(sourceDirReal, sourceBase);
  let sourceStat: fs.Stats;
  try {
    sourceStat = fs.lstatSync(sourceReal);
  } catch {
    throw new Error(`pitch_move: source does not exist: ${sourceReal}`);
  }
  if (sourceStat.isSymbolicLink()) {
    throw new Error(`pitch_move: source is a symlink, refusing: ${sourceReal}`);
  }
  if (!sourceStat.isFile()) {
    throw new Error(`pitch_move: source is not a regular file: ${sourceReal}`);
  }

  // Destination: must be a direct .md child of draft/ or archive/, must NOT
  // already exist, parent must canonicalize to one of the two lifecycle dirs.
  const destAbs = path.isAbsolute(destination)
    ? destination
    : path.join(repoRoot, destination);
  const destBase = path.basename(destAbs);
  if (!isDirectChildSlug(destBase)) {
    throw new Error(
      `pitch_move: destination basename is not a lowercase-kebab .md slug: ${destBase}`,
    );
  }

  const destDirRaw = path.dirname(destAbs);
  // archive/ may not exist yet on first use — allow it by literal path match
  // (the transaction mkdir's it), otherwise require the realpath'd match.
  let archiveDirReal: string;
  try {
    archiveDirReal = fs.realpathSync(archiveDir);
  } catch {
    archiveDirReal = path.resolve(archiveDir);
  }

  let destDirReal: string;
  if (path.resolve(destDirRaw) === path.resolve(draftDir)) {
    destDirReal = draftDirReal;
  } else if (path.resolve(destDirRaw) === path.resolve(archiveDir)) {
    destDirReal = archiveDirReal;
  } else {
    throw new Error(
      `pitch_move: destination parent must be codegen/pitches/draft/ or codegen/pitches/archive/ — got ${destDirRaw}`,
    );
  }

  const destinationReal = path.join(destDirReal, destBase);

  if (sourceReal === destinationReal) {
    throw new Error(
      `pitch_move: source and destination are the same path: ${sourceReal}`,
    );
  }

  if (fs.existsSync(destinationReal)) {
    throw new Error(
      `pitch_move: destination already exists, refusing to clobber: ${destinationReal}`,
    );
  }

  return { sourceReal, destinationReal };
}

/** Resolve the repo root as a canonical realpath from an arbitrary cwd. */
export function resolveRepoRoot(cwd: string): string {
  return fs.realpathSync(cwd);
}
