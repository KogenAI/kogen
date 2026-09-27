#![deny(warnings)]
mod sha256;
use rusqlite::{Connection, Error as SqlError, ErrorCode, OptionalExtension, params};
use std::{
    env, fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
const USAGE: &str =
    "usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR]";
fn usage() -> i32 {
    eprintln!("{USAGE}");
    2
}
fn runtime(s: impl std::fmt::Display) -> i32 {
    eprintln!("kogen-ctx: {s}");
    1
}
fn home() -> Result<PathBuf, String> {
    if let Some(x) = env::var("KOGEN_CTX_HOME").ok().filter(|x| !x.is_empty()) {
        return Ok(x.into());
    }
    env::var("HOME")
        .ok()
        .filter(|x| !x.is_empty())
        .map(|x| PathBuf::from(x).join("Library/Caches/Kogen/ctx"))
        .ok_or("HOME is not set; set KOGEN_CTX_HOME to a writable directory".into())
}
fn root(a: Option<&str>) -> Result<PathBuf, String> {
    let p = a
        .map(PathBuf::from)
        .unwrap_or(env::current_dir().map_err(|e| e.to_string())?);
    if !p.is_dir() {
        return Err(format!("not a directory: {}", a.unwrap_or("")));
    }
    let o = Command::new("git")
        .args([
            "-C",
            p.to_string_lossy().as_ref(),
            "rev-parse",
            "--show-toplevel",
        ])
        .output()
        .map_err(|e| e.to_string())?;
    if !o.status.success() {
        return Err(format!(
            "not a Git checkout: {}",
            fs::canonicalize(&p).unwrap_or(p).display()
        ));
    }
    fs::canonicalize(String::from_utf8_lossy(&o.stdout).trim()).map_err(|e| e.to_string())
}
fn id(r: &Path) -> String {
    sha256::digest(r.to_string_lossy().as_bytes())
}
fn ip(r: &Path) -> Result<PathBuf, String> {
    Ok(home()?.join(id(r)).join("index.sqlite"))
}
fn git(r: &Path, a: &[&str], input: Option<&[u8]>) -> Result<Vec<u8>, String> {
    let mut c = Command::new("git");
    c.current_dir(r).args(a).stdout(Stdio::piped());
    if input.is_some() {
        c.stdin(Stdio::piped());
    }
    let mut ch = c.spawn().map_err(|e| e.to_string())?;
    if let Some(i) = input {
        ch.stdin
            .take()
            .unwrap()
            .write_all(i)
            .map_err(|e| e.to_string())?
    }
    let o = ch.wait_with_output().map_err(|e| e.to_string())?;
    if !o.status.success() {
        return Err(String::from_utf8_lossy(&o.stderr).trim().into());
    }
    Ok(o.stdout)
}
fn walk(p: &Path, v: &mut Vec<PathBuf>) -> std::io::Result<()> {
    let Ok(root_meta) = fs::symlink_metadata(p) else {
        return Ok(());
    };
    if root_meta.file_type().is_symlink() || !root_meta.file_type().is_dir() {
        return Ok(());
    }
    for e in fs::read_dir(p)? {
        let e = e?;
        let q = e.path();
        let f = e.file_type()?;
        if f.is_symlink() {
            continue;
        }
        if f.is_dir() {
            walk(&q, v)?
        } else if f.is_file() {
            v.push(q)
        }
    }
    Ok(())
}
fn listed(r: &Path) -> Vec<(String, String)> {
    let mut v = Vec::new();
    if let Ok(b) = git(
        r,
        &[
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        None,
    ) {
        for x in b
            .split(|c| *c == 0)
            .filter_map(|x| std::str::from_utf8(x).ok())
        {
            if x.ends_with(".ex") || x.ends_with(".exs") {
                v.push((x.into(), "code".into()))
            }
        }
    }
    for (base, k, exts) in [
        (".kogen/intents", "intent", ["md", "yaml", "yml"]),
        (".kogen/memory", "memory", ["md", "yaml", "yml"]),
    ] {
        let mut xs = Vec::new();
        let _ = walk(&r.join(base), &mut xs);
        for p in xs {
            if exts
                .iter()
                .any(|e| p.extension().and_then(|x| x.to_str()) == Some(*e))
            {
                let s = p
                    .strip_prefix(r)
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/");
                if !s.split('/').any(|x| x.ends_with("-raw")) {
                    v.push((s, k.into()))
                }
            }
        }
    }
    v.sort();
    v
}
fn hash_many(r: &Path, p: &[String]) -> Result<Vec<String>, String> {
    let inp = if p.is_empty() {
        String::new()
    } else {
        p.join("\n") + "\n"
    };
    let b = git(
        r,
        &["hash-object", "--no-filters", "--stdin-paths"],
        Some(inp.as_bytes()),
    )?;
    let out: Vec<String> = String::from_utf8_lossy(&b)
        .lines()
        .map(str::to_string)
        .collect();
    if out.len() != p.len() {
        return Err(format!(
            "git hash-object returned {} hashes for {} paths",
            out.len(),
            p.len()
        ));
    }
    Ok(out)
}
fn init(c: &Connection) -> rusqlite::Result<()> {
    c.busy_timeout(Duration::from_secs(10))?;
    c.execute_batch("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,kind TEXT NOT NULL,blob TEXT NOT NULL);CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(path UNINDEXED,kind UNINDEXED,start_line UNINDEXED,end_line UNINDEXED,body);")
}
fn not_a_database(e: &SqlError) -> bool {
    matches!(e, SqlError::SqliteFailure(err, _) if err.code == ErrorCode::NotADatabase)
}
fn we(p: &Path, e: impl std::fmt::Display) -> String {
    format!(
        "cannot write index at {}: {}; set KOGEN_CTX_HOME to a writable directory",
        p.display(),
        e
    )
}
fn refresh(r: &Path) -> Result<(Connection, bool, Vec<String>, Vec<String>, usize), String> {
    let p = ip(r)?;
    fs::create_dir_all(p.parent().unwrap()).map_err(|e| we(&p, e))?;
    let mut c = Connection::open(&p).map_err(|e| we(&p, e))?;
    let mut reb = match init(&c) {
        Ok(()) => false,
        Err(e) if not_a_database(&e) => true,
        Err(e) => return Err(we(&p, e)),
    };
    if !reb {
        let a: Result<Option<String>, _> = c
            .query_row("select value from meta where key='root'", [], |x| x.get(0))
            .optional();
        let b: Result<Option<String>, _> = c
            .query_row(
                "select value from meta where key='schema_version'",
                [],
                |x| x.get(0),
            )
            .optional();
        // An existing SQLite file with a different table layout is derived
        // data too, so rebuild it just like a schema-version mismatch.
        match (a, b) {
            (Ok(a), Ok(b)) => {
                reb =
                    a.as_deref() != Some(r.to_string_lossy().as_ref()) || b.as_deref() != Some("1");
            }
            _ => reb = true,
        }
    }
    if reb {
        drop(c);
        fs::remove_file(&p).map_err(|e| we(&p, e))?;
        c = Connection::open(&p).map_err(|e| we(&p, e))?;
        init(&c).map_err(|e| we(&p, e))?
    }
    c.execute_batch("BEGIN IMMEDIATE").map_err(|e| we(&p, e))?;
    if reb {
        c.execute_batch("delete from meta;delete from files;delete from chunks;")
            .map_err(|e| we(&p, e))?;
        c.execute("insert into meta values('schema_version','1')", [])
            .map_err(|e| we(&p, e))?;
        c.execute(
            "insert into meta values('root',?)",
            params![r.to_string_lossy()],
        )
        .map_err(|e| we(&p, e))?;
    }
    let mut paths = Vec::new();
    let mut kinds = Vec::new();
    for (a, k) in listed(r) {
        let f = r.join(&a);
        let Ok(m) = fs::symlink_metadata(&f) else {
            continue;
        };
        if !m.file_type().is_file() {
            continue;
        }
        let Ok(b) = fs::read(&f) else { continue };
        let lim = if k == "code" { 1 << 20 } else { 512 << 10 };
        if b.len() > lim || std::str::from_utf8(&b).is_err() {
            continue;
        }
        paths.push(a);
        kinds.push((k, b))
    }
    let blobs = hash_many(r, &paths)?;
    let mut seen = std::collections::HashSet::new();
    let mut re = Vec::new();
    for (i, a) in paths.iter().enumerate() {
        seen.insert(a.clone());
        let old: Option<String> = c
            .query_row("select blob from files where path=?", params![a], |x| {
                x.get(0)
            })
            .optional()
            .unwrap_or(None);
        if old.as_deref() == Some(&blobs[i]) {
            continue;
        }
        c.execute("delete from chunks where path=?", params![a])
            .map_err(|e| we(&p, e))?;
        c.execute("delete from files where path=?", params![a])
            .map_err(|e| we(&p, e))?;
        if kinds[i].0 != "code" {
            let txt = String::from_utf8_lossy(&kinds[i].1).into_owned();
            let ls: Vec<&str> = txt.lines().collect();
            let mut s = 0;
            while s < ls.len() {
                while s < ls.len() && ls[s].trim().is_empty() {
                    s += 1
                }
                if s >= ls.len() {
                    break;
                }
                let st = s;
                while s < ls.len() && !ls[s].trim().is_empty() {
                    s += 1
                }
                for ch in (st..s).step_by(60) {
                    let en = (ch + 60).min(s);
                    c.execute(
                        "insert into chunks values(?,?,?,?,?)",
                        params![
                            a,
                            &kinds[i].0,
                            (ch + 1) as i64,
                            en as i64,
                            ls[ch..en].join("\n")
                        ],
                    )
                    .map_err(|e| we(&p, e))?;
                }
            }
        }
        c.execute(
            "insert into files values(?,?,?)",
            params![a, &kinds[i].0, &blobs[i]],
        )
        .map_err(|e| we(&p, e))?;
        re.push(a.clone())
    }
    let old: Vec<String> = {
        let mut st = c.prepare("select path from files").map_err(|e| we(&p, e))?;
        st.query_map([], |x| x.get(0))
            .map_err(|e| we(&p, e))?
            .filter_map(Result::ok)
            .collect()
    };
    let mut rm = Vec::new();
    for a in old {
        if !seen.contains(&a) {
            c.execute("delete from files where path=?", params![a])
                .map_err(|e| we(&p, e))?;
            c.execute("delete from chunks where path=?", params![a])
                .map_err(|e| we(&p, e))?;
            rm.push(a)
        }
    }
    c.execute_batch("COMMIT").map_err(|e| we(&p, e))?;
    re.sort();
    rm.sort();
    let n: i64 = c
        .query_row("select count(*) from files", [], |x| x.get(0))
        .unwrap_or(0);
    Ok((c, reb, re, rm, n as usize))
}
fn parse(a: &[String]) -> Result<(String, Vec<String>, Option<String>, i64), ()> {
    if a.is_empty() {
        return Err(());
    }
    let cmd = a[0].clone();
    if cmd != "index" && cmd != "search" {
        return Err(());
    }
    let (mut q, mut rv, mut l) = (Vec::new(), None, 20);
    let mut limit_seen = false;
    let mut i = 1;
    while i < a.len() {
        match a[i].as_str() {
            "--root" => {
                if rv.is_some() || i + 1 >= a.len() {
                    return Err(());
                }
                rv = Some(a[i + 1].clone());
                i += 2
            }
            "--limit" => {
                if cmd == "index"
                    || limit_seen
                    || i + 1 >= a.len()
                    || a[i + 1].is_empty()
                    || !a[i + 1].chars().all(|c| c.is_ascii_digit())
                    || a[i + 1] == "0"
                {
                    return Err(());
                }
                limit_seen = true;
                l = a[i + 1].parse().map_err(|_| ())?;
                i += 2
            }
            x if x.starts_with("--") => return Err(()),
            x => {
                if cmd == "index" {
                    return Err(());
                }
                q.push(x.into());
                i += 1
            }
        }
    }
    if cmd == "search" && q.is_empty() {
        return Err(());
    }
    Ok((cmd, q, rv, l))
}
fn main() {
    let a: Vec<String> = env::args().skip(1).collect();
    let Ok((cmd, q, rv, l)) = parse(&a) else {
        std::process::exit(usage())
    };
    let _h = match home() {
        Ok(x) => x,
        Err(e) => std::process::exit(runtime(e)),
    };
    let r = match root(rv.as_deref()) {
        Ok(x) => x,
        Err(e) => std::process::exit(runtime(e)),
    };
    let (c, b, re, rm, n) = match refresh(&r) {
        Ok(x) => x,
        Err(e) => std::process::exit(runtime(e)),
    };
    if cmd == "index" {
        let p = match ip(&r) {
            Ok(p) => p,
            Err(e) => std::process::exit(runtime(e)),
        };
        println!(
            "index {}\nproject {}\nrebuilt {}",
            p.display(),
            id(&r),
            if b { "yes" } else { "no" }
        );
        for x in &re {
            println!("reindexed {x}")
        }
        for x in &rm {
            println!("removed {x}")
        }
        println!("files {n} reindexed {} removed {}", re.len(), rm.len());
        return;
    }
    let ts: Vec<String> = q
        .join(" ")
        .split_whitespace()
        .filter(|x| x.chars().any(char::is_alphanumeric))
        .map(|x| format!("\"{}\"", x.replace('"', "\"\"")))
        .collect();
    if ts.is_empty() {
        return;
    }
    let mut st = match c.prepare(
        "select path,start_line,end_line,kind,body from chunks where chunks match ? order by bm25(chunks),path,start_line",
    ) {
        Ok(st) => st,
        Err(e) => std::process::exit(runtime(e)),
    };
    let rows: Vec<(String, i64, i64, String, String)> = match st
        .query_map(params![ts.join(" ")], |x| {
            Ok((x.get(0)?, x.get(1)?, x.get(2)?, x.get(3)?, x.get(4)?))
        }) {
        Ok(mapped) => {
            let mut rows = Vec::new();
            for row in mapped {
                match row {
                    Ok(row) => rows.push(row),
                    Err(e) => std::process::exit(runtime(e)),
                }
            }
            rows
        }
        Err(e) => std::process::exit(runtime(e)),
    };
    let take = rows.len().min(l as usize);
    for (p, s, e, k, b) in rows.iter().take(take) {
        println!(
            "{p}:{s}-{e} [{k}] {}",
            b.split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .chars()
                .take(160)
                .collect::<String>()
        )
    }
    if rows.len() > take {
        println!("... {} more", rows.len() - take)
    }
}
