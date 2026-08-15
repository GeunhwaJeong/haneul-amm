// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// User-facing swap entry points with the protections the core
/// deliberately leaves out: minimum-output / maximum-input bounds,
/// deadlines, and all-or-nothing fill semantics.
///
/// The core's receipts guarantee the pool cannot be underpaid; this
/// router guarantees the *user* cannot be underpaid. The two layers
/// are separable on purpose: the core is meant to be frozen, while
/// routers can be replaced as better ones are written.
///
/// # Fill semantics
///
/// Both directions are all-or-nothing. An exact-input swap must
/// consume the entire input and an exact-output swap must deliver the
/// full requested output; if the pool's liquidity runs out before the
/// price bound, the router aborts instead of silently trading less.
/// Failing loudly beats a partial trade the caller did not price.
///
/// # Multi-hop routes
///
/// There are no path parameters here. Chain single hops in one
/// programmable transaction: pass min_amount_out = 0 on intermediate
/// hops and enforce the real minimum on the final hop. Atomicity makes
/// the whole route revert together, which is exactly what a path
/// encoding would buy.
///
/// # Hooked pools
///
/// This router serves pools whose swaps are not hook-gated. A gated
/// pool's hook package is its router; it can offer the same guards by
/// wrapping the `*_with_hook` core entry points.
module haneul_amm_periphery::router {
    use haneul::clock::Clock;
    use haneul::coin::{Self, Coin};
    use haneul_amm::pool::{Self, Pool};
    use haneul_amm::tick_math;

    /// The transaction outlived its deadline.
    const EDeadlinePassed: u64 = 0;
    /// Output fell below the caller's minimum.
    const ETooLittleReceived: u64 = 1;
    /// Required input exceeds the coin the caller offered.
    const ETooMuchRequested: u64 = 2;
    /// Pool liquidity ran out before the full input was consumed.
    const EPartialFill: u64 = 3;
    /// Pool liquidity ran out before the requested output was filled.
    const EUnfilledExactOutput: u64 = 4;

    /// Swap the entire `coin_in` of A for B. Aborts unless at least
    /// `min_amount_out` of B comes back.
    public fun swap_exact_a_for_b<A, B>(
        pool: &mut Pool<A, B>,
        coin_in: Coin<A>,
        min_amount_out: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<B> {
        check_deadline(clock, deadline_ms);
        let amount_in = coin_in.value();
        let (out, receipt) =
            pool.swap_a_for_b(amount_in, true, tick_math::min_sqrt_price() + 1);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        assert!(owed == amount_in, EPartialFill);
        assert!(out.value() >= min_amount_out, ETooLittleReceived);
        pool.repay_swap_a(receipt, coin_in.into_balance());
        coin::from_balance(out, ctx)
    }

    /// Swap the entire `coin_in` of B for A.
    public fun swap_exact_b_for_a<A, B>(
        pool: &mut Pool<A, B>,
        coin_in: Coin<B>,
        min_amount_out: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<A> {
        check_deadline(clock, deadline_ms);
        let amount_in = coin_in.value();
        let (out, receipt) =
            pool.swap_b_for_a(amount_in, true, tick_math::max_sqrt_price() - 1);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        assert!(owed == amount_in, EPartialFill);
        assert!(out.value() >= min_amount_out, ETooLittleReceived);
        pool.repay_swap_b(receipt, coin_in.into_balance());
        coin::from_balance(out, ctx)
    }

    /// Receive exactly `amount_out` of B, paying from `coin_in`, whose
    /// value is the maximum the caller will spend. Returns the output
    /// and the unspent remainder of the input coin.
    public fun swap_a_for_exact_b<A, B>(
        pool: &mut Pool<A, B>,
        mut coin_in: Coin<A>,
        amount_out: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<B>, Coin<A>) {
        check_deadline(clock, deadline_ms);
        let (out, receipt) =
            pool.swap_a_for_b(amount_out, false, tick_math::min_sqrt_price() + 1);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        assert!(out.value() == amount_out, EUnfilledExactOutput);
        assert!(owed <= coin_in.value(), ETooMuchRequested);
        pool.repay_swap_a(receipt, coin_in.split(owed, ctx).into_balance());
        (coin::from_balance(out, ctx), coin_in)
    }

    /// Receive exactly `amount_out` of A, paying from `coin_in` of B.
    public fun swap_b_for_exact_a<A, B>(
        pool: &mut Pool<A, B>,
        mut coin_in: Coin<B>,
        amount_out: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        check_deadline(clock, deadline_ms);
        let (out, receipt) =
            pool.swap_b_for_a(amount_out, false, tick_math::max_sqrt_price() - 1);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        assert!(out.value() == amount_out, EUnfilledExactOutput);
        assert!(owed <= coin_in.value(), ETooMuchRequested);
        pool.repay_swap_b(receipt, coin_in.split(owed, ctx).into_balance());
        (coin::from_balance(out, ctx), coin_in)
    }

    /// Aborts once the clock passes the deadline. A deadline equal to
    /// the current timestamp is still valid.
    fun check_deadline(clock: &Clock, deadline_ms: u64) {
        assert!(clock.timestamp_ms() <= deadline_ms, EDeadlinePassed);
    }
}
