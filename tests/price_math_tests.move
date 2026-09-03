// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// sqrt_price_math and swap_math unit tests. Exact-value vectors come
/// from the independent big-integer reference implementation.
module haneul_amm::price_math_tests {
    use haneul_amm::i32;
    use haneul_amm::sqrt_price_math as spm;
    use haneul_amm::swap_math;
    use haneul_amm::tick_math;

    const P0: u128 = 1 << 64; // price at tick 0
    const L: u128 = 1000000000000; // 1e12

    fun p(tick: u32, neg: bool): u128 {
        tick_math::get_sqrt_price_at_tick(
            if (neg) i32::neg_from(tick) else i32::from(tick),
        )
    }

    // === amount deltas ===

    #[test]
    fun amount_deltas_exact_and_rounded() {
        // Reference: 100 ticks around 1.0 with L = 1e12.
        assert!(spm::get_amount_a_delta(P0, p(100, false), L, true) == 4987272071);
        assert!(spm::get_amount_a_delta(P0, p(100, false), L, false) == 4987272070);
        assert!(spm::get_amount_b_delta(p(100, true), P0, L, true) == 4987272071);
        assert!(spm::get_amount_b_delta(p(100, true), P0, L, false) == 4987272070);
        // Argument order must not matter.
        assert!(
            spm::get_amount_a_delta(p(100, false), P0, L, true)
                == spm::get_amount_a_delta(P0, p(100, false), L, true),
        );
    }

    #[test]
    fun amount_deltas_degenerate_cases() {
        assert!(spm::get_amount_a_delta(P0, p(100, false), 0, true) == 0);
        assert!(spm::get_amount_b_delta(P0, p(100, false), 0, true) == 0);
        assert!(spm::get_amount_a_delta(P0, P0, L, true) == 0);
        assert!(spm::get_amount_b_delta(P0, P0, L, true) == 0);
    }

    #[test]
    fun rounding_never_exceeds_one() {
        // up and down may differ by at most 1.
        let up = spm::get_amount_a_delta(P0, p(1000, false), L, true);
        let down = spm::get_amount_a_delta(P0, p(1000, false), L, false);
        assert!(up == down || up == down + 1);
        let up = spm::get_amount_b_delta(p(1000, true), P0, L, true);
        let down = spm::get_amount_b_delta(p(1000, true), P0, L, false);
        assert!(up == down || up == down + 1);
    }

    // === next sqrt price ===

    #[test]
    fun next_price_from_amounts_exact() {
        assert!(spm::next_sqrt_price_from_input(P0, L, 1000000, true) == 18446725626983924633);
        assert!(spm::next_sqrt_price_from_input(P0, L, 1000000, false) == 18446762520453625325);
        assert!(spm::next_sqrt_price_from_output(P0, L, 1000000, true) == 18446725626965477906);
        assert!(spm::next_sqrt_price_from_output(P0, L, 1000000, false) == 18446762520472072089);
    }

    #[test]
    fun next_price_zero_amount_is_identity() {
        assert!(spm::next_sqrt_price_from_input(P0, L, 0, true) == P0);
        assert!(spm::next_sqrt_price_from_input(P0, L, 0, false) == P0);
    }

    #[test]
    fun next_price_directions() {
        // Input of A pushes price down; input of B pushes it up.
        assert!(spm::next_sqrt_price_from_input(P0, L, 1000000, true) < P0);
        assert!(spm::next_sqrt_price_from_input(P0, L, 1000000, false) > P0);
        // Output of B pushes price down; output of A pushes it up.
        assert!(spm::next_sqrt_price_from_output(P0, L, 1000000, true) < P0);
        assert!(spm::next_sqrt_price_from_output(P0, L, 1000000, false) > P0);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::sqrt_price_math::EInvalidInput)]
    fun next_price_zero_liquidity_aborts() {
        spm::next_sqrt_price_from_input(P0, 0, 1, true);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::sqrt_price_math::ENotEnoughLiquidity)]
    fun output_exceeding_reserves_aborts() {
        // Asking for more B out than the virtual reserve holds.
        spm::next_sqrt_price_from_output(P0, 1000, 18446744073709552, true);
    }

    // === swap steps ===

    #[test]
    fun step_exact_in_reaches_target() {
        // Huge budget: the step stops at the target price.
        let target = p(100, true);
        let (next, amount_in, amount_out, fee) =
            swap_math::compute_swap_step(P0, target, L, 0xFFFFFFFFFFFFFFFF, true, 3000);
        assert!(next == target);
        assert!(amount_in == 5012269624);
        assert!(amount_out == 4987272070);
        assert!(fee == 15082056);
    }

    #[test]
    fun step_exact_in_exhausts_budget() {
        let target = p(100, true);
        let (next, amount_in, amount_out, fee) =
            swap_math::compute_swap_step(P0, target, L, 1000000, true, 3000);
        assert!(next == 18446725682324046339);
        assert!(amount_in == 997000);
        assert!(amount_out == 996999);
        assert!(fee == 3000);
        // The exhaust branch consumes the budget exactly.
        assert!(amount_in + fee == 1000000);
    }

    #[test]
    fun step_exact_out() {
        let target = p(100, true);
        let (next, amount_in, amount_out, fee) =
            swap_math::compute_swap_step(P0, target, L, 1000000, false, 3000);
        assert!(next == 18446725626965477906);
        assert!(amount_in == 1000002);
        assert!(amount_out == 1000000);
        assert!(fee == 3010);
    }

    #[test]
    fun step_full_fee_consumes_everything() {
        // At a 100% fee the entire input is fee and the price is pinned.
        let target = p(100, true);
        let (next, amount_in, amount_out, fee) =
            swap_math::compute_swap_step(P0, target, L, 1000000, true, 1000000);
        assert!(next == P0);
        assert!(amount_in == 0);
        assert!(amount_out == 0);
        assert!(fee == 1000000);
    }

    #[test]
    fun step_zero_liquidity_jumps_to_target() {
        let target = p(100, true);
        let (next, amount_in, amount_out, fee) =
            swap_math::compute_swap_step(P0, target, 0, 1000000, true, 3000);
        assert!(next == target);
        assert!(amount_in == 0 && amount_out == 0 && fee == 0);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::swap_math::EFeeConsumesEverything)]
    fun step_exact_out_full_fee_aborts() {
        swap_math::compute_swap_step(P0, p(100, true), L, 1000000, false, 1000000);
    }

    #[test]
    fun target_price_selection() {
        // Falling price: the higher of boundary and limit binds.
        assert!(swap_math::get_target_sqrt_price(true, 100, 200) == 200);
        assert!(swap_math::get_target_sqrt_price(true, 300, 200) == 300);
        // Rising price: the lower binds.
        assert!(swap_math::get_target_sqrt_price(false, 300, 200) == 200);
        assert!(swap_math::get_target_sqrt_price(false, 100, 200) == 100);
    }
}
