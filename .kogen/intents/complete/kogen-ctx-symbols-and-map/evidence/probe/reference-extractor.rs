// Reference extractor for the kogen-ctx split (probe only): implements INTENT.md's symbol/ref rules.
use std::collections::HashMap;
use tree_sitter::{Node, Parser};
const DEFS: [&str; 7] = ["def", "defp", "defmacro", "defmacrop", "defguard", "defguardp", "defdelegate"];
const DIRS: [&str; 4] = ["alias", "import", "use", "require"];
fn t<'a>(n: Node, s: &'a str) -> &'a str { n.utf8_text(s.as_bytes()).unwrap() }
fn kids(n: Node) -> Vec<Node> { let mut c = n.walk(); n.named_children(&mut c).collect() }
fn target_ident<'a>(n: Node, s: &'a str) -> Option<&'a str> {
    let tg = n.child_by_field_name("target")?; if tg.kind() == "identifier" { Some(t(tg, s)) } else { None } }
fn args(n: Node) -> Vec<Node> { kids(n).into_iter().filter(|k| k.kind() == "arguments").flat_map(kids).collect() }
fn do_block(n: Node) -> Option<Node> { kids(n).into_iter().find(|k| k.kind() == "do_block") }
struct Scope { module: String, aliases: HashMap<String, String> }
fn resolve(name: &str, scopes: &[Scope]) -> String {
    let first = name.split('.').next().unwrap();
    for sc in scopes.iter().rev() { if let Some(full) = sc.aliases.get(first) { return format!("{}{}", full, &name[first.len()..]); } }
    name.to_string()
}
// collect aliases declared directly in a module body (not inside nested modules' bodies, but including nested defmodule names)
fn collect_aliases(body: Node, s: &str, module: &str, out: &mut HashMap<String, String>) {
    for n in kids(body) {
        if n.kind() != "call" || !matches!(target_ident(n, s), Some("alias") | Some("defmodule")) { collect_aliases(n, s, module, out); continue; }
        match target_ident(n, s) {
            Some("alias") => { let a = args(n);
                if let Some(first) = a.first() {
                    let mut as_name = None;
                    for k in &a[1..] { if k.kind() == "keywords" { for p in kids(*k) { if t(p.child_by_field_name("key").unwrap(), s).trim() == "as:" { as_name = Some(t(p.child_by_field_name("value").unwrap(), s).to_string()); } } } }
                    for m in names(*first, s) { let last = m.rsplit('.').next().unwrap().to_string(); out.insert(as_name.clone().unwrap_or(last), m); }
                } }
            Some("defmodule") => { let a = args(n); let nm = t(a[0], s); let first = nm.split('.').next().unwrap(); out.insert(first.to_string(), format!("{module}.{first}")); }
            _ => {}
        }
    }
}
fn names(n: Node, s: &str) -> Vec<String> {
    if n.kind() == "dot" { if let Some(r) = n.child_by_field_name("right") { if r.kind() == "tuple" {
        let l = t(n.child_by_field_name("left").unwrap(), s); return kids(r).into_iter().map(|k| format!("{l}.{}", t(k, s))).collect(); } } }
    vec![t(n, s).to_string()]
}
fn line(n: Node) -> usize { n.start_position().row + 1 }
fn walk(n: Node, s: &str, scopes: &mut Vec<Scope>, path: &str, syms: &mut Vec<(String, usize, String, String)>, refs: &mut Vec<(String, usize, String, String, String)>) {
    if n.kind() == "call" {
        if let Some(id) = target_ident(n, s) {
            if id == "defmodule" {
                let a = args(n); let written = t(a[0], s);
                let full = match scopes.last() { Some(sc) => format!("{}.{}", sc.module, written), None => written.to_string() };
                syms.push((path.into(), line(n), "defmodule".into(), full.clone()));
                if let Some(b) = do_block(n) { let mut al = HashMap::new(); collect_aliases(b, s, &full, &mut al);
                    scopes.push(Scope { module: full, aliases: al }); for k in kids(b) { walk(k, s, scopes, path, syms, refs); } scopes.pop(); }
                return;
            }
            if DEFS.contains(&id) && !scopes.is_empty() {
                let a = args(n); let mut head = a[0];
                if head.kind() == "binary_operator" && t(head.child_by_field_name("operator").unwrap(), s) == "when" { head = head.child_by_field_name("left").unwrap(); }
                let (name, ar) = if head.kind() == "call" { (t(head.child_by_field_name("target").unwrap(), s).to_string(), args(head).len()) } else { (t(head, s).to_string(), 0) };
                let full = format!("{}.{}/{}", scopes.last().unwrap().module, name, ar);
                if !syms.iter().any(|x| x.2 == id && x.3 == full) { syms.push((path.into(), line(n), id.into(), full)); }
                for k in a.iter() { walk(*k, s, scopes, path, syms, refs); }
                if let Some(b) = do_block(n) { walk(b, s, scopes, path, syms, refs); }
                return;
            }
            if DIRS.contains(&id) && !scopes.is_empty() {
                let a = args(n); for m in names(a[0], s) { let r = resolve(&m, scopes); refs.push((path.into(), line(n), id.into(), r.clone(), r)); }
                return;
            }
        }
        if let Some(tg) = n.child_by_field_name("target") { if tg.kind() == "dot" && !scopes.is_empty() {
            let l = tg.child_by_field_name("left").unwrap(); let r = tg.child_by_field_name("right").unwrap();
            let module = if l.kind() == "alias" { Some(resolve(t(l, s), scopes)) } else if l.kind() == "identifier" && t(l, s) == "__MODULE__" { Some(scopes.last().unwrap().module.clone()) } else { None };
            if let (Some(m), "identifier") = (module, r.kind()) {
                let mut ar = args(n).len();
                if let Some(p) = n.parent() { if p.kind() == "binary_operator" && t(p.child_by_field_name("operator").unwrap(), s) == "|>" && p.child_by_field_name("right") == Some(n) { ar += 1; } }
                refs.push((path.into(), line(n), "call".into(), m.clone(), format!("{m}.{}/{ar}", t(r, s))));
            } } }
    }
    if n.kind() == "unary_operator" && t(n.child_by_field_name("operator").unwrap(), s) == "&" && !scopes.is_empty() {
        let op = n.child_by_field_name("operand").unwrap();
        if op.kind() == "binary_operator" && t(op.child_by_field_name("operator").unwrap(), s) == "/" {
            let c = op.child_by_field_name("left").unwrap(); let nn = op.child_by_field_name("right").unwrap();
            if c.kind() == "call" && nn.kind() == "integer" { if let Some(tg) = c.child_by_field_name("target") { if tg.kind() == "dot" {
                let l = tg.child_by_field_name("left").unwrap(); let r = tg.child_by_field_name("right").unwrap();
                let module = if l.kind() == "alias" { Some(resolve(t(l, s), scopes)) } else if t(l, s) == "__MODULE__" { Some(scopes.last().unwrap().module.clone()) } else { None };
                if let Some(m) = module { refs.push((path.into(), line(n), "capture".into(), m.clone(), format!("{m}.{}/{}", t(r, s), t(nn, s)))); return; } } } }
        }
    }
    for k in kids(n) { walk(k, s, scopes, path, syms, refs); }
}
fn main() {
    let mut syms = vec![]; let mut refs = vec![];
    let root = std::env::args().nth(1).unwrap();
    for f in std::env::args().skip(2) {
        let s = std::fs::read_to_string(format!("{root}/{f}")).unwrap();
        let mut p = Parser::new(); p.set_language(&tree_sitter_elixir::LANGUAGE.into()).unwrap();
        let tree = p.parse(&s, None).unwrap();
        walk(tree.root_node(), &s, &mut vec![], &f, &mut syms, &mut refs);
    }
    syms.sort_by(|a, b| (&a.0, a.1, &a.3).cmp(&(&b.0, b.1, &b.3)));
    refs.sort_by(|a, b| (&a.0, a.1, &a.2, &a.4).cmp(&(&b.0, b.1, &b.2, &b.4)));
    for x in &syms { println!("S\t{}:{} {} {}", x.0, x.1, x.2, x.3); }
    for x in &refs { println!("R\t{}\t{}:{} {} {}", x.3, x.0, x.1, x.2, x.4); }
}
