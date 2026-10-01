#![deny(warnings)]

use std::env;
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT_DIR: AtomicUsize = AtomicUsize::new(0);
const ARG_SEPARATOR: u8 = 1;

struct TestArea(PathBuf);

impl TestArea {
    fn new(label: &str) -> Self {
        let sequence = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
        let path = env::temp_dir().join(format!(
            "kogen cli test {} {sequence} {label}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("create test area");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn dir(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::create_dir_all(&path).expect("create test directory");
        path
    }
}

impl Drop for TestArea {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct FakeMix {
    bin_dir: PathBuf,
    args_path: PathBuf,
    cwd_path: PathBuf,
    git_env_path: PathBuf,
}

impl FakeMix {
    fn install(area: &TestArea) -> Self {
        let bin_dir = area.dir("fake mix bin");
        let args_path = area.path().join("mix argv.bin");
        let cwd_path = area.path().join("mix cwd.txt");
        let git_env_path = area.path().join("mix git env.txt");
        let script = bin_dir.join("mix");
        let mut file = File::create(&script).expect("create fake mix");
        file.write_all(
            b"#!/bin/sh\nprintf '%s\\001' \"$@\" > \"$KOGEN_TEST_ARGS\"\nprintf '%s' \"$PWD\" > \"$KOGEN_TEST_CWD\"\nprintf 'GIT_DIR=%s\\n' \"${GIT_DIR-unset}\" > \"$KOGEN_TEST_GIT_ENV\"\nprintf 'GIT_WORK_TREE=%s\\n' \"${GIT_WORK_TREE-unset}\" >> \"$KOGEN_TEST_GIT_ENV\"\nprintf 'engine stdout\\n'\nprintf 'engine stderr\\n' >&2\nexit \"$KOGEN_TEST_EXIT\"\n",
        )
        .expect("write fake mix");
        let mut permissions = fs::metadata(&script)
            .expect("read fake mix metadata")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script, permissions).expect("make fake mix executable");
        Self {
            bin_dir,
            args_path,
            cwd_path,
            git_env_path,
        }
    }

    fn env_path(&self) -> std::ffi::OsString {
        prepend_path(&self.bin_dir, env::var_os("PATH").unwrap_or_default())
    }

    fn assert_capture(&self, expected_args: &[&str], expected_cwd: &Path) {
        let capture = fs::read(&self.args_path).expect("fake mix captured argv");
        let actual_args = capture
            .split(|byte| *byte == ARG_SEPARATOR)
            .filter(|arg| !arg.is_empty())
            .map(|arg| String::from_utf8(arg.to_vec()).expect("UTF-8 fake argv"))
            .collect::<Vec<_>>();
        assert_eq!(actual_args, expected_args);
        let actual_cwd = fs::read_to_string(&self.cwd_path).expect("fake mix captured cwd");
        assert_eq!(actual_cwd, expected_cwd.to_string_lossy());
    }

    fn was_started(&self) -> bool {
        self.args_path.exists()
    }
}

fn prepend_path(prefix: &Path, rest: std::ffi::OsString) -> std::ffi::OsString {
    let mut paths = vec![prefix.to_path_buf()];
    paths.extend(env::split_paths(&rest));
    env::join_paths(paths).expect("join PATH entries")
}

fn init_git_checkout(path: &Path) {
    fs::create_dir_all(path).expect("create Git checkout");
    let output = Command::new("git")
        .args(["init", "--quiet"])
        .current_dir(path)
        .output()
        .expect("run git init");
    assert!(output.status.success(), "git init failed: {:?}", output);
}

fn create_engine(path: &Path) {
    fs::create_dir_all(path).expect("create engine checkout");
    fs::write(path.join("mix.exs"), "defmodule Engine.MixProject do end\n")
        .expect("create engine mix.exs");
}

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_kogen"))
}

fn run_cli(cwd: &Path, args: &[&str], fake_mix: &FakeMix, exit_code: u8) -> Output {
    let mut command = Command::new(binary());
    command
        .args(args)
        .current_dir(cwd)
        .env("PATH", fake_mix.env_path())
        .env("KOGEN_TEST_ARGS", &fake_mix.args_path)
        .env("KOGEN_TEST_CWD", &fake_mix.cwd_path)
        .env("KOGEN_TEST_GIT_ENV", &fake_mix.git_env_path)
        .env("KOGEN_TEST_EXIT", exit_code.to_string());
    command.output().expect("run kogen binary")
}

#[test]
fn external_project_dispatch_keeps_args_paths_stdio_and_exit_status() {
    let area = TestArea::new("external dispatch");
    let project = area.path().join("target project");
    let project_alias = area.path().join("target alias");
    let engine = area.path().join("engine checkout");
    let engine_alias = area.path().join("engine alias");
    let invocation = area.dir("caller directory");
    let invocation_alias = area.path().join("caller alias");
    init_git_checkout(&project);
    create_engine(&engine);
    std::os::unix::fs::symlink(&project, &project_alias).expect("create target symlink");
    std::os::unix::fs::symlink(&engine, &engine_alias).expect("create engine symlink");
    std::os::unix::fs::symlink(&invocation, &invocation_alias).expect("create invocation symlink");
    let fake_mix = FakeMix::install(&area);

    let output = run_cli(
        &invocation_alias,
        &[
            "--project",
            project_alias.to_str().unwrap(),
            "--engine",
            engine_alias.to_str().unwrap(),
            "shape",
            "--brief",
            "./drafts/feature brief.md",
            "--configuration",
            "nightly route",
            "--request-id",
            "rid 42",
            "--interface",
            "chatgpt",
        ],
        &fake_mix,
        37,
    );

    assert_eq!(output.status.code(), Some(37));
    assert_eq!(output.stdout, b"engine stdout\n");
    assert_eq!(output.stderr, b"engine stderr\n");
    fake_mix.assert_capture(
        &[
            "run",
            "--no-compile",
            "-e",
            "Kogen.Command.main(System.argv())",
            "--",
            "--project",
            project.canonicalize().unwrap().to_str().unwrap(),
            "--invocation-root",
            invocation.canonicalize().unwrap().to_str().unwrap(),
            "shape",
            "--brief",
            "./drafts/feature brief.md",
            "--configuration",
            "nightly route",
            "--request-id",
            "rid 42",
            "--interface",
            "chatgpt",
        ],
        &engine.canonicalize().unwrap(),
    );
}

#[test]
fn current_directory_is_the_default_project_checkout() {
    let area = TestArea::new("default project directory");
    let project = area.dir("caller checkout");
    let engine = area.dir("engine checkout");
    init_git_checkout(&project);
    create_engine(&engine);
    let fake_mix = FakeMix::install(&area);

    let output = Command::new(binary())
        .args(["--engine", engine.to_str().unwrap(), "status", "session 3"])
        .current_dir(&project)
        .env("PATH", fake_mix.env_path())
        .env("KOGEN_TEST_ARGS", &fake_mix.args_path)
        .env("KOGEN_TEST_CWD", &fake_mix.cwd_path)
        .env("KOGEN_TEST_EXIT", "0")
        .output()
        .expect("run kogen without --project");

    assert_eq!(output.status.code(), Some(0));
    fake_mix.assert_capture(
        &[
            "run",
            "--no-compile",
            "-e",
            "Kogen.Command.main(System.argv())",
            "--",
            "--project",
            project.canonicalize().unwrap().to_str().unwrap(),
            "--invocation-root",
            project.canonicalize().unwrap().to_str().unwrap(),
            "status",
            "session 3",
        ],
        &engine.canonicalize().unwrap(),
    );
}

#[test]
fn default_project_must_be_a_git_checkout() {
    let area = TestArea::new("default non Git project");
    let project = area.dir("plain caller directory");
    let engine = area.dir("engine");
    create_engine(&engine);
    let fake_mix = FakeMix::install(&area);

    let output = Command::new(binary())
        .args(["--engine", engine.to_str().unwrap(), "status", "session"])
        .current_dir(&project)
        .env("PATH", fake_mix.env_path())
        .env("KOGEN_TEST_ARGS", &fake_mix.args_path)
        .env("KOGEN_TEST_CWD", &fake_mix.cwd_path)
        .env("KOGEN_TEST_EXIT", "0")
        .output()
        .expect("run kogen from a non-Git directory");

    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("not a Git checkout"));
    assert!(!fake_mix.was_started());
}

#[test]
fn engine_environment_selects_engine_from_outside_source_checkout() {
    let area = TestArea::new("engine environment");
    let project = area.dir("external project");
    let engine = area.dir("selected engine");
    let caller = area.dir("unrelated caller");
    init_git_checkout(&project);
    create_engine(&engine);
    let fake_mix = FakeMix::install(&area);

    let output = Command::new(binary())
        .args([
            OsStr::new("--project"),
            project.as_os_str(),
            OsStr::new("status"),
            OsStr::new("session 9"),
        ])
        .current_dir(&caller)
        .env("PATH", fake_mix.env_path())
        .env("KOGEN_TEST_ARGS", &fake_mix.args_path)
        .env("KOGEN_TEST_CWD", &fake_mix.cwd_path)
        .env("KOGEN_TEST_EXIT", "0")
        .env("KOGEN_ENGINE_ROOT", &engine)
        .output()
        .expect("run kogen binary with engine environment");

    assert_eq!(output.status.code(), Some(0));
    fake_mix.assert_capture(
        &[
            "run",
            "--no-compile",
            "-e",
            "Kogen.Command.main(System.argv())",
            "--",
            "--project",
            project.canonicalize().unwrap().to_str().unwrap(),
            "--invocation-root",
            caller.canonicalize().unwrap().to_str().unwrap(),
            "status",
            "session 9",
        ],
        &engine.canonicalize().unwrap(),
    );
}

#[test]
fn compiled_engine_default_works_from_outside_source_checkout() {
    let area = TestArea::new("compiled engine default");
    let project = area.dir("external project");
    let caller = area.dir("external caller");
    init_git_checkout(&project);
    let fake_mix = FakeMix::install(&area);
    let compiled_engine = Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("CLI crate is under native/kogen-cli")
        .canonicalize()
        .expect("canonical compiled engine root");

    let output = Command::new(binary())
        .args([
            OsStr::new("--project"),
            project.as_os_str(),
            OsStr::new("result"),
            OsStr::new("session 12"),
        ])
        .current_dir(&caller)
        .env("PATH", fake_mix.env_path())
        .env("KOGEN_TEST_ARGS", &fake_mix.args_path)
        .env("KOGEN_TEST_CWD", &fake_mix.cwd_path)
        .env("KOGEN_TEST_EXIT", "0")
        .env_remove("KOGEN_ENGINE_ROOT")
        .output()
        .expect("run kogen binary with compiled engine default");

    assert_eq!(output.status.code(), Some(0));
    fake_mix.assert_capture(
        &[
            "run",
            "--no-compile",
            "-e",
            "Kogen.Command.main(System.argv())",
            "--",
            "--project",
            project.canonicalize().unwrap().to_str().unwrap(),
            "--invocation-root",
            caller.canonicalize().unwrap().to_str().unwrap(),
            "result",
            "session 12",
        ],
        &compiled_engine,
    );
}

#[test]
fn ambient_git_repository_overrides_do_not_redirect_project_or_engine() {
    let area = TestArea::new("ambient Git overrides");
    let project = area.dir("selected checkout");
    let decoy = area.dir("ambient checkout");
    let engine = area.dir("engine checkout");
    let caller = area.dir("caller");
    init_git_checkout(&project);
    init_git_checkout(&decoy);
    create_engine(&engine);
    let fake_mix = FakeMix::install(&area);

    let output = Command::new(binary())
        .args([
            "--project",
            project.to_str().unwrap(),
            "--engine",
            engine.to_str().unwrap(),
            "status",
            "session 1",
        ])
        .current_dir(&caller)
        .env("PATH", fake_mix.env_path())
        .env("KOGEN_TEST_ARGS", &fake_mix.args_path)
        .env("KOGEN_TEST_CWD", &fake_mix.cwd_path)
        .env("KOGEN_TEST_GIT_ENV", &fake_mix.git_env_path)
        .env("KOGEN_TEST_EXIT", "0")
        .env("GIT_DIR", decoy.join(".git"))
        .env("GIT_WORK_TREE", &decoy)
        .output()
        .expect("run kogen with ambient Git overrides");

    assert_eq!(output.status.code(), Some(0));
    fake_mix.assert_capture(
        &[
            "run",
            "--no-compile",
            "-e",
            "Kogen.Command.main(System.argv())",
            "--",
            "--project",
            project.canonicalize().unwrap().to_str().unwrap(),
            "--invocation-root",
            caller.canonicalize().unwrap().to_str().unwrap(),
            "status",
            "session 1",
        ],
        &engine.canonicalize().unwrap(),
    );
    assert_eq!(
        fs::read_to_string(&fake_mix.git_env_path).unwrap(),
        "GIT_DIR=unset\nGIT_WORK_TREE=unset\n"
    );
}

#[test]
fn ambient_git_repository_overrides_do_not_make_plain_directory_a_checkout() {
    let area = TestArea::new("ambient Git false checkout");
    let project = area.dir("plain target");
    let decoy = area.dir("unrelated checkout");
    let engine = area.dir("engine");
    let caller = area.dir("caller");
    init_git_checkout(&decoy);
    create_engine(&engine);
    let fake_mix = FakeMix::install(&area);

    let output = Command::new(binary())
        .args([
            "--project",
            project.to_str().unwrap(),
            "--engine",
            engine.to_str().unwrap(),
            "status",
            "session",
        ])
        .current_dir(&caller)
        .env("PATH", fake_mix.env_path())
        .env("KOGEN_TEST_ARGS", &fake_mix.args_path)
        .env("KOGEN_TEST_CWD", &fake_mix.cwd_path)
        .env("KOGEN_TEST_GIT_ENV", &fake_mix.git_env_path)
        .env("KOGEN_TEST_EXIT", "0")
        .env("GIT_DIR", decoy.join(".git"))
        .env("GIT_WORK_TREE", &decoy)
        .output()
        .expect("run kogen with ambient Git overrides and a plain target");

    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("not a Git checkout"));
    assert!(!fake_mix.was_started());
}

#[test]
fn malformed_globals_are_refused_before_git_or_engine_dispatch() {
    let area = TestArea::new("malformed globals");
    let project = area.dir("not a checkout");
    let engine = area.dir("engine");
    let caller = area.dir("caller");
    create_engine(&engine);
    let fake_mix = FakeMix::install(&area);
    let cases = [
        vec!["--engine", engine.to_str().unwrap(), "shape"],
        vec![
            "--project",
            project.to_str().unwrap(),
            "--project",
            project.to_str().unwrap(),
            "shape",
        ],
        vec!["--project", project.to_str().unwrap(), "--unknown", "shape"],
        vec!["--project", "--engine", engine.to_str().unwrap(), "shape"],
    ];

    for args in cases {
        let output = run_cli(&caller, &args, &fake_mix, 0);
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains("usage: kogen [--project PATH] [--engine PATH]")
        );
    }
    assert!(!fake_mix.was_started());
}

#[test]
fn non_git_project_is_refused_without_starting_engine() {
    let area = TestArea::new("non Git target");
    let project = area.dir("plain directory");
    let engine = area.dir("engine");
    let caller = area.dir("caller");
    create_engine(&engine);
    let fake_mix = FakeMix::install(&area);

    let output = run_cli(
        &caller,
        &[
            "--project",
            project.to_str().unwrap(),
            "--engine",
            engine.to_str().unwrap(),
            "status",
            "session",
        ],
        &fake_mix,
        0,
    );

    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("not a Git checkout"));
    assert!(!fake_mix.was_started());
}

#[test]
fn engine_and_project_must_resolve_to_distinct_directories() {
    let area = TestArea::new("same engine and target");
    let project = area.dir("one checkout");
    let caller = area.dir("caller");
    init_git_checkout(&project);
    create_engine(&project);
    let fake_mix = FakeMix::install(&area);

    let output = run_cli(
        &caller,
        &[
            "--project",
            project.to_str().unwrap(),
            "--engine",
            project.to_str().unwrap(),
            "build",
            "slug",
        ],
        &fake_mix,
        0,
    );

    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("must be different directories"));
    assert!(!fake_mix.was_started());
}

#[test]
fn help_documents_retained_headless_operation_flags() {
    let output = Command::new(binary())
        .arg("--help")
        .output()
        .expect("run kogen help");
    let alias = Command::new(binary())
        .arg("help")
        .output()
        .expect("run kogen help alias");
    let help = String::from_utf8(output.stdout).expect("UTF-8 help");

    assert_eq!(output.status.code(), Some(0));
    assert!(output.stderr.is_empty());
    assert_eq!(alias.status.code(), Some(0));
    assert_eq!(alias.stdout.as_slice(), help.as_bytes());
    assert!(help.contains("kogen [--project PATH] [--engine PATH] <command> [args...]"));
    assert!(help.contains("--project PATH  Git checkout to work on (default: current directory)"));
    for fragment in [
        "shape --brief FILE [--configuration NAME] [--request-id RID]",
        "input SESSION --file FILE",
        "present SESSION",
        "approve SESSION --presentation ID [--request-id RID]",
        "build SLUG [--configuration NAME]",
        "status SESSION",
        "cancel SESSION [--request-id RID]",
        "resume SESSION --file FILE",
        "result SESSION",
    ] {
        assert!(help.contains(fragment), "help lacks {fragment:?}");
    }
    assert!(!help.contains("--interface"));
}
