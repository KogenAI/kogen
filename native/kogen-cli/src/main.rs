#![deny(warnings)]

use std::env;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, ExitStatus, Stdio};

const COMMANDS: &[&str] = &[
    "shape", "input", "present", "approve", "build", "status", "cancel", "resume", "result",
];

const USAGE: &str = "usage: kogen [--project PATH] [--engine PATH] <command> [args...]";
const HELP: &str = "\
Shape and build changes in a Git project through Kogen's workflow engine.

Usage:
  kogen [--project PATH] [--engine PATH] <command> [args...]

Global options:
  --project PATH  Git checkout to work on (default: current directory)
  --engine PATH   Kogen engine checkout (or KOGEN_ENGINE_ROOT)
  -h, --help      Show this help; 'help' is also accepted

Commands:
  shape start --brief FILE [--configuration NAME] [--request-id RID]
  shape input SESSION --file FILE
  shape present SESSION
  shape approve SESSION --presentation ID [--request-id RID]
  shape status SESSION
  shape cancel SESSION [--request-id RID]
  shape resume SESSION --file FILE
  build SLUG [--configuration NAME]
  result SESSION

Use 'kogen shape --help' or a command's '--help' for its syntax. Arguments
are handled by the engine. Relative input paths are resolved there from the
directory where kogen was invoked. The default engine path is the Kogen
checkout used to build this binary.
";

const SHAPE_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] shape <command> [args...]

Shaping commands:
  start --brief FILE [--configuration NAME] [--request-id RID]
  input SESSION --file FILE
  present SESSION
  approve SESSION --presentation ID [--request-id RID]
  status SESSION
  cancel SESSION [--request-id RID]
  resume SESSION --file FILE

Use 'kogen shape <command> --help' for command details. Global options are
listed by 'kogen --help'.
";

const SHAPE_START_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] shape start --brief FILE [--configuration NAME] [--request-id RID]

Start a Shaping session from a brief file.
";

const SHAPE_INPUT_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] shape input SESSION --file FILE

Record the requested input for an existing Shaping session.
";

const SHAPE_PRESENT_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] shape present SESSION

Show the current presentation for an existing Shaping session.
";

const SHAPE_APPROVE_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] shape approve SESSION --presentation ID [--request-id RID]

Approve the specified presentation for an existing Shaping session.
";

const SHAPE_STATUS_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] shape status SESSION

Show the current status of a Shaping session.
";

const SHAPE_CANCEL_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] shape cancel SESSION [--request-id RID]

Cancel an existing Shaping session.
";

const SHAPE_RESUME_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] shape resume SESSION --file FILE

Resume an existing Shaping session with a brief file.
";

const BUILD_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] build SLUG [--configuration NAME]

Build the approved Intent with the specified slug.
";

const RESULT_HELP: &str = "\
Usage:
  kogen [--project PATH] [--engine PATH] result SESSION

Read the result or current status for a session.
";

const ENGINE_EXPRESSION: &str = "Kogen.Command.main(System.argv())";

#[derive(Debug)]
struct CliError {
    message: String,
    exit_code: u8,
}

impl CliError {
    fn usage(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            exit_code: 2,
        }
    }

    fn runtime(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            exit_code: 1,
        }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

enum Invocation {
    Help(&'static str),
    Command {
        project: Option<PathBuf>,
        engine: Option<PathBuf>,
        command: OsString,
        args: Vec<OsString>,
    },
}

fn main() -> ExitCode {
    match run(env::args_os().skip(1).collect()) {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("kogen: {error}");
            if error.exit_code == 2 {
                eprintln!("{USAGE}");
            }
            ExitCode::from(error.exit_code)
        }
    }
}

fn run(args: Vec<OsString>) -> Result<u8, CliError> {
    let invocation_root = env::current_dir()
        .and_then(fs::canonicalize)
        .map_err(|error| {
            CliError::runtime(format!("cannot resolve invocation directory: {error}"))
        })?;

    let invocation = parse_args(args)?;
    let (project, engine, command, args) = match invocation {
        Invocation::Help(help) => {
            print!("{help}");
            return Ok(0);
        }
        Invocation::Command {
            project,
            engine,
            command,
            args,
        } => (project, engine, command, args),
    };

    let git_local_env = git_local_env_vars()?;
    let project = project.unwrap_or_else(|| invocation_root.clone());
    let project_root = resolve_project(&project, &invocation_root, &git_local_env)?;
    let engine_root = resolve_engine(engine.as_deref(), &invocation_root)?;
    if project_root == engine_root {
        return Err(CliError::usage(
            "the engine checkout and target project must be different directories",
        ));
    }

    dispatch(
        &engine_root,
        &project_root,
        &invocation_root,
        &command,
        &args,
        &git_local_env,
    )
}

fn parse_args(args: Vec<OsString>) -> Result<Invocation, CliError> {
    let mut project = None;
    let mut engine = None;
    let mut position = 0;

    while position < args.len() {
        let token = &args[position];
        if token == OsStr::new("--help") || token == OsStr::new("-h") || token == OsStr::new("help")
        {
            return Ok(Invocation::Help(HELP));
        }

        if token == OsStr::new("--project") {
            if project.is_some() {
                return Err(CliError::usage("--project may be specified only once"));
            }
            project = Some(PathBuf::from(take_global_value(
                &args,
                &mut position,
                "--project",
            )?));
            continue;
        }

        if token == OsStr::new("--engine") {
            if engine.is_some() {
                return Err(CliError::usage("--engine may be specified only once"));
            }
            engine = Some(PathBuf::from(take_global_value(
                &args,
                &mut position,
                "--engine",
            )?));
            continue;
        }

        if let Some(name) = token.to_str().filter(|name| COMMANDS.contains(name)) {
            let rest = &args[position + 1..];
            if name == "shape" {
                return parse_shape(project, engine, rest);
            }

            let help = command_help(name);
            if requests_help(rest) {
                return Ok(Invocation::Help(help));
            }

            return Ok(Invocation::Command {
                project,
                engine,
                command: OsString::from(name),
                args: rest.to_vec(),
            });
        }

        if token.to_string_lossy().starts_with('-') {
            return Err(CliError::usage(format!(
                "unknown global option: {}",
                token.to_string_lossy()
            )));
        }

        return Err(CliError::usage(format!(
            "unknown command: {}",
            token.to_string_lossy()
        )));
    }

    if args.is_empty() {
        Ok(Invocation::Help(HELP))
    } else {
        Err(CliError::usage("a command is required"))
    }
}

fn parse_shape(
    project: Option<PathBuf>,
    engine: Option<PathBuf>,
    args: &[OsString],
) -> Result<Invocation, CliError> {
    let Some(first) = args.first() else {
        return Ok(Invocation::Help(SHAPE_HELP));
    };

    if first == OsStr::new("help") || first == OsStr::new("-h") || first == OsStr::new("--help") {
        return Ok(Invocation::Help(SHAPE_HELP));
    }

    let Some(first_text) = first.to_str() else {
        return Err(CliError::usage("invalid shape command"));
    };

    let (command, rest, help) = match first_text {
        "start" => ("shape", &args[1..], SHAPE_START_HELP),
        "input" => ("input", &args[1..], SHAPE_INPUT_HELP),
        "present" => ("present", &args[1..], SHAPE_PRESENT_HELP),
        "approve" => ("approve", &args[1..], SHAPE_APPROVE_HELP),
        "status" => ("status", &args[1..], SHAPE_STATUS_HELP),
        "cancel" => ("cancel", &args[1..], SHAPE_CANCEL_HELP),
        "resume" => ("resume", &args[1..], SHAPE_RESUME_HELP),
        _ if first_text.starts_with('-') => ("shape", args, SHAPE_START_HELP),
        _ => {
            return Err(CliError::usage(format!(
                "unknown shape command: {first_text}"
            )));
        }
    };

    if requests_help(rest) {
        return Ok(Invocation::Help(help));
    }

    Ok(Invocation::Command {
        project,
        engine,
        command: OsString::from(command),
        args: rest.to_vec(),
    })
}

fn requests_help(args: &[OsString]) -> bool {
    args.iter()
        .any(|argument| argument == OsStr::new("--help") || argument == OsStr::new("-h"))
        || args
            .first()
            .is_some_and(|first| first == OsStr::new("help"))
}

fn command_help(command: &str) -> &'static str {
    match command {
        "build" => BUILD_HELP,
        "result" => RESULT_HELP,
        "input" => SHAPE_INPUT_HELP,
        "present" => SHAPE_PRESENT_HELP,
        "approve" => SHAPE_APPROVE_HELP,
        "status" => SHAPE_STATUS_HELP,
        "cancel" => SHAPE_CANCEL_HELP,
        "resume" => SHAPE_RESUME_HELP,
        _ => HELP,
    }
}

fn take_global_value<'a>(
    args: &'a [OsString],
    position: &mut usize,
    option: &str,
) -> Result<&'a OsStr, CliError> {
    *position += 1;
    let value = args
        .get(*position)
        .ok_or_else(|| CliError::usage(format!("{option} requires a path")))?;
    if value == OsStr::new("--project")
        || value == OsStr::new("--engine")
        || value == OsStr::new("--help")
        || value == OsStr::new("-h")
        || value.to_string_lossy().starts_with('-')
    {
        return Err(CliError::usage(format!("{option} requires a path")));
    }
    *position += 1;
    Ok(value)
}

fn git_local_env_vars() -> Result<Vec<OsString>, CliError> {
    let mut git = Command::new("git");
    git.args(["rev-parse", "--local-env-vars"]).env_clear();
    if let Some(path) = env::var_os("PATH") {
        git.env("PATH", path);
    }

    let output = git.output().map_err(|error| {
        CliError::runtime(format!(
            "cannot inspect Git's repository environment: {error}"
        ))
    })?;
    if !output.status.success() {
        return Err(CliError::runtime(
            "cannot inspect Git's repository environment",
        ));
    }

    let output = String::from_utf8(output.stdout)
        .map_err(|_| CliError::runtime("Git returned invalid local environment names"))?;
    Ok(output
        .split_ascii_whitespace()
        .filter(|name| name.starts_with("GIT_"))
        .map(OsString::from)
        .collect())
}

fn clear_git_local_env(command: &mut Command, names: &[OsString]) {
    for name in names {
        command.env_remove(name);
    }
}

fn resolve_project(
    project: &Path,
    invocation_root: &Path,
    git_local_env: &[OsString],
) -> Result<PathBuf, CliError> {
    let supplied_path = absolute_from(project, invocation_root);
    let canonical_input = fs::canonicalize(&supplied_path).map_err(|error| {
        CliError::usage(format!(
            "cannot resolve --project path {}: {error}",
            supplied_path.display()
        ))
    })?;
    if !canonical_input.is_dir() {
        return Err(CliError::usage(format!(
            "--project must be a directory: {}",
            canonical_input.display()
        )));
    }

    let mut git = Command::new("git");
    git.arg("-C")
        .arg(&canonical_input)
        .args(["rev-parse", "--show-toplevel"]);
    clear_git_local_env(&mut git, git_local_env);
    let output = git.output().map_err(|error| {
        CliError::runtime(format!("cannot run git to validate --project: {error}"))
    })?;

    if !output.status.success() {
        return Err(CliError::usage(format!(
            "--project is not a Git checkout: {}",
            canonical_input.display()
        )));
    }

    let root = String::from_utf8(output.stdout)
        .map_err(|_| CliError::runtime("git returned a non-UTF-8 project path"))?;
    let root = root.trim_end_matches(['\r', '\n']);
    let canonical_root = fs::canonicalize(root)
        .map_err(|error| CliError::runtime(format!("cannot resolve Git project root: {error}")))?;
    if !canonical_root.is_dir() {
        return Err(CliError::runtime(
            "git returned a project root that is not a directory",
        ));
    }
    Ok(canonical_root)
}

fn resolve_engine(engine: Option<&Path>, invocation_root: &Path) -> Result<PathBuf, CliError> {
    let selected = if let Some(engine) = engine {
        engine.to_path_buf()
    } else if let Some(root) = env::var_os("KOGEN_ENGINE_ROOT").filter(|value| !value.is_empty()) {
        PathBuf::from(root)
    } else {
        compiled_engine_root()
    };
    let selected = absolute_from(&selected, invocation_root);
    let canonical = fs::canonicalize(&selected).map_err(|error| {
        CliError::usage(format!(
            "cannot resolve engine path {}: {error}",
            selected.display()
        ))
    })?;
    if !canonical.is_dir() {
        return Err(CliError::usage(format!(
            "engine path must be a directory: {}",
            canonical.display()
        )));
    }
    if !canonical.join("mix.exs").is_file() {
        return Err(CliError::usage(format!(
            "engine path must contain mix.exs: {}",
            canonical.display()
        )));
    }
    Ok(canonical)
}

fn compiled_engine_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("the CLI crate is expected under native/kogen-cli")
        .to_path_buf()
}

fn absolute_from(path: &Path, base: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        base.join(path)
    }
}

fn dispatch(
    engine_root: &Path,
    project_root: &Path,
    invocation_root: &Path,
    command: &OsStr,
    args: &[OsString],
    git_local_env: &[OsString],
) -> Result<u8, CliError> {
    let mut child = Command::new("mix");
    child
        .args(["run", "--no-compile", "-e", ENGINE_EXPRESSION, "--"])
        .arg("--project")
        .arg(project_root)
        .arg("--invocation-root")
        .arg(invocation_root)
        .arg(command)
        .args(args)
        .current_dir(engine_root)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    clear_git_local_env(&mut child, git_local_env);

    let status = child.status().map_err(|error| CliError {
        message: format!("cannot start mix in {}: {error}", engine_root.display()),
        exit_code: 127,
    })?;
    Ok(status_code(status))
}

fn status_code(status: ExitStatus) -> u8 {
    if let Some(code) = status.code() {
        return code as u8;
    }

    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return (128 + signal).min(u8::MAX as i32) as u8;
        }
    }

    1
}
