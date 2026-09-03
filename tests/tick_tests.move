// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

module haneul_amm::tick_tests {
    use haneul::tx_context;
    use haneul_amm::i128;
    use haneul_amm::i32::{Self, I32};
    use haneul_amm::tick;

    fun t(v: u32, neg: bool): I32 {
        if (neg) i32::neg_from(v) else i32::from(v)
    }

    #[test]
    fun max_liquidity_per_tick_bounds() {
        // spacing 1: 887273 usable ticks share u128 max.
        let per_tick = tick::max_liquidity_per_tick(1);
        assert!(per_tick == 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF / 887273);
        // Wider spacing concentrates more allowance per tick.
        assert!(tick::max_liquidity_per_tick(60) > per_tick);
        assert!(tick::max_liquidity_per_tick(32767) > tick::max_liquidity_per_tick(60));
    }

    #[test]
    fun bitmap_finds_ticks_in_both_directions() {
        let mut ctx = tx_context::dummy();
        let mut ticks = tick::new_for_testing(60, &mut ctx);
        let cur = i32::zero();

        // Initialize ticks -600, -60, 120, 300.
        ticks.update_for_testing(t(600, true), cur, i128::from(1000), 0, 0, false);
        ticks.update_for_testing(t(60, true), cur, i128::from(1000), 0, 0, false);
        ticks.update_for_testing(t(120, false), cur, i128::from(1000), 0, 0, true);
        ticks.update_for_testing(t(300, false), cur, i128::from(1000), 0, 0, true);

        // Downward (lte) from 0: tick -60 lives in the previous word,
        // so the search stops at this word's boundary (tick 0 itself),
        // uninitialized. The swap loop resumes from there.
        let (next, init) = ticks.next_initialized_tick_within_one_word(i32::zero(), true);
        assert!(!init && i32::eq(next, i32::zero()));
        // Downward from -1 (same word as -60): finds -60.
        let (next, init) = ticks.next_initialized_tick_within_one_word(t(1, true), true);
        assert!(init && i32::eq(next, t(60, true)));
        // Downward from -60 itself is inclusive.
        let (next, init) = ticks.next_initialized_tick_within_one_word(t(60, true), true);
        assert!(init && i32::eq(next, t(60, true)));
        // Downward from -61: skips to -600.
        let (next, init) = ticks.next_initialized_tick_within_one_word(t(61, true), true);
        assert!(init && i32::eq(next, t(600, true)));
        // Upward (gt) from 0: nearest strictly above is 120.
        let (next, init) = ticks.next_initialized_tick_within_one_word(i32::zero(), false);
        assert!(init && i32::eq(next, t(120, false)));
        // Upward from 120 is exclusive: finds 300.
        let (next, init) = ticks.next_initialized_tick_within_one_word(t(120, false), false);
        assert!(init && i32::eq(next, t(300, false)));
        // Upward from 300: nothing in this word; returns word boundary,
        // uninitialized.
        let (_, init) = ticks.next_initialized_tick_within_one_word(t(300, false), false);
        assert!(!init);

        ticks.destroy_for_testing();
    }

    #[test]
    fun update_flips_only_on_zero_transitions() {
        let mut ctx = tx_context::dummy();
        let mut ticks = tick::new_for_testing(60, &mut ctx);
        let cur = i32::zero();
        let tk = t(60, true);

        // 0 -> 1000 flips on.
        assert!(ticks.update_for_testing(tk, cur, i128::from(1000), 0, 0, false));
        // 1000 -> 1500 does not flip.
        assert!(!ticks.update_for_testing(tk, cur, i128::from(500), 0, 0, false));
        assert!(ticks.liquidity_gross(tk) == 1500);
        // 1500 -> 500 does not flip.
        assert!(!ticks.update_for_testing(tk, cur, i128::neg_from(1000), 0, 0, false));
        // 500 -> 0 flips off.
        assert!(ticks.update_for_testing(tk, cur, i128::neg_from(500), 0, 0, false));

        ticks.destroy_for_testing();
    }

    #[test]
    fun net_liquidity_signs_for_lower_and_upper() {
        let mut ctx = tx_context::dummy();
        let mut ticks = tick::new_for_testing(60, &mut ctx);
        let cur = i32::zero();

        // Same tick used as a lower boundary by one position (+L on
        // upward cross) and as an upper boundary by another (-L).
        ticks.update_for_testing(t(60, false), cur, i128::from(700), 0, 0, false);
        ticks.update_for_testing(t(60, false), cur, i128::from(300), 0, 0, true);
        assert!(ticks.liquidity_gross(t(60, false)) == 1000);
        assert!(i128::eq(ticks.liquidity_net(t(60, false)), i128::from(400)));

        ticks.destroy_for_testing();
    }

    #[test]
    fun crossing_flips_outside_growth() {
        let mut ctx = tx_context::dummy();
        let mut ticks = tick::new_for_testing(60, &mut ctx);
        // Initialize below the current tick: outside growth snapshots
        // the current globals (100, 200).
        ticks.update_for_testing(t(60, true), i32::zero(), i128::from(1000), 100, 200, false);

        // Cross when globals reached (150, 260): outside becomes the
        // complement (50, 60).
        let net = ticks.cross(t(60, true), 150, 260);
        assert!(i128::eq(net, i128::from(1000)));
        let (a, b) = ticks.get_fee_growth_inside(
            t(60, true),
            t(60, false),
            i32::zero(),
            150,
            260,
        );
        // Inside [-60, 60] with current tick 0: global - below - above
        // = 150 - 50 - 0 and 260 - 60 - 0.
        assert!(a == 100 && b == 200);

        ticks.destroy_for_testing();
    }

    #[test]
    fun fee_growth_inside_by_price_region() {
        let mut ctx = tx_context::dummy();
        let mut ticks = tick::new_for_testing(60, &mut ctx);
        // Ticks initialized while price is at 0; globals (1000, 2000).
        ticks.update_for_testing(t(120, true), i32::zero(), i128::from(1), 1000, 2000, false);
        ticks.update_for_testing(t(120, false), i32::zero(), i128::from(1), 1000, 2000, true);
        // Lower (-120 <= 0) snapshots (1000, 2000); upper (120 > 0)
        // snapshots nothing.

        // Price inside: inside = global - below - above.
        let (a, b) = ticks.get_fee_growth_inside(
            t(120, true), t(120, false), i32::zero(), 1500, 2600,
        );
        assert!(a == 500 && b == 600);

        // Price below the range: inside = lower.outside - upper.outside.
        let (a, b) = ticks.get_fee_growth_inside(
            t(120, true), t(120, false), t(180, true), 1500, 2600,
        );
        assert!(a == 1000 && b == 2000);

        // Price above the range.
        let (a, b) = ticks.get_fee_growth_inside(
            t(120, true), t(120, false), t(180, false), 1500, 2600,
        );
        // upper.outside - lower.outside = 0 - 1000 wraps.
        assert!(a == haneul_amm::math_u128::wrapping_sub(0, 1000));
        assert!(b == haneul_amm::math_u128::wrapping_sub(0, 2000));

        ticks.destroy_for_testing();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::tick::ETickLiquidityOverflow)]
    fun exceeding_max_liquidity_per_tick_aborts() {
        let mut ctx = tx_context::dummy();
        let mut ticks = tick::new_for_testing(60, &mut ctx);
        let cap = tick::max_liquidity_per_tick(60);
        ticks.update_for_testing(
            t(60, false),
            i32::zero(),
            i128::from(cap + 1),
            0,
            0,
            false,
        );
        ticks.destroy_for_testing();
    }

    #[test]
    fun check_tick_range_accepts_aligned_ranges() {
        let mut ctx = tx_context::dummy();
        let ticks = tick::new_for_testing(60, &mut ctx);
        ticks.check_tick_range(t(120, true), t(180, false));
        ticks.check_tick_range(t(443580, true), t(443580, false));
        ticks.destroy_for_testing();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::tick::ETicksMisordered)]
    fun reversed_range_aborts() {
        let mut ctx = tx_context::dummy();
        let ticks = tick::new_for_testing(60, &mut ctx);
        ticks.check_tick_range(t(60, false), t(60, true));
        ticks.destroy_for_testing();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::tick::ETickMisaligned)]
    fun misaligned_tick_aborts() {
        let mut ctx = tx_context::dummy();
        let ticks = tick::new_for_testing(60, &mut ctx);
        ticks.check_tick_range(t(61, true), t(120, false));
        ticks.destroy_for_testing();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::tick::ETickOutOfBounds)]
    fun out_of_bounds_tick_aborts() {
        let mut ctx = tx_context::dummy();
        let ticks = tick::new_for_testing(1, &mut ctx);
        ticks.check_tick_range(t(443637, true), t(60, false));
        ticks.destroy_for_testing();
    }
}
