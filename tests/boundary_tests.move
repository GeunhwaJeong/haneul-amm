// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Edge-of-domain tests: positions and swaps at the tick ceiling, at
/// the per-tick liquidity cap, and at the coin-width limits.
///
/// The first group is a regression suite for a class of aborts that
/// slipped past the reference-pinned matrices: a token-A position
/// priced near the tick ceiling can be worth more token B than a u64
/// holds. Adding it is legitimate (only its A principal is checked),
/// but the swap step used to compute the full to-target amount in u64
/// before consulting the budget, so any swap that reached the range
/// aborted regardless of how little it asked for. The step now
/// compares at full width and stops inside the range.
#[test_only]
module haneul_amm::boundary_tests {
    use haneul::balance;
    use haneul::test_scenario as ts;
    use haneul_amm::haneul_amm as amm_init;
    use haneul_amm::i32;
    use haneul_amm::pool::{Self, Pool};
    use haneul_amm::registry::{Self, Registry};
    use haneul_amm::sqrt_price_math;
    use haneul_amm::test_coins::{COIN_A, COIN_B};
    use haneul_amm::tick;
    use haneul_amm::tick_math;

    const ADMIN: address = @0xAD;

    /// The deep position's range: one tick wide at a price of about
    /// 4.3e15 B per A. With DEEP_L, L * P is about twice the 2^192
    /// bound of the full-precision price formula, the A principal is
    /// about 7.7e18 (fits a coin), the B equivalent is about 1e34
    /// (does not), and one unit of A costs about 4.3e15 B (affordable).
    /// DEEP_L is far below the per-tick cap of about 2^108 at spacing 1.
    const DEEP_LOWER: u32 = 360000;
    const DEEP_UPPER: u32 = 360001;
    const DEEP_L: u128 = 1 << 103;

    /// A pool priced ten ticks below the deep range, tick spacing 1.
    fun setup_at_ceiling(): (ts::Scenario, Pool<COIN_A, COIN_B>) {
        let mut scenario = ts::begin(ADMIN);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);
        let mut reg = scenario.take_shared<Registry>();
        let price = tick_math::get_sqrt_price_at_tick(i32::from(DEEP_LOWER - 10));
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 1, price, scenario.ctx());
        ts::return_shared(reg);
        scenario.next_tx(ADMIN);
        let p = scenario.take_shared<Pool<COIN_A, COIN_B>>();
        (scenario, p)
    }

    /// Open the deep range with DEEP_L, entirely above the price, and
    /// return the A principal it cost.
    fun fund_deep_position(p: &mut Pool<COIN_A, COIN_B>, ctx: &mut TxContext): u64 {
        let mut pos = p.open_position(i32::from(DEEP_LOWER).bits(), i32::from(DEEP_UPPER).bits(), ctx);
        let receipt = p.add_liquidity(&mut pos, DEEP_L);
        let (need_a, need_b) = pool::add_liquidity_receipt_amounts(&receipt);
        assert!(need_b == 0);
        p.repay_add_liquidity(
            receipt,
            balance::create_for_testing<COIN_A>(need_a),
            balance::create_for_testing<COIN_B>(need_b),
        );
        transfer::public_transfer(pos, ADMIN);
        need_a
    }

    fun swap_b_in(p: &mut Pool<COIN_A, COIN_B>, amount: u64, exact_in: bool): (u64, u64) {
        let (out, receipt) = p.swap_b_for_a(amount, exact_in, tick_math::max_sqrt_price() - 1);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        p.repay_swap_b(receipt, balance::create_for_testing<COIN_B>(owed));
        let got = out.value();
        balance::destroy_for_testing(out);
        (owed, got)
    }

    fun swap_a_in(p: &mut Pool<COIN_A, COIN_B>, amount: u64, exact_in: bool): (u64, u64) {
        let (out, receipt) = p.swap_a_for_b(amount, exact_in, tick_math::min_sqrt_price() + 1);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        p.repay_swap_a(receipt, balance::create_for_testing<COIN_A>(owed));
        let got = out.value();
        balance::destroy_for_testing(out);
        (owed, got)
    }

    // === Deep position at the tick ceiling (regression) ===

    #[test]
    fun deep_position_is_worth_more_b_than_u64() {
        let lo = tick_math::get_sqrt_price_at_tick(i32::from(DEEP_LOWER));
        let hi = tick_math::get_sqrt_price_at_tick(i32::from(DEEP_UPPER));
        // Its A side fits a coin; its B side does not; the price
        // formula's exact form does not apply.
        let a = sqrt_price_math::get_amount_a_delta_wide(lo, hi, DEEP_L, true);
        let b = sqrt_price_math::get_amount_b_delta_wide(lo, hi, DEEP_L, true);
        assert!(a == (NEED_A_DEEP as u256));
        assert!(b > (0xFFFFFFFFFFFFFFFF as u256));
        assert!((DEEP_L as u256) * (lo as u256) >= (1 << 192));
        assert!(DEEP_L < tick::max_liquidity_per_tick(1));
    }

    #[test]
    fun exact_in_swap_stops_inside_deep_range() {
        let (mut scenario, mut p) = setup_at_ceiling();
        let need_a = fund_deep_position(&mut p, scenario.ctx());
        let (ra, _) = p.reserves();
        assert!(ra == need_a && need_a == NEED_A_DEEP);

        // The whole budget is consumed, the price ends inside the deep
        // range, and the pool pays out what that movement is worth.
        let budget = 1_000_000_000_000_000_000;
        let (owed, got_a) = swap_b_in(&mut p, budget, true);
        assert!(owed == budget);
        assert!(got_a == GOT_A_EXACT_IN);
        assert!(i32::eq(p.tick_current(), i32::from(DEEP_LOWER)));
        assert!(p.liquidity() == DEEP_L);

        // Coming back down: the range holds almost no A at this depth,
        // so a large A budget drains it in a couple of units, crosses
        // the lower tick, and then runs to the price limit through
        // empty tick space (a partial fill, which the core allows).
        let (owed_a, got_b) = swap_a_in(&mut p, 1_000_000, true);
        assert!(owed_a == OWED_A_BACK);
        assert!(got_b == GOT_B_BACK);
        assert!(i32::lt(p.tick_current(), i32::from(DEEP_LOWER)));
        assert!(p.liquidity() == 0);

        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    fun exact_out_swap_stops_inside_deep_range() {
        let (mut scenario, mut p) = setup_at_ceiling();
        fund_deep_position(&mut p, scenario.ctx());

        // Asking for one unit of A charges the price the range implies
        // (a lot of B) and lands inside the range, via the divide-first
        // price formula.
        let (owed_b, got_a) = swap_b_in(&mut p, 1, false);
        assert!(got_a == 1);
        assert!(owed_b == OWED_B_EXACT_OUT);
        assert!(i32::eq(p.tick_current(), i32::from(DEEP_LOWER)));

        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::sqrt_price_math::EAmountOverflow)]
    fun exact_out_beyond_coin_width_still_aborts() {
        let (mut scenario, mut p) = setup_at_ceiling();
        fund_deep_position(&mut p, scenario.ctx());
        // Buying a meaningful slice of the deep range costs more B than
        // exists; exact-output has no partial-fill semantics, so the
        // honest answer is an abort on the input amount, not a wrong
        // price.
        swap_b_in(&mut p, 10_000_000, false);
        abort 0
    }

    // === Price formula fallback agrees with the exact form ===

    #[test]
    fun price_fallback_matches_exact_form_at_boundary() {
        // Just below the 2^192 bound the exact formula runs; just above
        // it the divide-first form runs. The liquidity difference is
        // two parts in 2^96, so any gap between the results is the
        // fallback's own rounding: at most 2^-64 relative, and always
        // in the pool's favor (the price moves no further than exact).
        let price = tick_math::get_sqrt_price_at_tick(i32::from(DEEP_LOWER));
        let l_exact: u128 = ((1u256 << 192) / (price as u256) - 1) as u128;
        let l_fallback: u128 = l_exact + 2;
        let tolerance = price >> 63;
        let amount = 1_000_000_000;

        // Adding A: the price falls. Fallback must not fall further.
        let p_exact = sqrt_price_math::next_sqrt_price_from_amount_a_rounding_up(
            price, l_exact, amount, true,
        );
        let p_fallback = sqrt_price_math::next_sqrt_price_from_amount_a_rounding_up(
            price, l_fallback, amount, true,
        );
        assert!(p_fallback < price && p_exact < price);
        assert!(p_fallback >= p_exact);
        assert!(p_fallback - p_exact <= tolerance);

        // Removing A: the price rises. Fallback must not rise less
        // (the input then charged for the move rounds up on top).
        let p_exact_rm = sqrt_price_math::next_sqrt_price_from_amount_a_rounding_up(
            price, l_exact, amount, false,
        );
        let p_fallback_rm = sqrt_price_math::next_sqrt_price_from_amount_a_rounding_up(
            price, l_fallback, amount, false,
        );
        assert!(p_fallback_rm > price && p_exact_rm > price);
        assert!(p_fallback_rm >= p_exact_rm);
        assert!(p_fallback_rm - p_exact_rm <= tolerance);
    }

    // === Per-tick cap and the widest range ===

    #[test]
    #[expected_failure(abort_code = haneul_amm::tick::ETickLiquidityOverflow)]
    fun position_at_cap_plus_one_aborts() {
        let (mut scenario, mut p) = setup_at_ceiling();
        let cap = tick::max_liquidity_per_tick(1);
        let mut pos = p.open_position(
            i32::from(DEEP_LOWER).bits(),
            i32::from(DEEP_UPPER).bits(),
            scenario.ctx(),
        );
        // The cap itself is fine on the tick side; the A principal for
        // cap + 1 is what is asserted here, before any coin check.
        let receipt = p.add_liquidity(&mut pos, cap + 1);
        let (_, _) = pool::add_liquidity_receipt_amounts(&receipt);
        abort 0
    }

    #[test]
    fun widest_position_at_spacing_one() {
        let (mut scenario, mut p) = setup_at_ceiling();
        let lower = tick_math::min_usable_tick(1);
        let upper = tick_math::max_usable_tick(1);
        assert!(i32::eq(lower, tick_math::min_tick()));
        assert!(i32::eq(upper, tick_math::max_tick()));
        let mut pos = p.open_position(lower.bits(), upper.bits(), scenario.ctx());
        // The full range spans 2^96 in sqrt price, so the B side caps
        // liquidity at 2^32 per unit of B; 2^30 costs about 2^62 B and
        // a single rounded-up unit of A at this price.
        let receipt = p.add_liquidity(&mut pos, 1 << 30);
        let (need_a, need_b) = pool::add_liquidity_receipt_amounts(&receipt);
        assert!(need_a == NEED_A_WIDEST);
        assert!(need_b == NEED_B_WIDEST);
        p.repay_add_liquidity(
            receipt,
            balance::create_for_testing<COIN_A>(need_a),
            balance::create_for_testing<COIN_B>(need_b),
        );
        transfer::public_transfer(pos, ADMIN);
        ts::return_shared(p);
        scenario.end();
    }

    // Values pinned from the first run of each test; the amounts are
    // consequences of the Q32.64 math and the deliberately chosen L.
    const NEED_A_DEEP: u64 = 7728890454277601763;
    const GOT_A_EXACT_IN: u64 = 231;
    const OWED_A_BACK: u64 = 233;
    const GOT_B_BACK: u64 = 996999760671932416;
    const OWED_B_EXACT_OUT: u64 = 4316437824589032;
    const NEED_A_WIDEST: u64 = 17;
    const NEED_B_WIDEST: u64 = 70403227471691868;
}
