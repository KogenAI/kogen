#!/usr/bin/env python3
"""The small, native-only Claude Code runtime installer used by Kogen's Elixir layer.

The public CLI deliberately has no configuration switches for registry URLs or
download locations.  Tests call the functions below with injected registry and
fetch functions; production always uses the official npm registry.
"""
from __future__ import annotations

import base64
import contextlib
import ctypes
import hashlib
import http.client
import json
import os
import platform as host_platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Dict, Iterator, Optional

INITIAL_VERSION = "2.1.280"
PINNED_ARTIFACTS = {
    "darwin-arm64": {
        "version": "2.1.280",
        "tarball": "https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-arm64/-/claude-code-darwin-arm64-2.1.280.tgz",
        "integrity": "sha512-ctkNgja8Yi2kngVFPO2667k6zbtJwjQ+dOTeEp1XmzHcoDFdaee4h4WVgZllsewm/Io+pPPPSFQVdGHOtdE/1A==",
    },
    "darwin-x64": {
        "version": "2.1.280",
        "tarball": "https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-x64/-/claude-code-darwin-x64-2.1.280.tgz",
        "integrity": "sha512-991qNyZVC/ra6THRMLDJ1mB1a+/C/bpKEA1w5ttNJA0mTvVm012kAbS3Pf7zrvRBFe7fU1KeHkGlTTq49519qA==",
    },
}
MANIFEST = ".kogen-runtime.json"
DEFAULT = "default.json"
OWNED_DIRECTORY_MARKER = ".kogen-installer-owned"
_UNSET = object()


class InstallerError(RuntimeError):
    pass


def _root_path(value: Path | str) -> Path:
    path = Path(value).expanduser()
    if path.is_symlink():
        raise InstallerError("unexpected managed installer occupant: " + str(path))
    # Canonicalize system ancestors such as macOS /var -> /private/var.  This
    # does not bless a symlink at the caller-owned root itself (checked above).
    return path.resolve()


def platform_name(machine: Optional[str] = None, system: Optional[str] = None) -> str:
    machine = (machine or host_platform.machine()).lower()
    system = (system or host_platform.system()).lower()
    if system != "darwin":
        raise InstallerError("managed Claude Code runtime is currently available only on macOS")
    if machine in {"arm64", "aarch64"}:
        return "darwin-arm64"
    if machine in {"x86_64", "amd64"}:
        return "darwin-x64"
    raise InstallerError("unsupported macOS architecture: " + machine)


def _package_name(platform: str) -> str:
    return "@anthropic-ai/claude-code-" + platform


def _official_get(url: str) -> bytes:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "registry.npmjs.org" or parsed.port is not None:
        raise InstallerError("official Claude Code download must use https://registry.npmjs.org")

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            raise InstallerError("official Claude Code download redirected to an untrusted location")

    last_error: Optional[BaseException] = None

    # The official native archives are large enough that an otherwise healthy
    # registry connection can reset mid-transfer. Each attempt starts a fresh
    # private response and only returns complete bytes; integrity verification
    # still happens before any extraction or native execution.
    for _attempt in range(3):
        try:
            opener = urllib.request.build_opener(NoRedirect())
            with opener.open(url, timeout=60) as response:
                return response.read()
        except InstallerError:
            raise
        except (OSError, http.client.HTTPException) as error:
            last_error = error

    raise InstallerError("could not download official Claude Code artifact after 3 attempts: " + str(last_error)) from last_error


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _runtime(root: Path, version: str, platform: str) -> Path:
    if not version or "/" in version or "\\" in version or version in {".", ".."}:
        raise InstallerError("invalid Claude Code version")
    return root / "runtimes" / (version + "-" + platform)


def _safe_member(name: str) -> Optional[PurePosixPath]:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise InstallerError("unsafe archive path: " + name)
    # npm tarballs have exactly one package root.  Ignore its directory itself.
    if path.parts[0] != "package":
        raise InstallerError("unexpected archive root: " + name)
    if len(path.parts) == 1:
        return None
    return PurePosixPath(*path.parts[1:])


def _inspect_archive(archive: Path) -> list[tuple[tarfile.TarInfo, PurePosixPath]]:
    entries: list[tuple[tarfile.TarInfo, PurePosixPath]] = []
    types: Dict[PurePosixPath, str] = {}
    try:
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar.getmembers():
                relative = _safe_member(member.name)
                if relative is None and not member.isdir():
                    raise InstallerError("unsafe archive entry type: " + member.name)
                if relative is None:
                    continue
                if not (member.isdir() or member.isreg()):
                    raise InstallerError("unsafe archive entry type: " + member.name)
                if relative in types:
                    raise InstallerError("duplicate archive path: " + str(relative))
                types[relative] = "directory" if member.isdir() else "file"
                entries.append((member, relative))
        for relative, kind in types.items():
            for parent in relative.parents:
                if parent == PurePosixPath("."):
                    break
                if types.get(parent) == "file":
                    raise InstallerError("conflicting archive parent path: " + str(parent))
            if kind == "file" and any(candidate != relative and relative in candidate.parents for candidate in types):
                raise InstallerError("conflicting archive file path: " + str(relative))
    except (tarfile.TarError, OSError) as error:
        raise InstallerError("invalid native distribution archive: " + str(error)) from error
    return entries


def _extract_archive(archive: Path, destination: Path) -> None:
    entries = _inspect_archive(archive)  # validate every member before writing anything
    with tarfile.open(archive, "r:gz") as tar:
        for member, relative in entries:
            output = destination.joinpath(*relative.parts)
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                source = tar.extractfile(member)
                if source is None:
                    raise InstallerError("archive file could not be read: " + member.name)
                with source, output.open("xb") as target:
                    shutil.copyfileobj(source, target)
                os.chmod(output, member.mode & 0o777)


def _tree_under(path: Path) -> Dict[str, Dict[str, Any]]:
    tree: Dict[str, Dict[str, Any]] = {}
    for child in sorted(path.rglob("*")):
        rel = child.relative_to(path).as_posix()
        if child.is_symlink() or not (child.is_file() or child.is_dir()):
            raise InstallerError("unexpected runtime path type: " + rel)
        mode = child.stat().st_mode & 0o777
        if child.is_file() and rel != MANIFEST:
            tree[rel] = {"sha256": _sha256(child), "mode": mode}
        elif child.is_dir():
            tree[rel] = {"directory": True, "mode": mode}
    return tree


def _required_paths(platform: str) -> tuple[str, tuple[str, ...]]:
    return "claude", ("package.json",)


def _validate_descriptor(runtime: Path, descriptor_path: str, platform: str, version: str) -> None:
    try:
        descriptor = json.loads((runtime / descriptor_path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise InstallerError("invalid native Claude Code package descriptor") from error
    if not isinstance(descriptor, dict):
        raise InstallerError("invalid native Claude Code package descriptor")
    if descriptor.get("name") != _package_name(platform) or descriptor.get("version") != version:
        raise InstallerError("native Claude Code package descriptor identity does not match pin")


def _write_manifest(runtime: Path, version: str, platform: str) -> Dict[str, Any]:
    executable, resources = _required_paths(platform)
    files = _tree_under(runtime)
    missing = [name for name in (executable, *resources)
               if name not in files or "sha256" not in files[name]]
    if missing:
        raise InstallerError("incomplete native distribution: missing " + ", ".join(missing))
    executable_resources = (executable, *resources[:-1])
    not_executable = [name for name in executable_resources if not (files[name]["mode"] & 0o111)]
    if not_executable:
        raise InstallerError("incomplete native distribution: non-executable " + ", ".join(not_executable))
    _validate_descriptor(runtime, resources[-1], platform, version)
    data = {"version": version, "platform": platform, "executable": executable, "files": files}
    (runtime / MANIFEST).write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    return data


def _verify_directory(runtime: Path, version: str, platform: str) -> Dict[str, Any]:
    manifest = runtime / MANIFEST
    if not runtime.is_dir() or runtime.is_symlink() or not manifest.is_file() or manifest.is_symlink():
        raise InstallerError("managed runtime is missing or incomplete: " + str(runtime))
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        expected = data["files"]
        executable = data["executable"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise InstallerError("invalid runtime manifest: " + str(runtime)) from error
    if data.get("version") != version or data.get("platform") != platform or not isinstance(expected, dict):
        raise InstallerError("runtime manifest identity does not match its directory")
    required_executable, resources = _required_paths(platform)
    if executable != required_executable or any(
            not isinstance(expected.get(item), dict) or "sha256" not in expected[item]
            for item in (required_executable, *resources)):
        raise InstallerError("runtime manifest lacks required native resources")
    _validate_descriptor(runtime, resources[-1], platform, version)
    actual = _tree_under(runtime)
    if actual != expected:
        raise InstallerError("runtime files do not match immutable manifest: " + str(runtime))
    executable_path = runtime / executable
    if any(not (actual[item]["mode"] & 0o111) for item in (executable, *resources[:-1])):
        raise InstallerError("managed Claude Code native resources are not executable")
    return {"version": version, "executable": str(executable_path), "path": str(runtime), "platform": platform}


def verify_runtime(root: Path | str, version: str, platform: Optional[str] = None) -> Dict[str, Any]:
    root, platform = _root_path(root), platform or platform_name()
    _safe_existing_directory(root)
    _safe_existing_directory(root / "runtimes", owned=True)
    return _verify_directory(_runtime(root, version, platform), version, platform)


def _native_check(runtime: Dict[str, Any]) -> None:
    executable = runtime["executable"]
    version = runtime["version"]
    with tempfile.TemporaryDirectory(prefix="kogen-claude-code-probe-") as private:
        environment = {
            "HOME": private,
            "CLAUDE_CONFIG_DIR": private,
            "PATH": "/usr/bin:/bin",
            "NO_COLOR": "1",
            "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        }
        try:
            completed = subprocess.run([executable, "--version"], stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                       timeout=60, check=False, env=environment)
        except OSError as error:
            raise InstallerError("could not launch validated native Claude Code runtime: " + str(error)) from error
        if completed.returncode != 0 or version not in completed.stdout:
            raise InstallerError("validated native Claude Code runtime rejected --version: " + completed.stderr.strip())


def _integrity_matches(payload: bytes, integrity: str) -> bool:
    try:
        algorithm, encoded = integrity.split("-", 1)
        return algorithm == "sha512" and hashlib.sha512(payload).digest() == base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError):
        return False


def _private_parents(path: Path) -> None:
    missing: list[Path] = []
    cursor = path
    while not cursor.exists():
        if cursor.is_symlink():
            raise InstallerError("unexpected managed installer occupant: " + str(cursor))
        missing.append(cursor)
        cursor = cursor.parent
    if cursor.is_symlink() or not cursor.is_dir():
        raise InstallerError("unexpected managed installer occupant: " + str(cursor))
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
        directory.chmod(0o700)


def _owned_directory(path: Path, *, root: bool = False) -> None:
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not path.is_dir():
            raise InstallerError("unexpected managed installer occupant: " + str(path))
        if not root and (not (path / OWNED_DIRECTORY_MARKER).is_file() or (path / OWNED_DIRECTORY_MARKER).is_symlink()):
            raise InstallerError("unrecognized managed installer directory: " + str(path))
        return
    _private_parents(path.parent)
    path.mkdir(mode=0o700)
    if not root:
        (path / OWNED_DIRECTORY_MARKER).write_text("installer-v1\n", encoding="utf-8")


def _safe_existing_directory(path: Path, *, owned: bool = False) -> bool:
    """Return false for an absent owned directory, rejecting every other occupant."""
    if not path.exists() and not path.is_symlink():
        return False
    if path.is_symlink() or not path.is_dir():
        raise InstallerError("unexpected managed installer occupant: " + str(path))
    if owned and (not (path / OWNED_DIRECTORY_MARKER).is_file() or (path / OWNED_DIRECTORY_MARKER).is_symlink()):
        raise InstallerError("unrecognized managed installer directory: " + str(path))
    return True


@contextlib.contextmanager
def _owned_lock(root: Path, name: str) -> Iterator[None]:
    import fcntl
    _owned_directory(root, root=True)
    lock_path = root / name
    if lock_path.exists() or lock_path.is_symlink():
        if lock_path.is_symlink() or not lock_path.is_file():
            raise InstallerError("unexpected managed installer occupant: " + str(lock_path))
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise InstallerError("could not create managed installer lock: " + str(error)) from error
    with os.fdopen(descriptor, "a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            if lock_path.is_symlink() or not lock_path.is_file():
                raise InstallerError("unexpected managed installer occupant: " + str(lock_path))
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def _promote(source: Path, destination: Path) -> None:
    # macOS renamex_np(RENAME_EXCL) is atomic and refuses even an empty
    # unrelated directory created after our cooperative staging-lock check.
    native = ctypes.CDLL(None, use_errno=True)
    rename = native.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        raise InstallerError("native runtime promotion refused: " + os.strerror(ctypes.get_errno()))


def _matches_platform(metadata: Dict[str, Any], version: str, platform: str) -> bool:
    cpu = metadata.get("cpu")
    operating_system = metadata.get("os")
    expected_cpu = "arm64" if platform == "darwin-arm64" else "x64"
    cpu_values = [cpu] if isinstance(cpu, str) else cpu
    os_values = [operating_system] if isinstance(operating_system, str) else operating_system
    return (metadata.get("name") == _package_name(platform) and metadata.get("version") == version
            and isinstance(cpu_values, list) and expected_cpu in cpu_values
            and isinstance(os_values, list) and "darwin" in os_values)


def stage(root: Path | str, version: str, *, platform: Optional[str] = None,
          registry: Optional[Callable[[str, Optional[str]], Dict[str, Any]]] = None,
          fetch: Callable[[str], bytes] = _official_get,
          native_check: Callable[[Dict[str, Any]], None] = _native_check,
          progress: Callable[[str], None] = lambda message: print(message, file=sys.stderr)) -> Dict[str, Any]:
    root, platform = _root_path(root), platform or platform_name()
    _safe_existing_directory(root)
    target = _runtime(root, version, platform)
    if target.exists() or target.is_symlink():
        return verify_runtime(root, version, platform)  # never overwrite an occupant
    package_name = _package_name(platform)
    progress("selecting pinned official native runtime " + package_name + "@" + version)
    if registry is None:
        if version != INITIAL_VERSION:
            raise InstallerError("runtime version is not pinned by this Kogen release")
        artifact = PINNED_ARTIFACTS[platform]
        metadata = {
            "name": package_name, "version": artifact["version"],
            "cpu": ["arm64" if platform == "darwin-arm64" else "x64"], "os": ["darwin"],
            "dist": {"tarball": artifact["tarball"], "integrity": artifact["integrity"]},
        }
    else:
        metadata = registry(package_name, version)
    dist = metadata.get("dist") if isinstance(metadata, dict) else None
    if not isinstance(metadata, dict) or not _matches_platform(metadata, version, platform):
        raise InstallerError("official native metadata identity does not match requested platform")
    if not isinstance(dist, dict) or not isinstance(dist.get("tarball"), str) or not isinstance(dist.get("integrity"), str):
        raise InstallerError("official native metadata lacks tarball or sha512 integrity")
    tarball = urllib.parse.urlparse(dist["tarball"])
    if tarball.scheme != "https" or tarball.hostname != "registry.npmjs.org" or tarball.port is not None:
        raise InstallerError("official native tarball URL is not registry.npmjs.org HTTPS")
    progress("downloading official native runtime")
    payload = fetch(dist["tarball"])
    if not _integrity_matches(payload, dist["integrity"]):
        raise InstallerError("native distribution integrity mismatch")
    _owned_directory(root, root=True)
    staging_parent = root / ".staging"
    _owned_directory(staging_parent)
    work = staging_parent / ("runtime-" + uuid.uuid4().hex)
    try:
        work.mkdir(mode=0o700)
        archive = work / "distribution.tgz"
        archive.write_bytes(payload)
        unpacked = work / "runtime"
        unpacked.mkdir()
        progress("validating and extracting native runtime")
        _extract_archive(archive, unpacked)
        _write_manifest(unpacked, version, platform)
        staged = _verify_directory(unpacked, version, platform)
        # The native probe happens only after integrity, archive type/path,
        # and complete-tree checks have settled, while this tree is still private.
        native_check(staged)
        runtimes = root / "runtimes"
        with _owned_lock(root, ".stage.lock"):
            _owned_directory(runtimes)
            if target.exists() or target.is_symlink():
                return verify_runtime(root, version, platform)
            _promote(unpacked, target)
        progress("staged native runtime " + version)
        return verify_runtime(root, version, platform)
    finally:
        shutil.rmtree(work, ignore_errors=True)


@contextlib.contextmanager
def _activation_lock(root: Path) -> Iterator[None]:
    with _owned_lock(root, ".activation.lock"):
        yield


def _default(root: Path) -> Optional[str]:
    path = root / DEFAULT
    if path.is_symlink():
        raise InstallerError("unexpected managed installer occupant: " + str(path))
    if not path.exists():
        return None
    if not path.is_file():
        raise InstallerError("unexpected managed installer occupant: " + str(path))
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        version = data["version"]
        if not isinstance(version, str):
            raise ValueError()
        return version
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise InstallerError("invalid default runtime pointer") from error


def activate(root: Path | str, version: str, expected_version: object = _UNSET,
             *, platform: Optional[str] = None) -> Dict[str, Any]:
    root, platform = _root_path(root), platform or platform_name()
    if expected_version == "-":
        expected_version = None
    result = verify_runtime(root, version, platform)
    with _activation_lock(root):
        current = _default(root)
        if expected_version is not _UNSET and current != expected_version:
            raise InstallerError("default runtime changed concurrently (expected %s, found %s)" % (expected_version, current or "-"))
        temporary = root / ("." + DEFAULT + "." + uuid.uuid4().hex)
        try:
            if (root / DEFAULT).is_symlink() or ((root / DEFAULT).exists() and not (root / DEFAULT).is_file()):
                raise InstallerError("unexpected managed installer occupant: " + str(root / DEFAULT))
            temporary.write_text(json.dumps({"version": version}, separators=(",", ":")) + "\n", encoding="utf-8")
            os.replace(temporary, root / DEFAULT)
        finally:
            temporary.unlink(missing_ok=True)
    return result


def inspect(root: Path | str, *, platform: Optional[str] = None) -> Optional[Dict[str, Any]]:
    root, platform = _root_path(root), platform or platform_name()
    if not _safe_existing_directory(root):
        return None
    version = _default(root)
    return None if version is None else verify_runtime(root, version, platform)


def required(root: Path | str, *, platform: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """Inspect only this checkout's pin; another retained/default release is not a substitute."""
    root, platform = _root_path(root), platform or platform_name()
    if not _safe_existing_directory(root):
        return None
    target = _runtime(root, INITIAL_VERSION, platform)
    if not target.exists() and not target.is_symlink():
        return None
    return verify_runtime(root, INITIAL_VERSION, platform)


def install(root: Path | str, *, platform: Optional[str] = None, **dependencies: Any) -> Dict[str, Any]:
    root, platform = _root_path(root), platform or platform_name()
    current = inspect(root, platform=platform)
    if current is not None and current["version"] == INITIAL_VERSION:
        return current
    candidate = stage(root, INITIAL_VERSION, platform=platform, **dependencies)
    expected = current["version"] if current is not None else "-"
    return activate(root, candidate["version"], expected, platform=platform)


def _main(arguments: list[str]) -> int:
    if sys.version_info < (3, 11):
        raise InstallerError("Python 3.11 or newer is required; use the project mise environment")
    if len(arguments) < 2:
        raise InstallerError("usage: install.py ROOT install|required|stage|activate|inspect [VERSION] [EXPECTED_VERSION]")
    root, command, rest = Path(arguments[0]), arguments[1], arguments[2:]
    if not root.is_absolute():
        raise InstallerError("Kogen runtime root must be an absolute path")
    if command == "install" and not rest:
        result: Any = install(root)
    elif command == "stage" and len(rest) == 1:
        result = stage(root, rest[0])
    elif command == "activate" and len(rest) in {1, 2}:
        expected = _UNSET if len(rest) == 1 else rest[1]
        result = activate(root, rest[0], expected)
    elif command == "inspect" and not rest:
        result = inspect(root)
    elif command == "required" and not rest:
        result = required(root)
    else:
        raise InstallerError("invalid installer command arguments")
    print(json.dumps({"ok": True, "runtime": result}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(_main(sys.argv[1:]))
    except InstallerError as error:
        print(json.dumps({"ok": False, "error": str(error)}, separators=(",", ":")))
        raise SystemExit(1)
