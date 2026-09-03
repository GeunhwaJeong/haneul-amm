// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Position management in token terms.
///
/// The core speaks liquidity units; users hold coins. This module
/// converts between the two and adds the guards the core omits:
///
///  - opening or increasing takes coin budgets, computes the maximum
///    liquidity they buy at the current price, and returns the change;
///    `min_liquidity` bounds how far the received liquidity may fall
///    if the price moves between signing and execution
///  - decreasing enforces minimum principal amounts (fees owed are
///    settled separately and are not part of the slippage bound)
///  - closing drains principal and fees in one call and deletes the
///    emptied position
///
/// These entry points use the plain core paths, so they serve pools
/// whose liquidity operations are not hook-gated; a gating hook's own
/// package plays this role for its pools.
module haneul_amm_periphery::liquidity {
    use haneul::balance;
    use haneul::clock::Clock;
    use haneul::coin::{Self, Coin};
    use haneul_amm::pool::{Self, Pool};
    use haneul_amm::position::Position;
    use haneul_amm::tick_math;
    use haneul_amm_periphery::liquidity_amounts;

    /// The transaction outlived its deadline.
    const EDeadlinePassed: u64 = 0;
    /// The budgets buy less liquidity than the caller's minimum.
    const EMinLiquidityNotMet: u64 = 1;
    /// Principal returned fell below the caller's minimum.
    const EMinAmountNotMet: u64 = 2;
    /// The budgets buy no liquidity at all.
    const EZeroLiquidity: u64 = 3;

    /// Open a position on `pool` and fund it with as much liquidity as
    /// the two coin budgets buy at the current price. Returns the
    /// position and the unspent remainders.
    public fun open_position_with_coins<A, B>(
        pool: &mut Pool<A, B>,
        tick_lower_bits: u32,
        tick_upper_bits: u32,
        mut coin_a: Coin<A>,
        mut coin_b: Coin<B>,
        min_liquidity: u128,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Position, Coin<A>, Coin<B>) {
        check_deadline(clock, deadline_ms);
        let mut pos = pool.open_position(tick_lower_bits, tick_upper_bits, ctx);
        add_max_liquidity(pool, &mut pos, &mut coin_a, &mut coin_b, min_liquidity, ctx);
        (pos, coin_a, coin_b)
    }

    /// Add to an existing position, spending at most the two budgets.
    /// Returns the unspent remainders.
    public fun increase_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
        mut coin_a: Coin<A>,
        mut coin_b: Coin<B>,
        min_liquidity: u128,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        check_deadline(clock, deadline_ms);
        add_max_liquidity(pool, pos, &mut coin_a, &mut coin_b, min_liquidity, ctx);
        (coin_a, coin_b)
    }

    /// Remove liquidity and receive the principal, enforcing minimum
    /// amounts per token. Fees accrued stay on the position for
    /// `collect_fees`; they are not part of this slippage bound.
    public fun decrease_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
        liquidity: u128,
        min_amount_a: u64,
        min_amount_b: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        check_deadline(clock, deadline_ms);
        let (out_a, out_b) = pool.remove_liquidity(pos, liquidity);
        assert!(out_a.value() >= min_amount_a, EMinAmountNotMet);
        assert!(out_b.value() >= min_amount_b, EMinAmountNotMet);
        (coin::from_balance(out_a, ctx), coin::from_balance(out_b, ctx))
    }

    /// Pay out all fees owed to a position, as coins.
    public fun collect_fees<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        let (fee_a, fee_b) = pool.collect_fees(pos);
        (coin::from_balance(fee_a, ctx), coin::from_balance(fee_b, ctx))
    }

    /// Drain a position completely: remove all liquidity (bounded by
    /// the minimums, principal only), collect all fees, delete the
    /// position, and return everything as two coins.
    public fun close_position<A, B>(
        pool: &mut Pool<A, B>,
        mut pos: Position,
        min_amount_a: u64,
        min_amount_b: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        check_deadline(clock, deadline_ms);
        let liquidity = pos.liquidity();
        let (mut out_a, mut out_b) = if (liquidity > 0) {
            pool.remove_liquidity(&mut pos, liquidity)
        } else {
            (balance::zero(), balance::zero())
        };
        assert!(out_a.value() >= min_amount_a, EMinAmountNotMet);
        assert!(out_b.value() >= min_amount_b, EMinAmountNotMet);
        let (fee_a, fee_b) = pool.collect_fees(&mut pos);
        out_a.join(fee_a);
        out_b.join(fee_b);
        pos.close();
        (coin::from_balance(out_a, ctx), coin::from_balance(out_b, ctx))
    }

    // === Internals ===

    /// Compute the largest liquidity the two budgets can fund, add it
    /// to the position, and pay the pool from the budgets in place.
    fun add_max_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        min_liquidity: u128,
        ctx: &mut TxContext,
    ) {
        let price_lower = tick_math::get_sqrt_price_at_tick(pos.tick_lower());
        let price_upper = tick_math::get_sqrt_price_at_tick(pos.tick_upper());
        let sqrt_price = pool.sqrt_price_x64();

        let mut liquidity = liquidity_amounts::liquidity_for_amounts(
            sqrt_price,
            price_lower,
            price_upper,
            coin_a.value(),
            coin_b.value(),
        );
        assert!(liquidity > 0, EZeroLiquidity);

        // liquidity_for_amounts rounds down while the pool charges
        // rounded up, so the required principal can overshoot the
        // budget by a unit of counter-rounding. Step down until it
        // fits; one step is enough in practice, two is a hard bound.
        let mut guard: u8 = 0;
        while (guard < 3) {
            let (need_a, need_b) = required_amounts(pool, pos, liquidity);
            if (need_a <= coin_a.value() && need_b <= coin_b.value()) break;
            liquidity = liquidity - 1;
            guard = guard + 1;
        };
        assert!(guard < 3 && liquidity > 0, EZeroLiquidity);
        assert!(liquidity >= min_liquidity, EMinLiquidityNotMet);

        let receipt = pool.add_liquidity(pos, liquidity);
        let (need_a, need_b) = pool::add_liquidity_receipt_amounts(&receipt);
        pool.repay_add_liquidity(
            receipt,
            coin_a.split(need_a, ctx).into_balance(),
            coin_b.split(need_b, ctx).into_balance(),
        );
    }

    /// Principal the pool will charge for adding `liquidity` to this
    /// position right now.
    fun required_amounts<A, B>(
        pool: &Pool<A, B>,
        pos: &Position,
        liquidity: u128,
    ): (u64, u64) {
        pool.amounts_for_liquidity(pos.tick_lower(), pos.tick_upper(), liquidity, true)
    }

    fun check_deadline(clock: &Clock, deadline_ms: u64) {
        assert!(clock.timestamp_ms() <= deadline_ms, EDeadlinePassed);
    }
}
