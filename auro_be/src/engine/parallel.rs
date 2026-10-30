//! CPU work split over a few threads, never all of them: the live engine
//! runs in the same process, and its price stream and candle feed must keep
//! headroom on the 8-core machine it runs on.

/// `f` over `items` on at most `threads` scoped threads, results in the
/// items' order. A thread that panics loses its share: each of its items
/// comes back as `crashed(item)` instead, so nothing goes silently missing.
pub fn map<T, R>(
    items: &[T],
    threads: usize,
    f: impl Fn(&T) -> R + Sync,
    crashed: impl Fn(&T) -> R,
) -> Vec<R>
where
    T: Sync,
    R: Send,
{
    if items.is_empty() {
        return Vec::new();
    }
    let per_thread = items.len().div_ceil(threads.max(1));
    let f = &f;
    std::thread::scope(|scope| {
        items
            .chunks(per_thread)
            .map(|chunk| scope.spawn(move || chunk.iter().map(f).collect::<Vec<R>>()))
            .collect::<Vec<_>>()
            .into_iter()
            .zip(items.chunks(per_thread))
            .flat_map(|(handle, chunk)| {
                handle
                    .join()
                    .unwrap_or_else(|_| chunk.iter().map(&crashed).collect())
            })
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn results_keep_the_items_order() {
        let items: Vec<u32> = (0..10).collect();
        assert_eq!(
            map(&items, 3, |i| i * 2, |_| 0),
            (0..10).map(|i| i * 2).collect::<Vec<_>>()
        );
        assert!(map(&[] as &[u32], 3, |i| *i, |_| 0).is_empty());
    }

    #[test]
    fn a_crashed_thread_reports_each_of_its_items() {
        let items: Vec<u32> = (0..4).collect();
        let out = map(
            &items,
            2,
            |i| if *i == 3 { panic!("boom") } else { Ok(*i) },
            |i| Err(*i),
        );
        // Items 2 and 3 shared the thread that panicked.
        assert_eq!(out, vec![Ok(0), Ok(1), Err(2), Err(3)]);
    }
}
