use std::collections::HashMap;
use tree_sitter::{Node, Parser};

#[derive(Clone, Debug)]
pub struct Symbol {
    pub line: usize,
    pub kind: String,
    pub name: String,
}

#[derive(Clone, Debug)]
pub struct Ref {
    pub line: usize,
    pub kind: String,
    pub module: String,
    pub target: String,
}

const DEFS: [&str; 7] = [
    "def",
    "defp",
    "defmacro",
    "defmacrop",
    "defguard",
    "defguardp",
    "defdelegate",
];
const DIRS: [&str; 4] = ["alias", "import", "use", "require"];

fn text<'a>(n: Node<'a>, source: &'a str) -> &'a str {
    n.utf8_text(source.as_bytes()).unwrap_or("")
}
fn children(n: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = n.walk();
    n.named_children(&mut cursor).collect()
}
fn target_ident<'a>(n: Node<'a>, source: &'a str) -> Option<&'a str> {
    let target = n.child_by_field_name("target")?;
    (target.kind() == "identifier").then(|| text(target, source))
}
fn arguments(n: Node<'_>) -> Vec<Node<'_>> {
    children(n)
        .into_iter()
        .filter(|k| k.kind() == "arguments")
        .flat_map(children)
        .collect()
}
fn do_block(n: Node<'_>) -> Option<Node<'_>> {
    children(n).into_iter().find(|k| k.kind() == "do_block")
}
fn line(n: Node<'_>) -> usize {
    n.start_position().row + 1
}

struct Scope {
    module: String,
    aliases: HashMap<String, String>,
}

fn resolve(name: &str, scopes: &[Scope]) -> String {
    let first = name.split('.').next().unwrap_or(name);
    for scope in scopes.iter().rev() {
        if let Some(full) = scope.aliases.get(first) {
            return format!("{}{}", full, &name[first.len()..]);
        }
    }
    name.to_string()
}

fn names(n: Node<'_>, source: &str) -> Vec<String> {
    if n.kind() == "dot" {
        if let Some(right) = n.child_by_field_name("right") {
            if right.kind() == "tuple" {
                let left = text(n.child_by_field_name("left").unwrap(), source);
                return children(right)
                    .into_iter()
                    .map(|k| format!("{left}.{}", text(k, source)))
                    .collect();
            }
        }
    }
    vec![text(n, source).to_string()]
}

fn collect_aliases(body: Node<'_>, source: &str, module: &str, out: &mut HashMap<String, String>) {
    for node in children(body) {
        if node.kind() == "call" {
            match target_ident(node, source) {
                Some("alias") => {
                    let args = arguments(node);
                    if let Some(first) = args.first() {
                        let mut as_name = None;
                        for kw in &args[1..] {
                            if kw.kind() == "keywords" {
                                for pair in children(*kw) {
                                    let key = pair.child_by_field_name("key");
                                    if key.map(|k| text(k, source).trim()) == Some("as:") {
                                        as_name = pair
                                            .child_by_field_name("value")
                                            .map(|v| text(v, source).to_string());
                                    }
                                }
                            }
                        }
                        for name in names(*first, source) {
                            let last = name.rsplit('.').next().unwrap_or(&name).to_string();
                            out.insert(as_name.clone().unwrap_or(last), name);
                        }
                    }
                }
                Some("defmodule") => {
                    if let Some(first) = arguments(node).first() {
                        let written = text(*first, source);
                        let short = written.split('.').next().unwrap_or(written);
                        out.insert(short.to_string(), format!("{module}.{short}"));
                    }
                }
                _ => collect_aliases(node, source, module, out),
            }
        } else {
            collect_aliases(node, source, module, out);
        }
    }
}

fn walk(
    node: Node<'_>,
    source: &str,
    scopes: &mut Vec<Scope>,
    symbols: &mut Vec<Symbol>,
    refs: &mut Vec<Ref>,
) {
    if node.kind() == "call" {
        if let Some(id) = target_ident(node, source) {
            if id == "defmodule" {
                let args = arguments(node);
                if let Some(first) = args.first() {
                    let written = text(*first, source);
                    let full = match scopes.last() {
                        Some(scope) => format!("{}.{}", scope.module, written),
                        None => written.to_string(),
                    };
                    symbols.push(Symbol {
                        line: line(node),
                        kind: "defmodule".into(),
                        name: full.clone(),
                    });
                    if let Some(body) = do_block(node) {
                        let mut aliases = HashMap::new();
                        collect_aliases(body, source, &full, &mut aliases);
                        scopes.push(Scope {
                            module: full,
                            aliases,
                        });
                        for child in children(body) {
                            walk(child, source, scopes, symbols, refs);
                        }
                        scopes.pop();
                    }
                }
                return;
            }
            if DEFS.contains(&id) && !scopes.is_empty() {
                let args = arguments(node);
                if let Some(first) = args.first() {
                    let mut head = *first;
                    if head.kind() == "binary_operator"
                        && head
                            .child_by_field_name("operator")
                            .map(|x| text(x, source))
                            == Some("when")
                    {
                        head = head.child_by_field_name("left").unwrap();
                    }
                    let (name, arity) = if head.kind() == "call" {
                        (
                            text(head.child_by_field_name("target").unwrap(), source).to_string(),
                            arguments(head).len(),
                        )
                    } else {
                        (text(head, source).to_string(), 0)
                    };
                    let full = format!("{}.{name}/{arity}", scopes.last().unwrap().module);
                    if !symbols.iter().any(|s| s.kind == id && s.name == full) {
                        symbols.push(Symbol {
                            line: line(node),
                            kind: id.into(),
                            name: full,
                        });
                    }
                }
                for child in children(node) {
                    walk(child, source, scopes, symbols, refs);
                }
                return;
            }
            if DIRS.contains(&id) && !scopes.is_empty() {
                if let Some(first) = arguments(node).first() {
                    for name in names(*first, source) {
                        let resolved = resolve(&name, scopes);
                        refs.push(Ref {
                            line: line(node),
                            kind: id.into(),
                            module: resolved.clone(),
                            target: resolved,
                        });
                    }
                }
                return;
            }
        }
        if let Some(target) = node.child_by_field_name("target") {
            if target.kind() == "dot" && !scopes.is_empty() {
                let left = target.child_by_field_name("left").unwrap();
                let right = target.child_by_field_name("right").unwrap();
                let module = if left.kind() == "alias" {
                    Some(resolve(text(left, source), scopes))
                } else if left.kind() == "identifier" && text(left, source) == "__MODULE__" {
                    Some(scopes.last().unwrap().module.clone())
                } else {
                    None
                };
                if let (Some(module), "identifier") = (module, right.kind()) {
                    let mut arity = arguments(node).len();
                    if let Some(parent) = node.parent() {
                        if parent.kind() == "binary_operator"
                            && parent
                                .child_by_field_name("operator")
                                .map(|x| text(x, source))
                                == Some("|>")
                            && parent.child_by_field_name("right") == Some(node)
                        {
                            arity += 1;
                        }
                    }
                    refs.push(Ref {
                        line: line(node),
                        kind: "call".into(),
                        module: module.clone(),
                        target: format!("{module}.{}{}", text(right, source), format!("/{arity}")),
                    });
                }
            }
        }
    }
    if node.kind() == "unary_operator"
        && node
            .child_by_field_name("operator")
            .map(|x| text(x, source))
            == Some("&")
        && !scopes.is_empty()
    {
        let operand = node.child_by_field_name("operand").unwrap();
        if operand.kind() == "binary_operator"
            && operand
                .child_by_field_name("operator")
                .map(|x| text(x, source))
                == Some("/")
        {
            let call = operand.child_by_field_name("left").unwrap();
            let arity = operand.child_by_field_name("right").unwrap();
            if call.kind() == "call" && arity.kind() == "integer" {
                if let Some(target) = call.child_by_field_name("target") {
                    if target.kind() == "dot" {
                        let left = target.child_by_field_name("left").unwrap();
                        let right = target.child_by_field_name("right").unwrap();
                        let module = if left.kind() == "alias" {
                            Some(resolve(text(left, source), scopes))
                        } else if text(left, source) == "__MODULE__" {
                            Some(scopes.last().unwrap().module.clone())
                        } else {
                            None
                        };
                        if let Some(module) = module {
                            refs.push(Ref {
                                line: line(node),
                                kind: "capture".into(),
                                module: module.clone(),
                                target: format!(
                                    "{module}.{}{}",
                                    text(right, source),
                                    format!("/{}", text(arity, source))
                                ),
                            });
                            return;
                        }
                    }
                }
            }
        }
    }
    for child in children(node) {
        walk(child, source, scopes, symbols, refs);
    }
}

pub fn extract(source: &str) -> (Vec<Symbol>, Vec<Ref>) {
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_elixir::LANGUAGE.into())
        .unwrap();
    let tree = parser.parse(source, None).unwrap();
    let mut symbols = Vec::new();
    let mut refs = Vec::new();
    walk(
        tree.root_node(),
        source,
        &mut Vec::new(),
        &mut symbols,
        &mut refs,
    );
    symbols.sort_by(|a, b| (a.line, &a.name).cmp(&(b.line, &b.name)));
    refs.sort_by(|a, b| (a.line, &a.kind, &a.target).cmp(&(b.line, &b.kind, &b.target)));
    (symbols, refs)
}
