#!/usr/bin/env python3
"""Create a pinned, curated Kogen source package without network access."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Sequence


PREFIX = "kogen-source/"
CURATED_PREFIXES = (
    "lib/",
    "priv/kogen/",
    "native/kogen-cli/src/",
    "docs/",
    "scripts/check/",
    "workflows/",
)
CURATED_FILES = (
    ".credo.exs",
    ".formatter.exs",
    ".gitignore",
    ".kogen/config.yaml",
    "LICENSE",
    "Makefile",
    "NOTICE",
    "README.md",
    "mix.exs",
    "mix.lock",
    "mise.toml",
    "native/kogen-cli/Cargo.lock",
    "native/kogen-cli/Cargo.toml",
    "native/kogen-cli/README.md",
    "scripts/package-local.py",
)
EXCLUDED_PATHS = [
    ".kogen/intents/** (historical Intent and recovery evidence)",
    ".kogen/runtime/** (sessions and runtime receipts)",
    ".codex/** (local harness configuration and authentication)",
    "test/** and native/kogen-cli/tests/** (test and grader material)",
    "deps/**, _build/**, cover/** (dependencies and build output)",
    "ignored and untracked worktree files (including caches and credentials)",
]
INTERFACE_FILES = [
    ".kogen/config.yaml",
    "docs/external-projects.md",
    "docs/role-configuration.md",
    "native/kogen-cli/README.md",
    "priv/kogen/custom/prompts/auditor.md",
    "priv/kogen/custom/prompts/developer.md",
    "priv/kogen/custom/prompts/expert.md",
    "priv/kogen/custom/prompts/reviewer.md",
    "priv/kogen/custom/prompts/shaping.md",
]


class PackageError(Exception):
    """An expected refusal or package-build failure."""


@dataclass(frozen=True)
class GitBlob:
    path: str
    mode: str
    oid: str


def run(
    command: Sequence[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    stdout: int | None = subprocess.PIPE,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            list(command),
            cwd=cwd,
            env=env,
            check=False,
            stdout=stdout,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise PackageError(f"cannot run {command[0]}: {error}") from error
    if result.returncode:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise PackageError(
            f"command failed ({result.returncode}): {' '.join(command)}"
            + (f"\n{detail}" if detail else "")
        )
    return result


def git_env() -> dict[str, str]:
    environment = os.environ.copy()
    for name in tuple(environment):
        if name.startswith("GIT_"):
            environment.pop(name)
    return environment


def git(source: Path, *args: str, stdout: int | None = subprocess.PIPE) -> bytes:
    return run(["git", "-C", str(source), *args], env=git_env(), stdout=stdout).stdout or b""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def hash_file(path: Path) -> dict[str, int | str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return {"sha256": digest.hexdigest(), "bytes": size}


def check_source(source_arg: Path, pin: str) -> tuple[Path, str, str, int]:
    if not re.fullmatch(r"[0-9a-fA-F]{40,64}", pin):
        raise PackageError("--source-sha must be a full 40- or 64-character commit ID")
    source = source_arg.expanduser().resolve(strict=True)
    if not source.is_dir():
        raise PackageError("--source must name a Git checkout directory")

    root_text = git(source, "rev-parse", "--show-toplevel").decode().strip()
    root = Path(root_text).resolve(strict=True)
    if root != source:
        raise PackageError("--source must be the checkout root")

    head = git(root, "rev-parse", "HEAD^{commit}").decode().strip()
    if head.lower() != pin.lower():
        raise PackageError(f"HEAD does not match --source-sha ({head})")

    status = git(root, "status", "--porcelain=v1", "--untracked-files=all")
    if status:
        raise PackageError("source worktree is dirty; commit or remove local changes first")
    index_entries = git(root, "ls-files", "-t", "-v", "-z").split(b"\0")
    if any(entry[:1].islower() or entry.startswith(b"S ") for entry in index_entries if entry):
        raise PackageError("source index has assume-unchanged or skip-worktree flags")

    tree = git(root, "rev-parse", f"{head}^{{tree}}").decode().strip()
    timestamp = int(git(root, "show", "-s", "--format=%ct", head).decode().strip())
    return root, head, tree, timestamp


def output_path(path_arg: Path, source: Path) -> Path:
    if not path_arg.is_absolute():
        raise PackageError("--output must be an absolute new directory path")
    if os.path.lexists(path_arg):
        raise PackageError("--output already exists; choose a new directory")

    parent = path_arg.parent.expanduser().resolve(strict=False)
    destination = parent / path_arg.name
    if destination == source or source in destination.parents:
        raise PackageError("--output must be outside the source checkout")

    cloud_docs = (Path.home() / "Library/Mobile Documents/com~apple~CloudDocs").resolve(
        strict=False
    )
    if destination == cloud_docs or cloud_docs in destination.parents:
        raise PackageError("--output must be outside iCloud Drive")
    return destination


def curated_blobs(source: Path, commit: str) -> list[GitBlob]:
    paths = [*CURATED_PREFIXES, *CURATED_FILES]
    command = ["git", "-C", str(source), "ls-tree", "-rz", "--full-tree", commit, "--", *paths]
    output = run(command, env=git_env()).stdout or b""
    blobs: list[GitBlob] = []
    for record in output.split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split(" ", 2)
        path = raw_path.decode("utf-8")
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise PackageError(f"curated source contains a non-regular file: {path}")
        blobs.append(GitBlob(path=path, mode=mode, oid=oid))

    if not blobs:
        raise PackageError("the supplied commit has no files in the curated source set")
    found = {blob.path for blob in blobs}
    missing = [path for path in INTERFACE_FILES if path not in found]
    if missing:
        raise PackageError("pinned source is missing interface files: " + ", ".join(missing))
    return sorted(blobs, key=lambda blob: blob.path)


def archive_source(
    source: Path, blobs: list[GitBlob], output: Path, timestamp: int
) -> list[dict[str, int | str]]:
    included: list[dict[str, int | str]] = []
    raw_archive = output / ".source.tar"
    with tarfile.open(raw_archive, "w", format=tarfile.PAX_FORMAT) as archive:
        for blob in blobs:
            data = git(source, "cat-file", "blob", blob.oid)
            relative = PurePosixPath(blob.path)
            if relative.is_absolute() or ".." in relative.parts:
                raise PackageError(f"unsafe source path in Git tree: {blob.path}")
            info = tarfile.TarInfo(PREFIX + blob.path)
            info.size = len(data)
            info.mode = 0o755 if blob.mode == "100755" else 0o644
            info.mtime = timestamp
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            archive.addfile(info, fileobj=io.BytesIO(data))
            included.append(
                {
                    "path": blob.path,
                    "git_blob": blob.oid,
                    "sha256": sha256(data),
                    "bytes": len(data),
                    "mode": blob.mode,
                }
            )

    archive_path = output / "kogen-source.tar.gz"
    with raw_archive.open("rb") as source_file, archive_path.open("xb") as output_file:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output_file, mtime=0) as compressed:
            shutil.copyfileobj(source_file, compressed)
    raw_archive.unlink()
    return included


def extract_curated_archive(archive_path: Path, destination: Path) -> None:
    destination.mkdir(parents=True)
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not member.isfile():
                raise PackageError(f"refusing unsafe archive entry: {member.name}")
            if not path.parts or path.parts[0] != PREFIX.rstrip("/"):
                raise PackageError(f"unexpected archive root: {member.name}")
            target = destination.joinpath(*path.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            payload = archive.extractfile(member)
            if payload is None:
                raise PackageError(f"cannot read archive entry: {member.name}")
            with target.open("xb") as output_file:
                shutil.copyfileobj(payload, output_file)
            target.chmod(member.mode & 0o777)


def create_snapshot_bundle(
    snapshot: Path,
    output: Path,
    timestamp: int,
    object_format: str,
    included: list[dict[str, int | str]],
) -> tuple[str, str]:
    env = git_env()
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    run(
        [
            "git",
            "init",
            "--quiet",
            f"--object-format={object_format}",
            "--initial-branch=package",
            str(snapshot),
        ],
        env=env,
    )
    run(["git", "-C", str(snapshot), "config", "core.autocrlf", "false"], env=env)
    run(["git", "-C", str(snapshot), "add", "--force", "--all"], env=env)
    tree = run(["git", "-C", str(snapshot), "write-tree"], env=env).stdout.decode().strip()
    expected = {
        ("100755" if item["mode"] == "100755" else "100644", str(item["git_blob"]), PREFIX + str(item["path"]))
        for item in included
    }
    listing = run(
        ["git", "-C", str(snapshot), "ls-tree", "-rz", "--full-tree", tree], env=env
    ).stdout or b""
    actual = set()
    for record in listing.split(b"\0"):
        if record:
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, oid = metadata.decode("ascii").split(" ", 2)
            if kind != "blob":
                raise PackageError("curated bundle tree contains a non-file entry")
            actual.add((mode, oid, raw_path.decode("utf-8")))
    if actual != expected:
        raise PackageError("curated bundle tree differs from the hashed source archive")

    commit_env = env.copy()
    commit_env.update(
        {
            "GIT_AUTHOR_NAME": "Kogen package snapshot",
            "GIT_AUTHOR_EMAIL": "package-snapshot@invalid",
            "GIT_COMMITTER_NAME": "Kogen package snapshot",
            "GIT_COMMITTER_EMAIL": "package-snapshot@invalid",
            "GIT_AUTHOR_DATE": f"@{timestamp} +0000",
            "GIT_COMMITTER_DATE": f"@{timestamp} +0000",
        }
    )
    commit = run(
        ["git", "-C", str(snapshot), "commit-tree", tree, "-m", "Curated Kogen source snapshot"],
        env=commit_env,
    ).stdout.decode().strip()
    run(["git", "-C", str(snapshot), "update-ref", "refs/heads/package", commit], env=env)
    bundle = output / "kogen-source.bundle"
    run(
        ["git", "-C", str(snapshot), "bundle", "create", str(bundle), "refs/heads/package"],
        env=env,
    )
    run(["git", "bundle", "verify", str(bundle)], cwd=snapshot, env=env)
    return commit, tree


def version(command: Sequence[str]) -> str | None:
    try:
        result = subprocess.run(
            list(command),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
            env={k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode:
        return None
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return " | ".join(lines[:3]) if lines else None


def build_binary(snapshot: Path, temp: Path) -> tuple[Path, str]:
    manifest = snapshot / "native/kogen-cli/Cargo.toml"
    target = temp / "cargo-target"
    command = [
        "cargo",
        "build",
        "--offline",
        "--locked",
        "--release",
        "--manifest-path",
        str(manifest),
        "--target-dir",
        str(target),
    ]
    run(command, env=git_env(), stdout=None)
    binary = target / "release" / ("kogen.exe" if os.name == "nt" else "kogen")
    if not binary.is_file():
        raise PackageError("Cargo succeeded but did not produce the kogen release binary")
    return (
        binary,
        "cargo build --offline --locked --release --manifest-path "
        "native/kogen-cli/Cargo.toml --target-dir <temporary>",
    )


def write_manifest(
    output: Path,
    *,
    source_commit: str,
    source_tree: str,
    snapshot_commit: str,
    snapshot_tree: str,
    included: list[dict[str, int | str]],
    build_command: str,
) -> None:
    files: dict[str, dict[str, int | str]] = {}
    for name in ("kogen-source.tar.gz", "kogen-source.bundle", "kogen"):
        files[name] = hash_file(output / name)

    manifest = {
        "schema": "kogen.local-package/v1",
        "package_kind": "curated-source-snapshot",
        "qualified": False,
        "live_receipt": None,
        "source": {"commit": source_commit, "tree": source_tree},
        "snapshot_bundle": {
            "commit": snapshot_commit,
            "tree": snapshot_tree,
            "history": "single synthetic commit; no source history",
            "tree_matches_curated_archive": True,
        },
        "curation": {"included": included, "excluded": EXCLUDED_PATHS},
        "interface_files": {
            item["path"]: {"sha256": item["sha256"], "bytes": item["bytes"]}
            for item in included
            if item["path"] in INTERFACE_FILES
        },
        "build": {
            "command": build_command,
            "network": "disabled by Cargo --offline",
            "binary": "kogen",
            "compiled_default_engine_path": "temporary build snapshot; always pass --engine",
        },
        "engine_runtime": {
            "requires": ["Elixir 1.20", "Erlang/OTP 29", "locked Mix dependencies"],
            "dependencies_included": False,
            "compiled_mix_output_included": False,
        },
        "host": {"platform": platform.platform(), "machine": platform.machine()},
        "tool_versions": {
            "python": f"{platform.python_implementation()} {platform.python_version()}",
            "git": version(["git", "--version"]),
            "rustc": version(["rustc", "--version"]),
            "cargo": version(["cargo", "--version"]),
            "elixir": version(["elixir", "--version"]),
            "mix": version(["mix", "--version"]),
        },
        "files": files,
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def package(source_arg: Path, pin: str, output_arg: Path) -> Path:
    source, commit, tree, timestamp = check_source(source_arg, pin)
    destination = output_path(output_arg, source)
    object_format = git(source, "rev-parse", "--show-object-format").decode().strip()
    if object_format not in {"sha1", "sha256"}:
        raise PackageError(f"unsupported Git object format: {object_format}")
    blobs = curated_blobs(source, commit)

    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        destination.mkdir(mode=0o700)
    except FileExistsError as error:
        raise PackageError("--output appeared during validation; choose another path") from error

    try:
        with tempfile.TemporaryDirectory(prefix="kogen-package-") as temporary:
            temporary_root = Path(temporary)
            included = archive_source(source, blobs, destination, timestamp)
            snapshot = temporary_root / "snapshot"
            extract_curated_archive(destination / "kogen-source.tar.gz", snapshot)
            snapshot_commit, snapshot_tree = create_snapshot_bundle(
                snapshot, destination, timestamp, object_format, included
            )
            binary, build_command = build_binary(snapshot / PREFIX.rstrip("/"), temporary_root)
            shutil.copy2(binary, destination / "kogen")
            (destination / "kogen").chmod(0o755)
            smoke = run([str(destination / "kogen"), "--help"])
            if b"kogen --project PATH [--engine PATH]" not in (smoke.stdout or b""):
                raise PackageError("release binary did not pass its provider-free --help smoke check")
            check_source(source, pin)
            write_manifest(
                destination,
                source_commit=commit,
                source_tree=tree,
                snapshot_commit=snapshot_commit,
                snapshot_tree=snapshot_tree,
                included=included,
                build_command=build_command,
            )
        return destination
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise


def main(argv: Sequence[str] | None = None) -> int:
    if sys.version_info < (3, 11):
        print("package-local: Python 3.11 or newer is required", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="clean Git checkout root")
    parser.add_argument("--source-sha", required=True, help="full pinned source commit ID")
    parser.add_argument("--output", type=Path, required=True, help="absolute new output directory")
    args = parser.parse_args(argv)
    try:
        destination = package(args.source, args.source_sha, args.output)
    except KeyboardInterrupt:
        print("package-local: interrupted; partial output was removed", file=sys.stderr)
        return 130
    except PackageError as error:
        print(f"package-local: {error}", file=sys.stderr)
        return 2
    except Exception as error:
        print(f"package-local: package failed: {error}", file=sys.stderr)
        return 2
    print(f"Created curated local package: {destination}")
    print("Snapshot only; it has no qualification or live receipt.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
