"""Offline, synthetic checks for priv/kogen/codex/install.py."""
import base64
import hashlib
import http.client
import importlib.util
import io
import tarfile
import tempfile
import threading
import unittest
from unittest import mock
from pathlib import Path


INSTALLER = Path(__file__).parents[2] / "priv/kogen/codex/install.py"
spec = importlib.util.spec_from_file_location("kogen_codex_installer", INSTALLER)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def package_tar(extra=None, unsafe=None, omit=None):
    stream = io.BytesIO()
    triple = "aarch64-apple-darwin"
    # Literal observed native package layout; do not derive this from the
    # installer's required-path helper or the fixture could mirror its defect.
    files = {
        "package/vendor/aarch64-apple-darwin/bin/codex": b"native codex",
        "package/vendor/aarch64-apple-darwin/bin/codex-code-mode-host": b"host",
        "package/vendor/aarch64-apple-darwin/codex-path/rg": b"rg",
        "package/vendor/aarch64-apple-darwin/codex-resources/zsh/bin/zsh": b"zsh",
        "package/vendor/aarch64-apple-darwin/codex-package.json": b'{"name":"codex-native"}',
    }
    files.update(extra or {})
    if omit:
        files.pop(omit)
    with tarfile.open(fileobj=stream, mode="w:gz") as tar:
        for name, body in files.items():
            item = tarfile.TarInfo(name)
            item.size, item.mode = len(body), 0o755
            tar.addfile(item, io.BytesIO(body))
        if unsafe:
            tar.addfile(unsafe)
    return stream.getvalue()


def registry_for(payload):
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(payload).digest()).decode()
    def registry(package, version):
        if package != "@openai/codex" or version is None:
            raise AssertionError((package, version))
        return {"name": package, "version": version, "os": ["darwin"], "cpu": ["arm64"],
                "dist": {"tarball": "https://registry.npmjs.org/fixture.tgz", "integrity": integrity}}
    return registry


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name) / "private-runtime"
        self.platform = "darwin-arm64"

    def tearDown(self):
        self.directory.cleanup()

    def stage(self, version="9.9.9", payload=None, **kwargs):
        payload = payload or package_tar()
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

    def test_stage_preserves_full_native_tree_and_manifest(self):
        result = self.stage()
        self.assertEqual(result["version"], "9.9.9")
        self.assertTrue(result["executable"].endswith("vendor/aarch64-apple-darwin/bin/codex"))
        manifest = Path(result["path"]) / installer.MANIFEST
        self.assertIn("vendor/aarch64-apple-darwin/codex-resources/zsh/bin/zsh", manifest.read_text())
        self.assertIn("vendor/aarch64-apple-darwin/codex-package.json", manifest.read_text())
        self.assertEqual(installer.inspect(self.root, platform=self.platform), None)
        active = installer.activate(self.root, "9.9.9", "-", platform=self.platform)
        self.assertEqual(active, result)

    def test_install_selects_initial_exact_release_and_repeat_preserves_native_state(self):
        payload, selected, launches = package_tar(), [], []
        def registry(package, version):
            selected.append(version)
            return registry_for(payload)(package, version)
        first = installer.install(self.root, platform=self.platform, registry=registry,
            fetch=lambda _: payload, native_check=lambda runtime: launches.append(runtime["version"]),
            progress=lambda _: None)
        self.assertEqual(selected, ["0.156.1-darwin-arm64"])
        self.assertEqual(launches, ["0.156.1"])
        account = self.root / "account-state"
        account.write_bytes(b"synthetic-credentials-and-retained-conversations")
        repeated = installer.install(self.root, platform=self.platform,
            registry=lambda *_: self.fail("repeated install fetched metadata"))
        self.assertEqual(repeated, first)
        self.assertEqual(account.read_bytes(), b"synthetic-credentials-and-retained-conversations")

    def test_production_pin_uses_tracked_artifact_metadata_without_registry_lookup(self):
        payload = package_tar()
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

    def test_install_moves_an_older_default_to_the_checkout_pin_without_deleting_it(self):
        previous = self.stage("0.154.0")
        installer.activate(self.root, "0.154.0", "-", platform=self.platform)
        account = self.root / "accounts/shared/auth.json"
        account.parent.mkdir(parents=True)
        account.write_bytes(b"synthetic-account")
        payload = package_tar()
        result = installer.install(
            self.root, platform=self.platform, registry=registry_for(payload),
            fetch=lambda _url: payload, native_check=lambda _runtime: None,
            progress=lambda _message: None,
        )
        self.assertEqual(installer.INITIAL_VERSION, "0.156.1")
        self.assertEqual(result["version"], "0.156.1")
        self.assertEqual(installer.inspect(self.root, platform=self.platform), result)
        # The retained 0.154.0 tree still verifies at its original executable,
        # so an operation that selected it before activation keeps working.
        self.assertEqual(installer.verify_runtime(self.root, "0.154.0", self.platform), previous)
        self.assertNotEqual(previous["executable"], result["executable"])
        self.assertEqual(account.read_bytes(), b"synthetic-account")

    def test_failed_pinned_upgrade_keeps_the_working_prior_runtime_selected(self):
        previous = self.stage("0.154.0")
        installer.activate(self.root, "0.154.0", "-", platform=self.platform)
        default = (self.root / "default.json").read_bytes()
        account = self.root / "accounts/shared/auth.json"
        account.parent.mkdir(parents=True)
        account.write_bytes(b"synthetic-account")
        payload = package_tar()
        def rejected_native(_runtime):
            raise installer.InstallerError("native validation failed")
        failures = [
            dict(fetch=lambda _url: package_tar(extra={"package/extra": b"x"})),
            dict(fetch=lambda _url: package_tar(omit="package/vendor/aarch64-apple-darwin/codex-path/rg"),
                 registry=registry_for(package_tar(omit="package/vendor/aarch64-apple-darwin/codex-path/rg"))),
            dict(fetch=lambda _url: payload, native_check=rejected_native),
        ]
        for failure in failures:
            with self.assertRaises(installer.InstallerError):
                installer.install(self.root, platform=self.platform,
                                  registry=failure.get("registry", registry_for(payload)),
                                  fetch=failure["fetch"],
                                  native_check=failure.get("native_check", lambda _runtime: None),
                                  progress=lambda _message: None)
            self.assertEqual((self.root / "default.json").read_bytes(), default)
            self.assertFalse((self.root / "runtimes/0.156.1-darwin-arm64").exists())
            self.assertIsNone(installer.required(self.root, platform=self.platform))
            self.assertEqual(installer.inspect(self.root, platform=self.platform), previous)
            self.assertEqual(account.read_bytes(), b"synthetic-account")
        retried = installer.install(self.root, platform=self.platform, registry=registry_for(payload),
                                    fetch=lambda _url: payload, native_check=lambda _runtime: None,
                                    progress=lambda _message: None)
        self.assertEqual(retried["version"], "0.156.1")
        self.assertEqual(installer.verify_runtime(self.root, "0.154.0", self.platform), previous)

    def test_download_and_incomplete_tree_failures_preserve_working_default_and_credentials(self):
        self.stage("1.0.0")
        installer.activate(self.root, "1.0.0", "-", platform=self.platform)
        default = (self.root / "default.json").read_bytes()
        account = self.root / "auth-fixture"
        account.write_bytes(b"synthetic-account")
        launches = []
        def failed_download(_):
            raise installer.InstallerError("download failed")
        with self.assertRaisesRegex(installer.InstallerError, "download failed"):
            self.stage("2.0.0", fetch=failed_download,
                       native_check=lambda _: launches.append(True))
        incomplete = package_tar(omit="package/vendor/aarch64-apple-darwin/codex-path/rg")
        with self.assertRaisesRegex(installer.InstallerError, "incomplete native distribution"):
            self.stage("2.0.0", payload=incomplete, native_check=lambda _: launches.append(True))
        self.assertEqual(launches, [])
        self.assertEqual((self.root / "default.json").read_bytes(), default)
        self.assertEqual(account.read_bytes(), b"synthetic-account")
        self.stage("2.0.0")
        self.assertEqual(installer.inspect(self.root, platform=self.platform)["version"], "1.0.0")

    def test_native_resource_directory_is_rejected_before_launch(self):
        path = "package/vendor/aarch64-apple-darwin/bin/codex-code-mode-host"
        directory = tarfile.TarInfo(path)
        directory.type, directory.mode = tarfile.DIRTYPE, 0o755
        payload = package_tar(omit=path, unsafe=directory)
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

    def test_stage_resolves_the_platform_as_a_version_not_a_registry_package_name(self):
        seen = []
        payload = package_tar()
        self.stage("1.2.3", payload, registry=lambda package, version: (seen.append((package, version)) or registry_for(payload)(package, version)))
        self.assertEqual(seen, [("@openai/codex", "1.2.3-darwin-arm64")])

    def test_integrity_failure_never_extracts_or_launches_and_clean_retry_succeeds(self):
        payload = package_tar()
        calls = []
        metadata = registry_for(payload)("@openai/codex", "9.9.9-darwin-arm64")
        metadata["dist"]["integrity"] = "sha512-AAAA"
        with self.assertRaisesRegex(installer.InstallerError, "integrity mismatch"):
            installer.stage(self.root, "9.9.9", platform=self.platform,
                            registry=lambda _p, _v: metadata,
                            fetch=lambda _url: payload, native_check=lambda _runtime: calls.append("launch"),
                            progress=lambda _message: None)
        self.assertFalse((self.root / "runtimes").exists())
        self.assertEqual(calls, [])
        self.stage(payload=payload)
        self.assertTrue((self.root / "runtimes/9.9.9-darwin-arm64").is_dir())

    def test_unsafe_archive_type_and_path_leave_no_runtime(self):
        link = tarfile.TarInfo("package/vendor/aarch64-apple-darwin/bin/escape")
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
        self.assertEqual(calls, [])

    def test_tampered_or_unexpected_runtime_is_refused(self):
        self.stage()
        runtime = self.root / "runtimes/9.9.9-darwin-arm64"
        (runtime / "unexpected").write_text("bad")
        with self.assertRaisesRegex(installer.InstallerError, "do not match immutable manifest"):
            installer.verify_runtime(self.root, "9.9.9", self.platform)
        with self.assertRaisesRegex(installer.InstallerError, "do not match immutable manifest"):
            self.stage()
        runtime = self.root / "runtimes/9.9.9-darwin-arm64"
        (runtime / "unexpected").unlink()
        (runtime / "vendor/aarch64-apple-darwin/codex-path/rg").chmod(0o644)
        with self.assertRaisesRegex(installer.InstallerError, "do not match immutable manifest"):
            installer.verify_runtime(self.root, "9.9.9", self.platform)

    def test_invalid_metadata_urls_and_owned_symlinks_are_refused(self):
        payload = package_tar()
        metadata = registry_for(payload)("@openai/codex", "9.9.9-darwin-arm64")
        metadata["dist"]["tarball"] = "https://example.invalid/codex.tgz"
        with self.assertRaisesRegex(installer.InstallerError, "tarball URL"):
            installer.stage(self.root, "9.9.9", platform=self.platform, registry=lambda _p, _v: metadata,
                            fetch=lambda _url: payload, native_check=lambda _runtime: None, progress=lambda _message: None)
        self.root.mkdir()
        (self.root / "default.json").symlink_to("missing")
        with self.assertRaisesRegex(installer.InstallerError, "unexpected managed installer occupant"):
            installer.inspect(self.root, platform=self.platform)

    def test_native_probe_uses_private_minimal_environment(self):
        runtime = {"executable": "/fixture/codex"}
        calls = []
        with mock.patch.object(installer.subprocess, "run", side_effect=lambda *args, **kwargs: calls.append(kwargs) or mock.Mock(returncode=0, stderr="")):
            installer._native_check(runtime)
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertEqual(call["env"]["PATH"], "/usr/bin:/bin")
            self.assertNotIn("OPENAI_API_KEY", call["env"])
            self.assertEqual(call["env"]["HOME"], call["env"]["CODEX_HOME"])

    def test_private_root_ancestors_are_created_and_unrecognized_runtime_dir_is_refused(self):
        nested = Path(self.directory.name) / "missing/Library/Application Support/Kogen/codex"
        payload = package_tar()
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


if __name__ == "__main__":
    unittest.main()
