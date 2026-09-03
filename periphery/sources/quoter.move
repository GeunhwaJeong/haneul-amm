// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Read-only swap quotes.
///
/// A quote is the core's own swap walk replayed against `&Pool`, so it
/// is exact for the state it reads and cannot drift from execution:
/// there is one engine, and `pool::simulate_swap` exposes it. This
/// module only shapes the result for the two questions callers ask.
///
/// Caveats: quotes use the pool's stored LP fee, so a hook-gated pool
/// that overrides fees per swap can quote differently from how it
/// executes. Quote and execution also diverge if any transaction
/// changes the pool in between; on-chain, quote in the same
/// transaction or accept the race.
module haneul_amm_periphery::quoter {
    use haneul_amm::pool::Pool;

    /// Quote an exact-input swap up to `sqrt_price_limit`.
    /// Returns (amount_out, amount_in_consumed, sqrt_price_after).
    /// `amount_in_consumed` < `amount_in` means the pool would run out
    /// of liquidity or hit the limit first (a partial fill).
    public fun quote_exact_in<A, B>(
        pool: &Pool<A, B>,
        a_to_b: bool,
        amount_in: u64,
        sqrt_price_limit: u128,
    ): (u64, u64, u128) {
        let (consumed, out, _, price_after, _, _) =
            pool.simulate_swap(a_to_b, true, amount_in, sqrt_price_limit, option::none());
        (out, consumed, price_after)
    }

    /// Quote an exact-output swap up to `sqrt_price_limit`.
    /// Returns (amount_in_required, amount_out_filled, sqrt_price_after).
    /// `amount_out_filled` < `amount_out` means the request cannot be
    /// fully filled from current liquidity.
    public fun quote_exact_out<A, B>(
        pool: &Pool<A, B>,
        a_to_b: bool,
        amount_out: u64,
        sqrt_price_limit: u128,
    ): (u64, u64, u128) {
        let (required, filled, _, price_after, _, _) =
            pool.simulate_swap(a_to_b, false, amount_out, sqrt_price_limit, option::none());
        (required, filled, price_after)
    }
}
