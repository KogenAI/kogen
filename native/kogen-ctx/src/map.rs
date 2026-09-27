use std::collections::HashMap;

pub fn rank(
    files: &[String],
    edges: &HashMap<(String, String), f64>,
    focus: &[String],
) -> HashMap<String, f64> {
    let mut p = HashMap::new();
    let denom = if focus.is_empty() {
        files.len()
    } else {
        focus.len()
    } as f64;
    for file in files {
        p.insert(
            file.clone(),
            if focus.is_empty() || focus.contains(file) {
                1.0 / denom
            } else {
                0.0
            },
        );
    }
    let mut out_weight = HashMap::new();
    for file in files {
        out_weight.insert(
            file.clone(),
            edges
                .iter()
                .filter(|((from, _), _)| from == file)
                .map(|(_, w)| *w)
                .sum::<f64>(),
        );
    }
    let mut r = p.clone();
    for _ in 0..100 {
        let dangling: f64 = files
            .iter()
            .filter(|f| out_weight[*f] == 0.0)
            .map(|f| r[f])
            .sum();
        let mut next = HashMap::new();
        for v in files {
            let incoming = files
                .iter()
                .filter(|u| out_weight[*u] > 0.0)
                .map(|u| {
                    r[u] * edges.get(&(u.clone(), v.clone())).copied().unwrap_or(0.0)
                        / out_weight[u]
                })
                .sum::<f64>();
            next.insert(v.clone(), 0.15 * p[v] + 0.85 * (incoming + p[v] * dangling));
        }
        r = next;
    }
    r
}

pub fn ordered(files: &[String], ranks: &HashMap<String, f64>) -> Vec<String> {
    let mut out = files.to_vec();
    out.sort_by(|a, b| {
        let da = ranks[a];
        let db = ranks[b];
        if (da - db).abs() < 1e-12 {
            a.cmp(b)
        } else {
            db.partial_cmp(&da).unwrap_or(std::cmp::Ordering::Equal)
        }
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn map_rank_values() {
        let files: Vec<String> = [
            "lib/shop.ex",
            "lib/shop/cart.ex",
            "lib/shop/format.ex",
            "lib/shop/inventory.ex",
            "lib/shop/pricing.ex",
            "lib/shop/tax.ex",
            "test/shop_test.exs",
        ]
        .into_iter()
        .map(str::to_string)
        .collect();
        let mut edges = HashMap::new();
        for (a, b, n) in [
            ("lib/shop.ex", "lib/shop/cart.ex", 2.0),
            ("lib/shop.ex", "lib/shop/pricing.ex", 2.0),
            ("lib/shop.ex", "lib/shop/tax.ex", 2.0),
            ("lib/shop.ex", "lib/shop/inventory.ex", 2.0),
            ("lib/shop.ex", "lib/shop/format.ex", 1.0),
            ("lib/shop/inventory.ex", "lib/shop/tax.ex", 1.0),
            ("test/shop_test.exs", "lib/shop/cart.ex", 2.0),
        ] {
            edges.insert((a.to_string(), b.to_string()), n);
        }
        let r = rank(&files, &edges, &files);
        let expected = [
            ("lib/shop.ex", 0.102980719720808),
            ("lib/shop/cart.ex", 0.209966245208536),
            ("lib/shop/format.ex", 0.112706676583328),
            ("lib/shop/inventory.ex", 0.122432633445849),
            ("lib/shop/pricing.ex", 0.122432633445849),
            ("lib/shop/tax.ex", 0.226500371874821),
            ("test/shop_test.exs", 0.102980719720808),
        ];
        for (name, value) in expected {
            assert!((r[name] - value).abs() < 1e-12, "{name}: {}", r[name]);
        }
        let focus = vec!["test/shop_test.exs".to_string()];
        let r = rank(&files, &edges, &focus);
        assert!((r["lib/shop/cart.ex"] - 0.459459419267445).abs() < 1e-12);
        assert!((r["test/shop_test.exs"] - 0.540540580732555).abs() < 1e-12);
    }
}
