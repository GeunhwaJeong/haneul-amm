// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

module haneul_amm_periphery::liquidity_tests {
    use haneul::balance;
    use haneul::clock::{Self, Clock};
    use haneul::coin;
    use haneul_amm::test_coins::{COIN_A, COIN_B};
    use haneul_amm_periphery::liquidity;
    use haneul_amm_periphery::test_setup as setup;

    const NOW_MS: u64 = 1000000;
    const DEADLINE: u64 = 2000000;
    /// Principal charged for 1e12 liquidity across the full range at
    /// price 1.0 (reference value, same as the core suite).
    const FULL_RANGE_PRINCIPAL: u64 = 999999999767;

    fun test_clock(ctx: &mut TxContext): Clock {
        let mut c = clock::create_for_testing(ctx);
        c.set_for_testing(NOW_MS);
        c
    }

    #[test]
    fun open_with_exact_budgets_no_change() {
        let (mut scenario, mut p) = setup::setup(3000);
        let c = test_clock(scenario.ctx());

        // Budgets equal to the reference principal buy back exactly
        // 1e12 liquidity with zero change.
        let (pos, change_a, change_b) = liquidity::open_position_with_coins(
            &mut p,
            setup::full_lower_bits(),
            setup::full_upper_bits(),
            coin::mint_for_testing<COIN_A>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            coin::mint_for_testing<COIN_B>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            1000000000000,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        assert!(pos.liquidity() == 1000000000000);
        assert!(change_a.value() == 0 && change_b.value() == 0);
        assert!(p.liquidity() == 1000000000000);

        coin::burn_for_testing(change_a);
        coin::burn_for_testing(change_b);
        c.destroy_for_testing();
        transfer::public_transfer(pos, setup::admin());
        haneul::test_scenario::return_shared(p);
        scenario.end();
    }

    #[test]
    fun open_with_excess_b_returns_change() {
        let (mut scenario, mut p) = setup::setup(3000);
        let c = test_clock(scenario.ctx());

        // A is the binding side; the surplus 1e12 of B comes back.
        let (pos, change_a, change_b) = liquidity::open_position_with_coins(
            &mut p,
            setup::full_lower_bits(),
            setup::full_upper_bits(),
            coin::mint_for_testing<COIN_A>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            coin::mint_for_testing<COIN_B>(FULL_RANGE_PRINCIPAL + 1000000000000, scenario.ctx()),
            1000000000000,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        assert!(pos.liquidity() == 1000000000000);
        assert!(change_a.value() == 0);
        assert!(change_b.value() == 1000000000000);

        coin::burn_for_testing(change_a);
        coin::burn_for_testing(change_b);
        c.destroy_for_testing();
        transfer::public_transfer(pos, setup::admin());
        haneul::test_scenario::return_shared(p);
        scenario.end();
    }

    #[test]
    fun increase_then_decrease_round_trip() {
        let (mut scenario, mut p) = setup::setup(3000);
        let c = test_clock(scenario.ctx());

        let (mut pos, ca, cb) = liquidity::open_position_with_coins(
            &mut p,
            setup::full_lower_bits(),
            setup::full_upper_bits(),
            coin::mint_for_testing<COIN_A>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            coin::mint_for_testing<COIN_B>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            0,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(ca);
        coin::burn_for_testing(cb);

        let (ca2, cb2) = liquidity::increase_liquidity(
            &mut p,
            &mut pos,
            coin::mint_for_testing<COIN_A>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            coin::mint_for_testing<COIN_B>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            1000000000000,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        assert!(pos.liquidity() == 2000000000000);
        coin::burn_for_testing(ca2);
        coin::burn_for_testing(cb2);

        // Withdrawing half must return at least principal - 1 unit of
        // exit rounding per token.
        let (out_a, out_b) = liquidity::decrease_liquidity(
            &mut p,
            &mut pos,
            1000000000000,
            FULL_RANGE_PRINCIPAL - 1,
            FULL_RANGE_PRINCIPAL - 1,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        assert!(pos.liquidity() == 1000000000000);
        coin::burn_for_testing(out_a);
        coin::burn_for_testing(out_b);

        c.destroy_for_testing();
        transfer::public_transfer(pos, setup::admin());
        haneul::test_scenario::return_shared(p);
        scenario.end();
    }

    #[test]
    fun close_position_returns_principal_and_fees() {
        let (mut scenario, mut p) = setup::setup(3000);
        let c = test_clock(scenario.ctx());

        let (pos, ca, cb) = liquidity::open_position_with_coins(
            &mut p,
            setup::full_lower_bits(),
            setup::full_upper_bits(),
            coin::mint_for_testing<COIN_A>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            coin::mint_for_testing<COIN_B>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            0,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(ca);
        coin::burn_for_testing(cb);

        // Earn some fees through the donation path.
        p.donate(
            balance::create_for_testing<COIN_A>(1000000),
            balance::create_for_testing<COIN_B>(2000000),
        );

        let (out_a, out_b) = liquidity::close_position(
            &mut p,
            pos,
            FULL_RANGE_PRINCIPAL - 1,
            FULL_RANGE_PRINCIPAL - 1,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        // Principal (minus exit rounding) plus the donation (minus
        // fee-growth floor rounding).
        assert!(out_a.value() >= FULL_RANGE_PRINCIPAL - 1 + 999999);
        assert!(out_b.value() >= FULL_RANGE_PRINCIPAL - 1 + 1999999);
        assert!(p.liquidity() == 0);

        coin::burn_for_testing(out_a);
        coin::burn_for_testing(out_b);
        c.destroy_for_testing();
        haneul::test_scenario::return_shared(p);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::liquidity::EMinLiquidityNotMet)]
    fun liquidity_below_minimum_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        let c = test_clock(scenario.ctx());
        let (pos, ca, cb) = liquidity::open_position_with_coins(
            &mut p,
            setup::full_lower_bits(),
            setup::full_upper_bits(),
            coin::mint_for_testing<COIN_A>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            coin::mint_for_testing<COIN_B>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            1000000000001, // one unit above what the budgets buy
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(ca);
        coin::burn_for_testing(cb);
        transfer::public_transfer(pos, setup::admin());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::liquidity::EMinAmountNotMet)]
    fun principal_below_minimum_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        let c = test_clock(scenario.ctx());
        let (mut pos, ca, cb) = liquidity::open_position_with_coins(
            &mut p,
            setup::full_lower_bits(),
            setup::full_upper_bits(),
            coin::mint_for_testing<COIN_A>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            coin::mint_for_testing<COIN_B>(FULL_RANGE_PRINCIPAL, scenario.ctx()),
            0,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(ca);
        coin::burn_for_testing(cb);
        let (out_a, out_b) = liquidity::decrease_liquidity(
            &mut p,
            &mut pos,
            1000000000000,
            FULL_RANGE_PRINCIPAL + 1, // impossible: exit rounds down
            0,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(out_a);
        coin::burn_for_testing(out_b);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::liquidity::EZeroLiquidity)]
    fun empty_budgets_abort() {
        let (mut scenario, mut p) = setup::setup(3000);
        let c = test_clock(scenario.ctx());
        let (pos, ca, cb) = liquidity::open_position_with_coins(
            &mut p,
            setup::full_lower_bits(),
            setup::full_upper_bits(),
            coin::zero<COIN_A>(scenario.ctx()),
            coin::zero<COIN_B>(scenario.ctx()),
            0,
            DEADLINE,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(ca);
        coin::burn_for_testing(cb);
        transfer::public_transfer(pos, setup::admin());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm_periphery::liquidity::EDeadlinePassed)]
    fun expired_deadline_aborts() {
        let (mut scenario, mut p) = setup::setup(3000);
        let c = test_clock(scenario.ctx());
        let (pos, ca, cb) = liquidity::open_position_with_coins(
            &mut p,
            setup::full_lower_bits(),
            setup::full_upper_bits(),
            coin::mint_for_testing<COIN_A>(1000, scenario.ctx()),
            coin::mint_for_testing<COIN_B>(1000, scenario.ctx()),
            0,
            NOW_MS - 1,
            &c,
            scenario.ctx(),
        );
        coin::burn_for_testing(ca);
        coin::burn_for_testing(cb);
        transfer::public_transfer(pos, setup::admin());
        abort 0
    }
}
