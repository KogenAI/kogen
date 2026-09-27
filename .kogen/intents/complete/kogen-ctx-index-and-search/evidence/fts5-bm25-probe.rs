use rusqlite::Connection;
fn main() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch("create virtual table docs using fts5(path unindexed, start unindexed, body);").unwrap();
    let rows = [
        ("i/INTENT.md", 1, "# Rework stray paths"),
        ("i/INTENT.md", 3, "## Why"),
        ("i/INTENT.md", 5, "A stray Mix lock directory stopped the Build."),
        ("i/INTENT.md", 7, "## Outcome"),
        ("i/INTENT.md", 9, "The Developer deletes each stray path and the guard passes."),
        ("i/scenarios.yaml", 1, "- id: stray-file-reworked\n  given: A fixture with a stray file.\n  then: The guard reworks the stray file."),
        ("d/INTENT.md", 1, "# Add cart discounts"),
        ("d/INTENT.md", 3, "Discounts apply before tax in Shop.Pricing."),
        ("m/lesson.md", 1, "---\nid: \"lesson-stray-rework\"\nkind: \"lesson\"\nclaim: \"stray-rework published after 2 stopped Builds: stray Mix lock directories\"\n---"),
    ];
    for (p, s, b) in rows { db.execute("insert into docs values (?1, ?2, ?3)", (p, s, b)).unwrap(); }
    for q in [r#""stray""#, r#""Mix" "lock""#, r#""rework""#, r#""stray" "rework""#, r#""guard""passes""#, r#""stopped""#, r#""the""#] {
        let mut st = db.prepare("select path, start, bm25(docs) from docs where docs match ?1 order by bm25(docs), path, start").unwrap();
        let hits: Vec<(String, i64, f64)> = st.query_map([q], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().map(|x| x.unwrap()).collect();
        println!("{q}: {hits:?}");
    }
}
