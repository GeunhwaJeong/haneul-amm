// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Router guard tests over the reference-pinned pool scenarios: the
/// same market as the core suite, so expected amounts are exact.
module haneul_amm_periphery::router_tests {
    use haneul::clock::{Self, Clock};
    use haneul::coin;
    use haneul_amm::i32;
    use haneul_amm::test_coins::{COIN_A, COIN_B};
    use haneul_amm_periphery::router;
    use haneul_amm_periphery::test_setup as setup;

    const L_BIG: u128 = 1000000000000;
    const NOW_MS: u64 = 1000000;

    fun test_clock(ctx: &mut TxContext): Clock {
        let mut c = clock::create_for_testing(ctx);
        c.set_for_testing(NOW_MS);
        c
    }

    #[test]
    fun exact_in_both_directions() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        let c = test_clock(scenario.ctx());

        // The pool is symmetric at price 1.0, so both directions quote
        // the same reference number.
        let out_b = router::swap_exact_a_for_b(
            &mut p,
            coin::mint_for_testing<COIN_A>(1000000000, scenario.ctx()),
            996006981, // exact boundary: the reference output itself
            NOW_MS + 60000,
            &c,
            scenario.ctx(),
        );
        assert!(out_b.value() == 996006981);

        let out_a = router::swap_exact_b_for_a(
            &mut p,
            coin::mint_for_testing<COIN_B>(1000000000, scenario.ctx()),
            0,
            NOW_MS + 60000,
            &c,
            scenario.ctx(),
        );
        // Not the pristine-pool number: the first swap moved the price.
        assert!(out_a.value() > 996006981);

        coin::burn_for_testing(out_b);
        coin::burn_for_testing(out_a);
        c.destroy_for_testing();
        transfer::public_transfer(pos, setup::admin());
        haneul::test_scenario::return_shared(p);
        scenario.end();
    }

    #[test]
    fun exact_out_returns_change() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        let c = test_clock(scenario.ctx());

        let (out_b, change_a) = router::swap_a_for_exact_b(
            &mut p,
            coin::mint_for_testing<COIN_A>(1100000000, scenario.ctx()),
            1000000000,
            NOW_MS + 60000,
            &c,
            scenario.ctx(),
        );
        assert!(out_b.value() == 1000000000);
        // Reference input for 1e9 out is 1_004_013_042.
        assert!(change_a.value() == 1100000000 - 1004013042);

        coin::burn_for_testing(out_b);
        coin::burn_for_testing(change_a);
        c.destroy_for_testing();
        transfer::public_transfer(pos, setup::admin());
        haneul::test_scenario::return_shared(p);
        scenario.end();
    }

    #[test]
    fun exact_out_b_for_a_symmetric() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        let c = test_clock(scenario.ctx());

        let (out_a, change_b) = router::swap_b_for_exact_a(
            &mut p,
            coin::mint_for_testing<COIN_B>(1100000000, scenario.ctx()),
            1000000000,
            NOW_MS + 60000,
            &c,
            scenario.ctx(),
        );
        assert!(out_a.value() == 1000000000);
        assert!(change_b.value() == 1100000000 - 1004013042);

        coin::burn_for_testing(out_a);
        coin::burn_for_testing(change_b);
        c.destroy_for_testing();
        transfer::public_transfer(pos, setup::admin());
        haneul::test_scenario::return_shared(p);
        scenario.end();
    }

    #[test]
    fun deadline_at_current_instant_is_valid() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        let c = test_clock(scenario.ctx());

        let out = router::swap_exact_a_for_b(
            &mut p,
            coin::mint_for_testing<COIN_A>(1000000, scenario.ctx()),
            0,
            NOW_MS, // exactly now
            &c,
            scenario.ctx(),
        );

        coin::burn_for_testing(out);
        c.destroy_for_testing();
        transfer::public_transfer(pos, setup::admin());
        haneul::test_scenario::return_shared(p);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::router::EDeadlinePassed)]
    fun expired_deadline_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        transfer::public_transfer(pos, setup::admin());
        let c = test_clock(scenario.ctx());
        let out = router::swap_exact_a_for_b(
            &mut p,
            coin::mint_for_testing<COIN_A>(1000000, scenario.ctx()),
            0,
            NOW_MS - 1,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(out);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::router::ETooLittleReceived)]
    fun output_below_minimum_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        transfer::public_transfer(pos, setup::admin());
        let c = test_clock(scenario.ctx());
        let out = router::swap_exact_a_for_b(
            &mut p,
            coin::mint_for_testing<COIN_A>(1000000000, scenario.ctx()),
            996006982, // one unit above the reference output
            NOW_MS + 60000,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(out);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::router::ETooMuchRequested)]
    fun input_budget_too_small_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_full_range(&mut p, L_BIG, scenario.ctx());
        transfer::public_transfer(pos, setup::admin());
        let c = test_clock(scenario.ctx());
        // Needs 1_004_013_042; offer exactly 1e9.
        let (out, change) = router::swap_a_for_exact_b(
            &mut p,
            coin::mint_for_testing<COIN_A>(1000000000, scenario.ctx()),
            1000000000,
            NOW_MS + 60000,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(out);
        coin::burn_for_testing(change);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::router::EUnfilledExactOutput)]
    fun draining_the_pool_exact_out_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        // A tiny, narrow position cannot deliver a huge output.
        let pos = setup::fund_range(
            &mut p,
            i32::neg_from(60).bits(),
            i32::from(60).bits(),
            1000000,
            scenario.ctx(),
        );
        transfer::public_transfer(pos, setup::admin());
        let c = test_clock(scenario.ctx());
        let (out, change) = router::swap_a_for_exact_b(
            &mut p,
            coin::mint_for_testing<COIN_A>(1000000000, scenario.ctx()),
            100000000,
            NOW_MS + 60000,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(out);
        coin::burn_for_testing(change);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::router::EPartialFill)]
    fun draining_the_pool_exact_in_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        let pos = setup::fund_range(
            &mut p,
            i32::neg_from(60).bits(),
            i32::from(60).bits(),
            1000000,
            scenario.ctx(),
        );
        transfer::public_transfer(pos, setup::admin());
        let c = test_clock(scenario.ctx());
        let out = router::swap_exact_a_for_b(
            &mut p,
            coin::mint_for_testing<COIN_A>(1000000000, scenario.ctx()),
            0,
            NOW_MS + 60000,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(out);
        abort 0
    }
}
