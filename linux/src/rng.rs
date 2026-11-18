//! A small random number generator (xorshift64*) for the animation. Not for anything security related.

pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        // xorshift must never hold 0
        let s = seed ^ 0x9E37_79B9_7F4A_7C15;
        Rng(if s == 0 { 1 } else { s })
    }

    /// Seeded from the clock and the process id, so every run differs.
    pub fn from_time() -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0);
        Rng::new(nanos ^ ((std::process::id() as u64) << 32))
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// 0 <= r < 1 (like `Random.NextDouble()` cast to float).
    pub fn f(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / 16_777_216.0
    }

    /// 0 <= r < 1 as f64.
    pub fn f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / 9_007_199_254_740_992.0
    }

    /// lo <= r < hi (like `Random.Next(lo, hi)`); returns lo when the range is empty.
    pub fn range(&mut self, lo: i32, hi: i32) -> i32 {
        if hi <= lo {
            return lo;
        }
        lo + (self.next_u64() % (hi - lo) as u64) as i32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_stay_inside() {
        let mut r = Rng::new(0);
        for _ in 0..10_000 {
            let a = r.f();
            assert!((0.0..1.0).contains(&a));
            let b = r.f64();
            assert!((0.0..1.0).contains(&b));
            let c = r.range(-50, 1970);
            assert!((-50..1970).contains(&c));
        }
        assert_eq!(r.range(5, 5), 5);
    }
}
