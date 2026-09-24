"""Offline, synthetic checks for priv/kogen/claude_code/install.py."""
import base64
import hashlib
import http.client
import importlib.util
import io
import json
import os
import tarfile
import tempfile
import threading
import unittest
from unittest import mock
from pathlib import Path


INSTALLER = Path(__file__).parents[2] / "priv/kogen/claude_code/install.py"
spec = importlib.util.spec_from_file_location("kogen_claude_code_installer", INSTALLER)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

PLATFORM = "darwin-arm64"
PACKAGE = "@anthropic-ai/claude-code-darwin-arm64"


def package_tar(name=PACKAGE, version="9.9.9", extra=None, unsafe=None, omit=None):
    stream = io.BytesIO()
    # Literal observed native package layout; do not derive this from the
    # installer's required-path helper or the fixture could mirror its defect.
    descriptor = json.dumps({"name": name, "version": version, "os": ["darwin"], "cpu": ["arm64"]}).encode()
    files = {
        "package/claude": (b"native claude binary", 0o755),
        "package/package.json": (descriptor, 0o644),
        "package/LICENSE.md": (b"license", 0o644),
        "package/README.md": (b"readme", 0o644),
    }
    files.update(extra or {})
    if omit:
        files.pop(omit)
    with tarfile.open(fileobj=stream, mode="w:gz") as tar:
        for name_, (body, mode) in files.items():
            item = tarfile.TarInfo(name_)
            item.size, item.mode = len(body), mode
            tar.addfile(item, io.BytesIO(body))
        if unsafe:
            tar.addfile(unsafe)
    return stream.getvalue()


def registry_for(payload, name=PACKAGE):
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(payload).digest()).decode()
    def registry(package, version):
        if package != name or version is None:
            raise AssertionError((package, version))
        return {"name": package, "version": version, "os": ["darwin"], "cpu": ["arm64"],
                "dist": {"tarball": "https://registry.npmjs.org/fixture.tgz", "integrity": integrity}}
    return registry


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name) / "private-runtime"
        self.platform = PLATFORM

    def tearDown(self):
        self.directory.cleanup()

    def accounts_marker(self, content=b"synthetic-keychain-scoped-accounts"):
        marker = self.root / "accounts" / "shared" / "marker"
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_bytes(content)
        return marker, content

    def stage(self, version="9.9.9", payload=None, **kwargs):
        payload = payload or package_tar(version=version)
        native_check = kwargs.pop("native_check", lambda _runtime: None)
        registry = kwargs.pop("registry", registry_for(payload))
        fetch = kwargs.pop("fetch", lambda _url: payload)
        return installer.stage(self.root, version, platform=self.platform,
                               registry=registry, fetch=fetch,
                               native_check=native_check,
                               progress=lambda _message: None, **kwargs)

    def test_official_download_retries_only_complete_transfers(self):
        first = mock.MagicMock()
        first.__enter__.return_value.read.side_effect = http.client.IncompleteRead(b"partial", 4)
        second = mock.MagicMock()
        second.__enter__.return_value.read.return_value = b"complete"
        opener = mock.MagicMock()
        opener.open.side_effect = [first, second]

        with mock.patch.object(installer.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(
                installer._official_get("https://registry.npmjs.org/fixture.tgz"),
                b"complete",
            )
        self.assertEqual(opener.open.call_count, 2)

    def test_official_get_refuses_non_registry_urls_without_connecting(self):
        with mock.patch.object(installer.urllib.request, "build_opener") as opener:
            with self.assertRaisesRegex(installer.InstallerError, "registry.npmjs.org"):
                installer._official_get("https://evil.example/claude.tgz")
        opener.assert_not_called()

    def test_stage_preserves_full_native_tree_and_manifest(self):
        result = self.stage()
        self.assertEqual(result["version"], "9.9.9")
        self.assertTrue(result["executable"].endswith("/claude"))
        manifest = Path(result["path"]) / installer.MANIFEST
        self.assertIn("package.json", manifest.read_text())
        self.assertIn("LICENSE.md", manifest.read_text())
        self.assertEqual(installer.inspect(self.root, platform=self.platform), None)
        active = installer.activate(self.root, "9.9.9", "-", platform=self.platform)
        self.assertEqual(active, result)

    def test_install_selects_initial_exact_release_and_repeat_preserves_native_state(self):
        payload, selected, launches = package_tar(version=installer.INITIAL_VERSION), [], []
        def registry(package, version):
            selected.append((package, version))
            return registry_for(payload)(package, version)
        first = installer.install(self.root, platform=self.platform, registry=registry,
            fetch=lambda _: payload, native_check=lambda runtime: launches.append(runtime["version"]),
            progress=lambda _: None)
        self.assertEqual(selected, [(PACKAGE, installer.INITIAL_VERSION)])
        self.assertEqual(launches, [installer.INITIAL_VERSION])
        account = self.root / "account-state"
        account.write_bytes(b"synthetic-credentials-and-retained-conversations")
        repeated = installer.install(self.root, platform=self.platform,
            registry=lambda *_: self.fail("repeated install fetched metadata"))
        self.assertEqual(repeated, first)
        self.assertEqual(account.read_bytes(), b"synthetic-credentials-and-retained-conversations")

    def test_production_pin_uses_tracked_artifact_metadata_without_registry_lookup(self):
        payload = package_tar(version=installer.INITIAL_VERSION)
        artifact = installer.PINNED_ARTIFACTS[self.platform]
        artifact_integrity = artifact["integrity"]
        try:
            artifact["integrity"] = "sha512-" + base64.b64encode(hashlib.sha512(payload).digest()).decode()
            result = installer.stage(
                self.root, installer.INITIAL_VERSION, platform=self.platform,
                fetch=lambda url: payload if url == artifact["tarball"] else self.fail(url),
                native_check=lambda _runtime: None, progress=lambda _message: None,
            )
            self.assertEqual(result["version"], installer.INITIAL_VERSION)
        finally:
            artifact["integrity"] = artifact_integrity

    def test_production_pin_is_exactly_2_1_281_with_registry_integrity(self):
        self.assertEqual(installer.INITIAL_VERSION, "2.1.281")
        self.assertEqual(installer.PINNED_ARTIFACTS, {
            "darwin-arm64": {
                "version": "2.1.281",
                "tarball": "https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-arm64/-/claude-code-darwin-arm64-2.1.281.tgz",
                "integrity": "sha512-rEI/YGBDX4YTfdq5w1B86NicoLgpFHGp4IrKM6sDrmUemruePSXF7ybICthHClIsRY8a/Kp7PQ6UJah1VWTbSA==",
            },
            "darwin-x64": {
                "version": "2.1.281",
                "tarball": "https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-x64/-/claude-code-darwin-x64-2.1.281.tgz",
                "integrity": "sha512-nGJBmWAMlyHAlf0i/vwBzjvTfEC86KcGZT4VNlpInL03jufnBztZr8+ILcXcwg5h94McpmvI/tu8lgHJtHKLVQ==",
            },
        })

    def test_production_pin_refuses_bytes_that_do_not_match_the_pinned_integrity(self):
        payload = package_tar(version=installer.INITIAL_VERSION)
        fetched, launches = [], []
        with self.assertRaisesRegex(installer.InstallerError, "integrity mismatch"):
            installer.install(self.root, platform=self.platform,
                              fetch=lambda url: fetched.append(url) or payload,
                              native_check=lambda _runtime: launches.append(True),
                              progress=lambda _message: None)
        self.assertEqual(fetched, [installer.PINNED_ARTIFACTS[self.platform]["tarball"]])
        self.assertEqual(launches, [])
        self.assertFalse((self.root / "runtimes").exists())
        self.assertFalse((self.root / "default.json").exists())

    def test_upgrade_from_retained_2_1_280_preserves_it_on_failure_and_after_publishing(self):
        self.stage("2.1.280")
        installer.activate(self.root, "2.1.280", "-", platform=self.platform)
        default = (self.root / "default.json").read_bytes()
        old = self.root / "runtimes/2.1.280-darwin-arm64"
        before = {p: p.read_bytes() for p in sorted(old.rglob("*")) if p.is_file()}
        marker, marker_content = self.accounts_marker()
        payload = package_tar(version=installer.INITIAL_VERSION)
        def failed_download(_url):
            raise installer.InstallerError("download failed")
        failures = [
            ("download failed", dict(registry=registry_for(payload), fetch=failed_download)),
            ("integrity mismatch", dict(fetch=lambda _url: payload)),
            ("incomplete native distribution",
             dict(registry=registry_for(package_tar(version=installer.INITIAL_VERSION, omit="package/claude")),
                  fetch=lambda _url: package_tar(version=installer.INITIAL_VERSION, omit="package/claude"))),
        ]
        for message, dependencies in failures:
            with self.assertRaisesRegex(installer.InstallerError, message):
                installer.install(self.root, platform=self.platform,
                                  native_check=lambda _runtime: None,
                                  progress=lambda _message: None, **dependencies)
            self.assertEqual((self.root / "default.json").read_bytes(), default)
            self.assertEqual(installer.inspect(self.root, platform=self.platform)["version"], "2.1.280")
            self.assertIsNone(installer.required(self.root, platform=self.platform))
            self.assertFalse((self.root / "runtimes/2.1.281-darwin-arm64").exists())
        result = installer.install(self.root, platform=self.platform, registry=registry_for(payload),
                                   fetch=lambda _url: payload, native_check=lambda _runtime: None,
                                   progress=lambda _message: None)
        self.assertEqual(result["version"], "2.1.281")
        self.assertEqual(installer.inspect(self.root, platform=self.platform)["version"], "2.1.281")
        self.assertEqual({p: p.read_bytes() for p in sorted(old.rglob("*")) if p.is_file()}, before)
        self.assertTrue(os.access(old / "claude", os.X_OK))
        self.assertEqual(marker.read_bytes(), marker_content)

    def test_install_moves_an_older_default_to_the_checkout_pin_without_deleting_it(self):
        self.stage("2.0.10")
        installer.activate(self.root, "2.0.10", "-", platform=self.platform)
        payload = package_tar(version=installer.INITIAL_VERSION)
        result = installer.install(
            self.root, platform=self.platform, registry=registry_for(payload),
            fetch=lambda _url: payload, native_check=lambda _runtime: None,
            progress=lambda _message: None,
        )
        self.assertEqual(result["version"], installer.INITIAL_VERSION)
        self.assertTrue((self.root / "runtimes/2.0.10-darwin-arm64").is_dir())

    def test_download_and_incomplete_tree_failures_preserve_working_default_and_credentials(self):
        self.stage("1.0.0")
        installer.activate(self.root, "1.0.0", "-", platform=self.platform)
        default = (self.root / "default.json").read_bytes()
        marker, marker_content = self.accounts_marker()
        launches = []
        def failed_download(_):
            raise installer.InstallerError("download failed")
        with self.assertRaisesRegex(installer.InstallerError, "download failed"):
            self.stage("2.0.0", fetch=failed_download,
                       native_check=lambda _: launches.append(True))
        incomplete = package_tar(version="2.0.0", omit="package/claude")
        with self.assertRaisesRegex(installer.InstallerError, "incomplete native distribution"):
            self.stage("2.0.0", payload=incomplete, native_check=lambda _: launches.append(True))
        self.assertEqual(launches, [])
        self.assertEqual((self.root / "default.json").read_bytes(), default)
        self.assertEqual(marker.read_bytes(), marker_content)
        self.assertEqual(sorted(p.name for p in (self.root / ".staging").iterdir()),
                          [installer.OWNED_DIRECTORY_MARKER])
        self.stage("2.0.0")
        self.assertEqual(installer.inspect(self.root, platform=self.platform)["version"], "1.0.0")

    def test_native_resource_directory_is_rejected_before_launch(self):
        directory = tarfile.TarInfo("package/package.json")
        directory.type, directory.mode = tarfile.DIRTYPE, 0o755
        payload = package_tar(omit="package/package.json", unsafe=directory)
        launches = []
        with self.assertRaisesRegex(installer.InstallerError, "incomplete native distribution"):
            self.stage(payload=payload, native_check=lambda _: launches.append(True))
        self.assertEqual(launches, [])
        self.assertIsNone(installer.inspect(self.root, platform=self.platform))
        self.stage()

    def test_mac_architecture_selection_and_pinned_release_policy(self):
        self.assertEqual(installer.platform_name("arm64", "Darwin"), "darwin-arm64")
        self.assertEqual(installer.platform_name("x86_64", "Darwin"), "darwin-x64")
        with self.assertRaises(installer.InstallerError):
            installer.platform_name("arm64", "Linux")
        self.assertFalse(self.root.exists())
        with self.assertRaisesRegex(installer.InstallerError, "invalid installer command"):
            installer._main([str(self.root), "latest"])

    def test_stage_resolves_the_plain_pin_as_the_registry_version_not_a_platform_suffix(self):
        seen = []
        payload = package_tar(version="1.2.3")
        self.stage("1.2.3", payload, registry=lambda package, version: (seen.append((package, version)) or registry_for(payload)(package, version)))
        self.assertEqual(seen, [(PACKAGE, "1.2.3")])

    def test_integrity_failure_never_extracts_or_launches_and_clean_retry_succeeds(self):
        payload = package_tar()
        calls = []
        metadata = registry_for(payload)(PACKAGE, "9.9.9")
        metadata["dist"]["integrity"] = "sha512-AAAA"
        marker, marker_content = self.accounts_marker()
        with self.assertRaisesRegex(installer.InstallerError, "integrity mismatch"):
            installer.stage(self.root, "9.9.9", platform=self.platform,
                            registry=lambda _p, _v: metadata,
                            fetch=lambda _url: payload, native_check=lambda _runtime: calls.append("launch"),
                            progress=lambda _message: None)
        self.assertFalse((self.root / "runtimes").exists())
        self.assertFalse((self.root / ".staging").exists())
        self.assertEqual(calls, [])
        self.assertEqual(marker.read_bytes(), marker_content)
        self.stage(payload=payload)
        self.assertTrue((self.root / "runtimes/9.9.9-darwin-arm64").is_dir())

    def test_integrity_failure_preserves_existing_working_runtime_and_default(self):
        self.stage("1.0.0")
        installer.activate(self.root, "1.0.0", "-", platform=self.platform)
        default = (self.root / "default.json").read_bytes()
        runtime = self.root / "runtimes/1.0.0-darwin-arm64"
        before = {p: p.read_bytes() for p in sorted(runtime.rglob("*")) if p.is_file()}
        marker, marker_content = self.accounts_marker()
        payload = package_tar(version="2.0.0")
        metadata = registry_for(payload)(PACKAGE, "2.0.0")
        metadata["dist"]["integrity"] = "sha512-AAAA"
        with self.assertRaisesRegex(installer.InstallerError, "integrity mismatch"):
            installer.stage(self.root, "2.0.0", platform=self.platform,
                            registry=lambda _p, _v: metadata,
                            fetch=lambda _url: payload, native_check=lambda _runtime: None,
                            progress=lambda _message: None)
        self.assertEqual((self.root / "default.json").read_bytes(), default)
        after = {p: p.read_bytes() for p in sorted(runtime.rglob("*")) if p.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(marker.read_bytes(), marker_content)
        self.assertFalse((self.root / "runtimes/2.0.0-darwin-arm64").exists())

    def test_native_check_failure_publishes_nothing(self):
        payload = package_tar()
        marker, marker_content = self.accounts_marker()
        def failing_check(_runtime):
            raise installer.InstallerError("validated native Claude Code runtime rejected --version")
        with self.assertRaisesRegex(installer.InstallerError, "rejected --version"):
            self.stage(payload=payload, native_check=failing_check)
        self.assertFalse((self.root / "runtimes").exists())
        self.assertEqual(sorted(p.name for p in (self.root / ".staging").iterdir()),
                          [installer.OWNED_DIRECTORY_MARKER])
        self.assertEqual(marker.read_bytes(), marker_content)

    def test_registry_metadata_identity_mismatches_are_refused(self):
        payload = package_tar()
        good = registry_for(payload)(PACKAGE, "9.9.9")
        for mutate in (
            lambda m: m.__setitem__("name", "@anthropic-ai/claude-code-darwin-x64"),
            lambda m: m.__setitem__("version", "9.9.8"),
            lambda m: m.__setitem__("cpu", ["x64"]),
            lambda m: m.__setitem__("os", ["linux"]),
        ):
            metadata = dict(good)
            metadata["dist"] = dict(good["dist"])
            mutate(metadata)
            with self.assertRaisesRegex(installer.InstallerError, "does not match requested platform"):
                installer.stage(self.root, "9.9.9", platform=self.platform, registry=lambda _p, _v: metadata,
                                fetch=lambda _url: payload, native_check=lambda _runtime: None, progress=lambda _message: None)
            self.assertFalse((self.root / "runtimes").exists())

    def test_unsafe_archive_type_and_path_leave_no_runtime(self):
        link = tarfile.TarInfo("package/escape")
        link.type, link.linkname = tarfile.SYMTYPE, "/tmp/escape"
        calls = []
        with self.assertRaisesRegex(installer.InstallerError, "unsafe archive entry type"):
            self.stage(payload=package_tar(unsafe=link), native_check=lambda _runtime: calls.append("launch"))
        self.assertFalse((self.root / "runtimes").exists())
        path = tarfile.TarInfo("package/../../outside")
        path.size = 0
        with self.assertRaisesRegex(installer.InstallerError, "unsafe archive path"):
            self.stage(payload=package_tar(unsafe=path), native_check=lambda _runtime: calls.append("launch"))
        self.assertFalse((self.root / "runtimes").exists())
        wrong_root = tarfile.TarInfo("other/claude")
        wrong_root.size = 0
        with self.assertRaisesRegex(installer.InstallerError, "unexpected archive root"):
            self.stage(payload=package_tar(unsafe=wrong_root), native_check=lambda _runtime: calls.append("launch"))
        self.assertFalse((self.root / "runtimes").exists())
        self.assertEqual(calls, [])

    def test_tampered_or_unexpected_runtime_is_refused(self):
        self.stage()
        runtime = self.root / "runtimes/9.9.9-darwin-arm64"
        (runtime / "unexpected").write_text("bad")
        with self.assertRaisesRegex(installer.InstallerError, "do not match immutable manifest"):
            installer.verify_runtime(self.root, "9.9.9", self.platform)
        with self.assertRaisesRegex(installer.InstallerError, "do not match immutable manifest"):
            self.stage()
        (runtime / "unexpected").unlink()
        original_bytes = (runtime / "package.json").read_bytes()
        (runtime / "package.json").chmod(0o600)
        with self.assertRaisesRegex(installer.InstallerError, "do not match immutable manifest"):
            installer.verify_runtime(self.root, "9.9.9", self.platform)
        (runtime / "package.json").chmod(0o644)
        (runtime / "package.json").write_bytes(original_bytes)

    def test_foreign_occupant_at_runtime_target_is_reported_and_left_untouched(self):
        occupant = self.root / "runtimes" / "9.9.9-darwin-arm64"
        occupant.mkdir(parents=True)
        (occupant / "not-ours.txt").write_bytes(b"foreign content")
        marker, marker_content = self.accounts_marker()
        with self.assertRaisesRegex(installer.InstallerError, "unrecognized managed installer directory|missing or incomplete"):
            self.stage()
        self.assertEqual((occupant / "not-ours.txt").read_bytes(), b"foreign content")
        self.assertEqual(marker.read_bytes(), marker_content)

    def test_invalid_metadata_urls_and_owned_symlinks_are_refused(self):
        payload = package_tar()
        metadata = registry_for(payload)(PACKAGE, "9.9.9")
        metadata["dist"]["tarball"] = "https://example.invalid/claude.tgz"
        with self.assertRaisesRegex(installer.InstallerError, "tarball URL"):
            installer.stage(self.root, "9.9.9", platform=self.platform, registry=lambda _p, _v: metadata,
                            fetch=lambda _url: payload, native_check=lambda _runtime: None, progress=lambda _message: None)
        self.root.mkdir()
        (self.root / "default.json").symlink_to("missing")
        with self.assertRaisesRegex(installer.InstallerError, "unexpected managed installer occupant"):
            installer.inspect(self.root, platform=self.platform)

    def test_native_probe_uses_private_minimal_environment_and_checks_pinned_version_stdout(self):
        runtime = {"executable": "/fixture/claude", "version": "2.1.281"}
        calls = []
        def fake_run(*args, **kwargs):
            calls.append(kwargs)
            return mock.Mock(returncode=0, stdout="2.1.281\n", stderr="")
        with mock.patch.object(installer.subprocess, "run", side_effect=fake_run):
            installer._native_check(runtime)
        self.assertEqual(len(calls), 1)
        call = calls[0]
        self.assertEqual(call["env"]["PATH"], "/usr/bin:/bin")
        self.assertEqual(call["env"]["DISABLE_AUTOUPDATER"], "1")
        self.assertEqual(call["env"]["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
        self.assertEqual(call["env"]["NO_COLOR"], "1")
        self.assertEqual(call["env"]["HOME"], call["env"]["CLAUDE_CONFIG_DIR"])
        self.assertNotIn("ANTHROPIC_API_KEY", call["env"])
        self.assertEqual(call["timeout"], 60)

        def fake_run_wrong_version(*args, **kwargs):
            return mock.Mock(returncode=0, stdout="9.9.9\n", stderr="")
        with mock.patch.object(installer.subprocess, "run", side_effect=fake_run_wrong_version):
            with self.assertRaisesRegex(installer.InstallerError, "rejected --version"):
                installer._native_check(runtime)

    def test_private_root_ancestors_are_created_and_unrecognized_runtime_dir_is_refused(self):
        nested = Path(self.directory.name) / "missing/Library/Application Support/Kogen/claude"
        payload = package_tar(version="3.0.0")
        installer.stage(nested, "3.0.0", platform=self.platform, registry=registry_for(payload),
                        fetch=lambda _url: payload, native_check=lambda _runtime: None, progress=lambda _message: None)
        self.assertTrue((nested / "runtimes" / installer.OWNED_DIRECTORY_MARKER).is_file())
        other = Path(self.directory.name) / "other"
        (other / "runtimes").mkdir(parents=True)
        with self.assertRaisesRegex(installer.InstallerError, "unrecognized managed installer directory"):
            installer.stage(other, "3.0.0", platform=self.platform, registry=registry_for(payload),
                            fetch=lambda _url: payload, native_check=lambda _runtime: None, progress=lambda _message: None)

    def test_concurrent_expected_activation_has_one_winner(self):
        self.stage("1.0.0")
        self.stage("2.0.0")
        outcomes = []
        barrier = threading.Barrier(2)

        def activate(version):
            barrier.wait()
            try:
                installer.activate(self.root, version, "-", platform=self.platform)
                outcomes.append((version, "ok"))
            except installer.InstallerError:
                outcomes.append((version, "changed"))

        one = threading.Thread(target=activate, args=("1.0.0",))
        two = threading.Thread(target=activate, args=("2.0.0",))
        one.start(); two.start(); one.join(); two.join()
        self.assertEqual(sorted(value for _version, value in outcomes), ["changed", "ok"])
        self.assertIn(installer.inspect(self.root, platform=self.platform)["version"], {"1.0.0", "2.0.0"})

    def test_promotion_does_not_replace_an_unrelated_empty_directory_created_at_rename(self):
        promote = installer._promote
        def occupy_then_promote(source, destination):
            destination.mkdir()
            return promote(source, destination)
        with mock.patch.object(installer, "_promote", side_effect=occupy_then_promote):
            with self.assertRaisesRegex(installer.InstallerError, "promotion refused"):
                self.stage()
        target = self.root / "runtimes/9.9.9-darwin-arm64"
        self.assertTrue(target.is_dir())
        self.assertEqual(list(target.iterdir()), [])
        self.assertFalse((self.root / "default.json").exists())

    def test_required_ignores_a_different_retained_default_version(self):
        self.stage("1.0.0")
        installer.activate(self.root, "1.0.0", "-", platform=self.platform)
        self.assertIsNone(installer.required(self.root, platform=self.platform))
        payload = package_tar(version=installer.INITIAL_VERSION)
        installer.stage(self.root, installer.INITIAL_VERSION, platform=self.platform,
                        registry=registry_for(payload), fetch=lambda _url: payload,
                        native_check=lambda _runtime: None, progress=lambda _message: None)
        pinned = installer.required(self.root, platform=self.platform)
        self.assertEqual(pinned["version"], installer.INITIAL_VERSION)
        self.assertEqual(installer.inspect(self.root, platform=self.platform)["version"], "1.0.0")


if __name__ == "__main__":
    unittest.main()
