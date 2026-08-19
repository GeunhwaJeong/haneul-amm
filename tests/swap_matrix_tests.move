// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Swap matrix suite: 16 pools (4 liquidity topologies x 4 fee
/// configurations), each running 12 chained swaps (3 amounts x 2
/// directions x exact-in/exact-out) whose full post-state is pinned
/// against the independent big-integer reference. Later cases run on
/// state evolved by earlier ones, so tick crossings, fee accumulation
/// and price drift compound across the chain.
///
/// On top of the pinned values, every case checks direction-agnostic
/// properties: budget bounds, protocol fee bounds, and exact reserve
/// conservation through the repay path.
///
/// Assertion codes are `case * 16 + field` so a failure names its case
/// and field: 0 in, 1 out, 2 protocol fee, 3 sqrt price, 4 tick,
/// 5 liquidity, 6/7 fee growth a/b, 8/9 reserves a/b, 10 budget bound,
/// 11 protocol fee bound.
#[test_only]
module haneul_amm::swap_matrix_tests {
    use haneul::balance;
    use haneul::test_scenario as ts;
    use haneul_amm::i32;
    use haneul_amm::pool::{Self, Pool};
    use haneul_amm::swap_matrix_vectors as vectors;
    use haneul_amm::test_coins::{COIN_A, COIN_B};
    use haneul_amm::tick_math;

    const ADMIN: address = @0xAD;
    const PRICE_1: u128 = 1 << 64;

    /// Fee configuration c of the matrix: (lp_fee_pips, protocol_pips).
    fun fee_config(c: u8): (u64, u64) {
        if (c == 0) (500, 0)
        else if (c == 1) (3000, 0)
        else if (c == 2) (10000, 0)
        else (3000, 1000)
    }

    fun fund(
        p: &mut Pool<COIN_A, COIN_B>,
        lower_bits: u32,
        upper_bits: u32,
        liquidity: u128,
        ctx: &mut TxContext,
    ) {
        let mut pos = p.open_position(lower_bits, upper_bits, ctx);
        let receipt = p.add_liquidity(&mut pos, liquidity);
        let (need_a, need_b) = pool::add_liquidity_receipt_amounts(&receipt);
        p.repay_add_liquidity(
            receipt,
            balance::create_for_testing<COIN_A>(need_a),
            balance::create_for_testing<COIN_B>(need_b),
        );
        transfer::public_transfer(pos, ADMIN);
    }

    /// Build pool `pool_idx` of the matrix; must mirror TOPOLOGIES and
    /// FEE_CONFIGS in tools/gen_swap_matrix.py exactly.
    fun build_pool(pool_idx: u8, ctx: &mut TxContext): Pool<COIN_A, COIN_B> {
        let topo = pool_idx / 4;
        let (lp_fee, protocol_fee) = fee_config(pool_idx % 4);
        let mut p = pool::new<COIN_A, COIN_B>(
            lp_fee,
            false,
            60,
            option::none(),
            0,
            PRICE_1,
            ctx,
        );
        if (protocol_fee > 0) {
            let cap = pool::new_protocol_cap(ctx);
            p.set_protocol_fee(&cap, protocol_fee, protocol_fee);
            transfer::public_transfer(cap, ADMIN);
        };

        let full_lower = i32::neg_from(443580).bits();
        let full_upper = i32::from(443580).bits();
        if (topo == 0) {
            fund(&mut p, full_lower, full_upper, 1000000000000, ctx);
        } else if (topo == 1) {
            fund(&mut p, full_lower, full_upper, 1000000000000, ctx);
            fund(
                &mut p,
                i32::neg_from(600).bits(),
                i32::from(600).bits(),
                5000000000000,
                ctx,
            );
        } else if (topo == 2) {
            fund(&mut p, full_lower, full_upper, 1000000000, ctx);
            fund(
                &mut p,
                i32::neg_from(1200).bits(),
                i32::neg_from(600).bits(),
                3000000000000,
                ctx,
            );
            fund(
                &mut p,
                i32::from(600).bits(),
                i32::from(1200).bits(),
                3000000000000,
                ctx,
            );
        } else {
            fund(
                &mut p,
                i32::neg_from(600).bits(),
                i32::zero().bits(),
                2000000000000,
                ctx,
            );
            fund(
                &mut p,
                i32::zero().bits(),
                i32::from(600).bits(),
                2000000000000,
                ctx,
            );
        };
        p
    }

    /// Run every matrix case belonging to `pool_idx` on one pool, in
    /// generation order.
    ///
    /// Takes the test's single scenario and advances it one transaction
    /// first: two `ts::begin` calls in one test would replay the same
    /// object-id sequence, and the second pool's tick table would alias
    /// the first pool's stored ticks.
    fun run_pool_cases(scenario: &mut ts::Scenario, pool_idx: u8) {
        scenario.next_tx(ADMIN);
        let mut p = build_pool(pool_idx, scenario.ctx());

        let v_pool = vectors::pool_index();
        let v_a2b = vectors::a_to_b();
        let v_exact_in = vectors::exact_in();
        let v_amount = vectors::amount();
        let v_in = vectors::expected_in();
        let v_out = vectors::expected_out();
        let v_pf = vectors::expected_protocol_fee();
        let v_price = vectors::expected_sqrt_price();
        let v_tick = vectors::expected_tick_bits();
        let v_liq = vectors::expected_liquidity();
        let v_fga = vectors::expected_fee_growth_a();
        let v_fgb = vectors::expected_fee_growth_b();

        let n = v_pool.length();
        let mut i = 0;
        while (i < n) {
            if (v_pool[i] != pool_idx) {
                i = i + 1;
                continue
            };
            let code = (i as u64) * 16;
            let a_to_b = v_a2b[i];
            let exact_in = v_exact_in[i];
            let amount = v_amount[i];
            let (ra0, rb0) = p.reserves();

            let (owed, got, protocol_fee) = if (a_to_b) {
                let (out, receipt) = p.swap_a_for_b(
                    amount,
                    exact_in,
                    tick_math::min_sqrt_price() + 1,
                );
                let (owed, pf) = pool::swap_receipt_amounts(&receipt);
                p.repay_swap_a(receipt, balance::create_for_testing<COIN_A>(owed));
                let got = out.value();
                balance::destroy_for_testing(out);
                // Conservation through the repay path: the input net of
                // the protocol's cut joins the reserves, the output
                // leaves them.
                let (ra1, rb1) = p.reserves();
                assert!(ra1 == ra0 + owed - pf, code + 8);
                assert!(rb1 == rb0 - got, code + 9);
                (owed, got, pf)
            } else {
                let (out, receipt) = p.swap_b_for_a(
                    amount,
                    exact_in,
                    tick_math::max_sqrt_price() - 1,
                );
                let (owed, pf) = pool::swap_receipt_amounts(&receipt);
                p.repay_swap_b(receipt, balance::create_for_testing<COIN_B>(owed));
                let got = out.value();
                balance::destroy_for_testing(out);
                let (ra1, rb1) = p.reserves();
                assert!(rb1 == rb0 + owed - pf, code + 9);
                assert!(ra1 == ra0 - got, code + 8);
                (owed, got, pf)
            };

            // Reference-pinned effects.
            assert!(owed == v_in[i], code);
            assert!(got == v_out[i], code + 1);
            assert!(protocol_fee == v_pf[i], code + 2);
            assert!(p.sqrt_price_x64() == v_price[i], code + 3);
            assert!(p.tick_current().bits() == v_tick[i], code + 4);
            assert!(p.liquidity() == v_liq[i], code + 5);
            let (fga, fgb) = p.fee_growth_globals();
            assert!(fga == v_fga[i], code + 6);
            assert!(fgb == v_fgb[i], code + 7);

            // Direction-agnostic properties.
            if (exact_in) {
                // The engine never takes more than the budget.
                assert!(owed <= amount, code + 10);
            } else {
                // The pool never pays out more than requested.
                assert!(got <= amount, code + 10);
            };
            assert!(protocol_fee <= owed, code + 11);

            i = i + 1;
        };

        pool::share(p);
    }

    #[test]
    fun matrix_full_range() {
        let mut scenario = ts::begin(ADMIN);
        run_pool_cases(&mut scenario, 0);
        run_pool_cases(&mut scenario, 1);
        run_pool_cases(&mut scenario, 2);
        run_pool_cases(&mut scenario, 3);
        scenario.end();
    }

    #[test]
    fun matrix_inner_band() {
        let mut scenario = ts::begin(ADMIN);
        run_pool_cases(&mut scenario, 4);
        run_pool_cases(&mut scenario, 5);
        run_pool_cases(&mut scenario, 6);
        run_pool_cases(&mut scenario, 7);
        scenario.end();
    }

    #[test]
    fun matrix_gap_with_side_bands() {
        let mut scenario = ts::begin(ADMIN);
        run_pool_cases(&mut scenario, 8);
        run_pool_cases(&mut scenario, 9);
        run_pool_cases(&mut scenario, 10);
        run_pool_cases(&mut scenario, 11);
        scenario.end();
    }

    #[test]
    fun matrix_bands_meeting_at_price() {
        let mut scenario = ts::begin(ADMIN);
        run_pool_cases(&mut scenario, 12);
        run_pool_cases(&mut scenario, 13);
        run_pool_cases(&mut scenario, 14);
        run_pool_cases(&mut scenario, 15);
        scenario.end();
    }
}
