use tree_sitter::Parser;
fn main() {
    let root = std::env::args().nth(1).unwrap();
    for f in std::env::args().skip(2) {
        let src = std::fs::read_to_string(format!("{root}/{f}")).unwrap();
        let mut p = Parser::new();
        p.set_language(&tree_sitter_elixir::LANGUAGE.into()).unwrap();
        let t = p.parse(&src, None).unwrap();
        println!("== {f} (has_error={})\n{}", t.root_node().has_error(), t.root_node().to_sexp());
    }
}
