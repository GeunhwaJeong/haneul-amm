// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Exact vectors from the independent big-integer reference.
module haneul_amm_periphery::liquidity_amounts_tests {
    use haneul_amm::i32;
    use haneul_amm::tick_math;
    use haneul_amm_periphery::liquidity_amounts as la;

    const P0: u128 = 1 << 64;

    fun p(tick: u32, neg: bool): u128 {
        tick_math::get_sqrt_price_at_tick(
            if (neg) i32::neg_from(tick) else i32::from(tick),
        )
    }

    #[test]
    fun single_sided_vectors() {
        assert!(la::liquidity_for_amount_a(P0, p(60, false), 1000000000) == 333850249709);
        assert!(la::liquidity_for_amount_b(p(60, true), P0, 1000000000) == 333850249709);
        // Argument order must not matter.
        assert!(
            la::liquidity_for_amount_a(p(60, false), P0, 1000000000)
                == la::liquidity_for_amount_a(P0, p(60, false), 1000000000),
        );
    }

    #[test]
    fun full_range_amounts_recover_reference_liquidity() {
        // The principal charged for 1e12 liquidity across the full
        // range buys back exactly 1e12 liquidity.
        let l = la::liquidity_for_amounts(
            P0,
            p(443580, true),
            p(443580, false),
            999999999767,
            999999999767,
        );
        assert!(l == 1000000000000);
    }

    #[test]
    fun in_range_takes_the_scarcer_side() {
        // Extra B does not help once A binds.
        let balanced = la::liquidity_for_amounts(
            P0, p(60, true), p(60, false), 1000000000, 1000000000,
        );
        let extra_b = la::liquidity_for_amounts(
            P0, p(60, true), p(60, false), 1000000000, 3000000000,
        );
        assert!(balanced == 333850249709);
        assert!(extra_b == balanced);
    }

    #[test]
    fun out_of_range_uses_one_token_only() {
        // Price below the range: all A; B is irrelevant.
        let below = la::liquidity_for_amounts(
            p(120, true), p(60, true), p(60, false), 1000000000, 0,
        );
        assert!(below == la::liquidity_for_amount_a(p(60, true), p(60, false), 1000000000));
        // Price above the range: all B; A is irrelevant.
        let above = la::liquidity_for_amounts(
            p(120, false), p(60, true), p(60, false), 0, 1000000000,
        );
        assert!(above == la::liquidity_for_amount_b(p(60, true), p(60, false), 1000000000));
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::liquidity_amounts::EEmptyRange)]
    fun equal_prices_abort() {
        la::liquidity_for_amount_a(P0, P0, 1);
    }
}
