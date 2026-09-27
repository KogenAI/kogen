use rusqlite::Connection;
use tree_sitter::StreamingIterator;

fn main() {
    let db = Connection::open_in_memory().unwrap();
    let v: String = db.query_row("select sqlite_version()", [], |r| r.get(0)).unwrap();
    println!("sqlite {v}");
    db.execute_batch(r#"create virtual table t using fts5(body, tokenize='trigram');
        insert into t values ('defmodule Kogen.Build do');
        create virtual table u using fts5(body);
        insert into u values ('guard violation rework');"#).unwrap();
    let n: i64 = db.query_row(r#"select count(*) from t where t match '"ogen.Bu"'"#, [], |r| r.get(0)).unwrap();
    let m: i64 = db.query_row("select count(*) from u where u match 'rework'", [], |r| r.get(0)).unwrap();
    println!("fts5 trigram hits {n}; unicode61 hits {m}");
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&tree_sitter_elixir::LANGUAGE.into()).unwrap();
    let src = "defmodule A.B do\n  alias C.D\n  def run(x), do: D.go(x)\n  defp hidden, do: :ok\n  def two(a, b) when a > b do\n    a\n  end\nend\n";
    let tree = parser.parse(src, None).unwrap();
    let root = tree.root_node();
    println!("root {} errors {}", root.kind(), root.has_error());
    let q = tree_sitter::Query::new(
        &tree_sitter_elixir::LANGUAGE.into(),
        r#"(call target: (identifier) @kw (arguments . [(alias) @name (identifier) @name (call target: (identifier) @name) (binary_operator left: (call target: (identifier) @name))]) (#match? @kw "^(defmodule|def|defp)$"))
           (call target: (dot left: (alias) @mod right: (identifier) @fun))"#,
    ).unwrap();
    let mut cur = tree_sitter::QueryCursor::new();
    let mut it = cur.matches(&q, root, src.as_bytes());
    while let Some(m) = it.next() {
        let caps: Vec<_> = m.captures().iter().map(|c| (q.capture_names()[c.index as usize], c.node.utf8_text(src.as_bytes()).unwrap().to_string(), c.node.start_position().row + 1)).collect();
        println!("{}", serde_json::to_string(&caps).unwrap());
    }
}
