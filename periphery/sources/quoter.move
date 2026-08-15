// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Read-only swap quotes.
///
/// Walks the same tick path with the same step math as the pool's
/// swap engine, but against an immutable reference, so a quote is
/// exact for the state it reads and touches nothing. The core's
/// public views (tick bitmap search, per-tick net liquidity, step
/// computation) are sufficient to reproduce the engine, which is
/// intentional: a quoter should not need privileged access.
///
/// Caveats: quotes use the pool's stored LP fee, so a hook-gated pool
/// that overrides fees per swap can quote differently from how it
/// executes. Quote and execution also diverge if any transaction
/// changes the pool in between; on-chain, quote in the same
/// transaction or accept the race.
module haneul_amm_periphery::quoter {
    use haneul_amm::i32;
    use haneul_amm::pool::Pool;
    use haneul_amm::swap_math;
    use haneul_amm::tick;
    use haneul_amm::tick_math;

    /// Quote amount must be nonzero.
    const EZeroAmount: u64 = 0;
    /// The price limit is on the wrong side of the current price.
    const EPriceLimitAlreadyExceeded: u64 = 1;
    /// The price limit is outside the representable price range.
    const EPriceLimitOutOfBounds: u64 = 2;
    /// A 100% fee makes exact-output swaps impossible.
    const EInvalidFeeForExactOut: u64 = 3;
    /// Accumulated amount exceeds a coin balance.
    const EAmountOverflow: u64 = 4;

    const MAX_U64: u128 = 0xFFFFFFFFFFFFFFFF;

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
        let (consumed, calculated, price_after) =
            walk(pool, a_to_b, true, amount_in, sqrt_price_limit);
        (calculated, consumed, price_after)
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
        let (filled, calculated, price_after) =
            walk(pool, a_to_b, false, amount_out, sqrt_price_limit);
        (calculated, filled, price_after)
    }

    /// The swap engine's loop, replayed against `&Pool`. Returns
    /// (specified amount consumed/filled, other-side amount, price).
    fun walk<A, B>(
        pool: &Pool<A, B>,
        a_to_b: bool,
        exact_in: bool,
        amount: u64,
        sqrt_price_limit: u128,
    ): (u64, u64, u128) {
        assert!(amount > 0, EZeroAmount);
        let mut sqrt_price = pool.sqrt_price_x64();
        if (a_to_b) {
            assert!(sqrt_price_limit < sqrt_price, EPriceLimitAlreadyExceeded);
            assert!(sqrt_price_limit > tick_math::min_sqrt_price(), EPriceLimitOutOfBounds);
        } else {
            assert!(sqrt_price_limit > sqrt_price, EPriceLimitAlreadyExceeded);
            assert!(sqrt_price_limit < tick_math::max_sqrt_price(), EPriceLimitOutOfBounds);
        };

        let (protocol_a_to_b, protocol_b_to_a) = pool.protocol_fees_pips();
        let protocol_fee_pips = if (a_to_b) protocol_a_to_b else protocol_b_to_a;
        let lp_fee = pool.lp_fee_pips();
        let swap_fee = if (protocol_fee_pips == 0) {
            lp_fee
        } else {
            protocol_fee_pips + lp_fee
                - protocol_fee_pips * lp_fee / swap_math::fee_scale()
        };
        if (swap_fee >= swap_math::fee_scale()) {
            assert!(exact_in, EInvalidFeeForExactOut);
        };

        let mut amount_remaining = amount;
        let mut amount_calculated: u128 = 0;
        let mut tick_cur = pool.tick_current();
        let mut liq = pool.liquidity();
        let ticks = pool.ticks();

        while (amount_remaining > 0 && sqrt_price != sqrt_price_limit) {
            let sqrt_price_start = sqrt_price;
            let (mut tick_next, initialized) =
                ticks.next_initialized_tick_within_one_word(tick_cur, a_to_b);
            if (i32::lt(tick_next, tick_math::min_tick())) {
                tick_next = tick_math::min_tick();
            };
            if (i32::gt(tick_next, tick_math::max_tick())) {
                tick_next = tick_math::max_tick();
            };
            let sqrt_price_next = tick_math::get_sqrt_price_at_tick(tick_next);
            let target =
                swap_math::get_target_sqrt_price(a_to_b, sqrt_price_next, sqrt_price_limit);

            let (new_sqrt_price, step_in, step_out, step_fee) = swap_math::compute_swap_step(
                sqrt_price,
                target,
                liq,
                amount_remaining,
                exact_in,
                swap_fee,
            );
            sqrt_price = new_sqrt_price;

            if (exact_in) {
                amount_remaining = amount_remaining - step_in - step_fee;
                amount_calculated = amount_calculated + (step_out as u128);
            } else {
                amount_remaining = amount_remaining - step_out;
                amount_calculated =
                    amount_calculated + (step_in as u128) + (step_fee as u128);
            };

            if (sqrt_price == sqrt_price_next) {
                if (initialized) {
                    let mut liquidity_net = ticks.liquidity_net(tick_next);
                    if (a_to_b) {
                        liquidity_net = liquidity_net.neg();
                    };
                    liq = tick::add_liquidity_delta(liq, liquidity_net);
                };
                tick_cur = if (a_to_b) {
                    i32::sub(tick_next, i32::from(1))
                } else {
                    tick_next
                };
            } else if (sqrt_price != sqrt_price_start) {
                tick_cur = tick_math::get_tick_at_sqrt_price(sqrt_price);
            };
        };

        assert!(amount_calculated <= (MAX_U64 as u128), EAmountOverflow);
        (amount - amount_remaining, (amount_calculated as u64), sqrt_price)
    }
}
