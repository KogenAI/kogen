import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";

/**
 * No-clobber hard-link move transaction for pitch_move.
 *
 * Sequence: lstat/read/hash source → require destination absent → linkSync
 * destination → verify both paths are regular, same inode, byte-identical →
 * unlink source → verify source absent and destination unchanged.
 *
 * Crash recovery: a retry after process death may complete ONLY the
 * uniquely-identifiable interrupted state where source and destination are
 * same-inode regular files at the requested paths with unchanged hash —
 * every other existing destination denies without mutation.
 */

function sha256(buf: Buffer): string {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

function isRegularFile(p: string): boolean {
  try {
    return fs.lstatSync(p).isFile();
  } catch {
    return false;
  }
}

function sameInode(a: string, b: string): boolean {
  const sa = fs.lstatSync(a);
  const sb = fs.lstatSync(b);
  return sa.dev === sb.dev && sa.ino === sb.ino;
}

export type MoveResult = {
  ok: true;
  source: string;
  destination: string;
  recovered: boolean;
};

export type MoveError = {
  ok: false;
  error: string;
};

/**
 * Execute (or complete an interrupted) no-clobber hard-link move.
 *
 * Preconditions (caller MUST have already validated): source is a real,
 * non-symlink regular file; destination does not already exist UNLESS this
 * is the uniquely-identifiable interrupted-retry case (source AND
 * destination both present, same inode, regular files) — that is the one
 * shape this function will complete rather than refuse.
 */
export function executeMove(
  source: string,
  destination: string,
): MoveResult | MoveError {
  const sourceExists = isRegularFile(source);
  const destExists = isRegularFile(destination);

  // Uniquely-identifiable interrupted state: both present, same inode.
  // Complete the transaction (unlink source) rather than refuse.
  if (sourceExists && destExists) {
    if (!sameInode(source, destination)) {
      return {
        ok: false,
        error: `pitch_move: destination already exists and is NOT the same file as source (different inode) — refusing to clobber: ${destination}`,
      };
    }
    try {
      fs.unlinkSync(source);
    } catch (err) {
      return {
        ok: false,
        error: `pitch_move: retry-completion failed to unlink source after confirming same-inode destination: ${(err as Error).message}`,
      };
    }
    if (fs.existsSync(source)) {
      return {
        ok: false,
        error: `pitch_move: retry-completion postcondition failed — source still exists after unlink: ${source}`,
      };
    }
    if (!isRegularFile(destination)) {
      return {
        ok: false,
        error: `pitch_move: retry-completion postcondition failed — destination missing or not regular after unlink: ${destination}`,
      };
    }
    return { ok: true, source, destination, recovered: true };
  }

  if (destExists && !sourceExists) {
    // Some OTHER existing destination — never mutate, never clobber.
    return {
      ok: false,
      error: `pitch_move: destination already exists (source absent — not the interrupted-retry shape) — refusing to clobber: ${destination}`,
    };
  }

  if (!sourceExists) {
    return {
      ok: false,
      error: `pitch_move: source does not exist or is not a regular file: ${source}`,
    };
  }

  // Normal (non-retry) path.
  let sourceBuf: Buffer;
  try {
    sourceBuf = fs.readFileSync(source);
  } catch (err) {
    return {
      ok: false,
      error: `pitch_move: failed to read source: ${(err as Error).message}`,
    };
  }
  const sourceHash = sha256(sourceBuf);

  // The destination's lifecycle directory (draft/ or archive/) is created on
  // first use — archive/ in particular may not exist yet for a fresh repo.
  // Directory creation is safe here: it happens ONLY after source has been
  // fully validated and read, and mkdir with recursive:true is a no-op on an
  // already-existing directory (never clobbers, never touches sibling paths).
  try {
    fs.mkdirSync(path.dirname(destination), { recursive: true });
  } catch (err) {
    return {
      ok: false,
      error: `pitch_move: failed to create destination directory: ${(err as Error).message}`,
    };
  }

  try {
    fs.linkSync(source, destination);
  } catch (err) {
    return {
      ok: false,
      error: `pitch_move: linkSync failed: ${(err as Error).message}`,
    };
  }

  // Verify before unlinking source: both regular, same inode, byte-identical.
  const verifyFailure = (msg: string): MoveError => {
    // Rollback: remove only the new destination we just created.
    try {
      fs.unlinkSync(destination);
    } catch {
      // best-effort rollback; the verify failure itself is the loud signal
    }
    return {
      ok: false,
      error: `pitch_move: pre-unlink verification failed (${msg}) — rolled back destination`,
    };
  };

  if (!isRegularFile(source) || !isRegularFile(destination)) {
    return verifyFailure(
      "source or destination is not a regular file after link",
    );
  }
  if (!sameInode(source, destination)) {
    return verifyFailure(
      "source and destination are not the same inode after link",
    );
  }
  let destBuf: Buffer;
  try {
    destBuf = fs.readFileSync(destination);
  } catch (err) {
    return verifyFailure(
      `failed to read destination for hash check: ${(err as Error).message}`,
    );
  }
  if (sha256(destBuf) !== sourceHash) {
    return verifyFailure("destination content hash does not match source");
  }

  try {
    fs.unlinkSync(source);
  } catch (err) {
    // Unlink failure: roll back destination (preserve source as ground truth).
    try {
      fs.unlinkSync(destination);
    } catch {
      // best-effort rollback
    }
    return {
      ok: false,
      error: `pitch_move: unlink of source failed after verified link, rolled back destination: ${(err as Error).message}`,
    };
  }

  if (fs.existsSync(source)) {
    return {
      ok: false,
      error: `pitch_move: postcondition failed — source still exists after unlink: ${source}`,
    };
  }
  if (!isRegularFile(destination)) {
    return {
      ok: false,
      error: `pitch_move: postcondition failed — destination missing or not regular after unlink: ${destination}`,
    };
  }

  return { ok: true, source, destination, recovered: false };
}
