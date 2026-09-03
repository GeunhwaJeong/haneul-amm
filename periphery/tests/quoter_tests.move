// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// The quoter's contract is exactness: every quote must equal what the
/// pool then actually does. These tests quote first, execute second,
/// and require bit-for-bit agreement on the reference scenarios.
module haneul_amm_periphery::quoter_tests {
    use haneul::balance;
    use haneul::test_scenario as ts;
    use haneul_amm::i32;
    use haneul_amm::pool::{Self, ProtocolCap};
    use haneul_amm::test_coins::COIN_A;
    use haneul_amm::tick_math;
    use haneul_amm_periphery::quoter;
    use haneul_amm_periphery::test_setup as setup;

    const L_BIG: u128 = 1000000000000;

    #[test]
    fun exact_in_quote_matches_execution() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        let limit = tick_math::min_sqrt_price() + 1;

        let (quoted_out, quoted_in, quoted_price) =
            quoter::quote_exact_in(&p, true, 1000000000, limit);
        assert!(quoted_out == 996006981);
        assert!(quoted_in == 1000000000);
        assert!(quoted_price == 18428370987834680440);

        // Execute and compare.
        let (out, receipt) = p.swap_a_for_b(1000000000, true, limit);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        assert!(out.value() == quoted_out);
        assert!(owed == quoted_in);
        assert!(p.sqrt_price_x64() == quoted_price);
        p.repay_swap_a(receipt, balance::create_for_testing<COIN_A>(owed));

        balance::destroy_for_testing(out);
        transfer::public_transfer(pos, setup::admin());
        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    fun exact_out_quote_matches_execution() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        let limit = tick_math::min_sqrt_price() + 1;

        let (quoted_in, quoted_filled, quoted_price) =
            quoter::quote_exact_out(&p, true, 1000000000, limit);
        assert!(quoted_in == 1004013042);
        assert!(quoted_filled == 1000000000);
        assert!(quoted_price == 18428297329635842064);

        let (out, receipt) = p.swap_a_for_b(1000000000, false, limit);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        assert!(out.value() == quoted_filled);
        assert!(owed == quoted_in);
        assert!(p.sqrt_price_x64() == quoted_price);
        p.repay_swap_a(receipt, balance::create_for_testing<COIN_A>(owed));

        balance::destroy_for_testing(out);
        transfer::public_transfer(pos, setup::admin());
        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    fun cross_tick_partial_fill_quote_matches_execution() {
        let (mut scenario, mut p) = setup::setup(3000);
        // The core suite's crossing scenario: a narrow position inside
        // a wide one, swap limited at tick -540.
        let pos_narrow = setup::fund_range(
            &mut p,
            i32::neg_from(60).bits(),
            i32::from(60).bits(),
            2000000000,
            scenario.ctx(),
        );
        let pos_wide = setup::fund_range(
            &mut p,
            i32::neg_from(600).bits(),
            i32::from(600).bits(),
            1000000000,
            scenario.ctx(),
        );
        let limit = tick_math::get_sqrt_price_at_tick(i32::neg_from(540));

        let (quoted_out, quoted_in, quoted_price) =
            quoter::quote_exact_in(&p, true, 100000000, limit);
        // Partial fill: the limit binds before the budget runs out.
        assert!(quoted_in == 33475553);
        assert!(quoted_out == 32628153);
        assert!(quoted_price == limit);

        let (out, receipt) = p.swap_a_for_b(100000000, true, limit);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        assert!(out.value() == quoted_out);
        assert!(owed == quoted_in);
        p.repay_swap_a(receipt, balance::create_for_testing<COIN_A>(owed));

        balance::destroy_for_testing(out);
        transfer::public_transfer(pos_narrow, setup::admin());
        transfer::public_transfer(pos_wide, setup::admin());
        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    fun quote_includes_protocol_fee() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        scenario.next_tx(setup::admin());
        let cap = scenario.take_from_sender<ProtocolCap>();
        p.set_protocol_fee(&cap, 1000, 0);

        let (quoted_out, quoted_in, quoted_price) = quoter::quote_exact_in(
            &p,
            true,
            1000000000,
            tick_math::min_sqrt_price() + 1,
        );
        // Reference: protocol fee thins the output relative to the
        // fee-only scenario.
        assert!(quoted_out == 995011965);
        assert!(quoted_in == 1000000000);
        assert!(quoted_price == 18428389342639115030);

        scenario.return_to_sender(cap);
        transfer::public_transfer(pos, setup::admin());
        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    fun quote_is_read_only() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        let price_before = p.sqrt_price_x64();
        let (ra, rb) = p.reserves();

        quoter::quote_exact_in(&p, true, 1000000000, tick_math::min_sqrt_price() + 1);
        quoter::quote_exact_out(&p, false, 1000000000, tick_math::max_sqrt_price() - 1);

        assert!(p.sqrt_price_x64() == price_before);
        let (ra2, rb2) = p.reserves();
        assert!(ra == ra2 && rb == rb2);

        transfer::public_transfer(pos, setup::admin());
        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::ESwapAmountZero)]
    fun zero_amount_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        transfer::public_transfer(pos, setup::admin());
        quoter::quote_exact_in(&p, true, 0, tick_math::min_sqrt_price() + 1);
        abort 0
    }

    #[test]
    #[expected_failure(
        abort_code = haneul_amm::pool::EPriceLimitAlreadyExceeded,
    )]
    fun wrong_side_limit_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        transfer::public_transfer(pos, setup::admin());
        quoter::quote_exact_in(&p, true, 1000, (1 << 64) + 1);
        abort 0
    }
}
