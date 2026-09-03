// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Hook gating and dynamic fees.
///
/// `test_hook` stands in for an external hook package: it owns two
/// witness types and exposes them only through its own functions,
/// exactly as a real hook module would.
#[test_only]
module haneul_amm::test_hook {
    public struct Hook has drop {}

    public struct OtherHook has drop {}

    public fun witness(): Hook {
        Hook {}
    }

    public fun other_witness(): OtherHook {
        OtherHook {}
    }
}

#[test_only]
module haneul_amm::hook_tests {
    use haneul::balance;
    use haneul::test_scenario as ts;
    use haneul_amm::haneul_amm as amm_init;
    use haneul_amm::i32;
    use haneul_amm::pool::{Self, Pool};
    use haneul_amm::registry::{Self, Registry};
    use haneul_amm::test_coins::{COIN_A, COIN_B};
    use haneul_amm::test_hook;
    use haneul_amm::tick_math;

    const ADMIN: address = @0xAD;
    const PRICE_1: u128 = 1 << 64;
    const L_BIG: u128 = 1000000000000;
    const FULL: u32 = 443580;

    /// Create a hooked pool; `dynamic` implies a zero starting fee.
    fun setup_hooked(
        permissions: u8,
        fee_pips: u64,
        dynamic: bool,
    ): (ts::Scenario, Pool<COIN_A, COIN_B>) {
        let mut scenario = ts::begin(ADMIN);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool_with_hook<COIN_A, COIN_B, test_hook::Hook>(
            &mut reg,
            test_hook::witness(),
            fee_pips,
            dynamic,
            60,
            permissions,
            PRICE_1,
            scenario.ctx(),
        );
        ts::return_shared(reg);
        scenario.next_tx(ADMIN);
        let p = scenario.take_shared<Pool<COIN_A, COIN_B>>();
        (scenario, p)
    }

    fun fund_full_range(
        p: &mut Pool<COIN_A, COIN_B>,
        ctx: &mut TxContext,
    ): haneul_amm::position::Position {
        let mut pos = p.open_position(
            i32::neg_from(FULL).bits(),
            i32::from(FULL).bits(),
            ctx,
        );
        // The test pools gate swaps and/or donations, never liquidity,
        // so the plain path funds them.
        let receipt = p.add_liquidity(&mut pos, L_BIG);
        let (need_a, need_b) = pool::add_liquidity_receipt_amounts(&receipt);
        p.repay_add_liquidity(
            receipt,
            balance::create_for_testing<COIN_A>(need_a),
            balance::create_for_testing<COIN_B>(need_b),
        );
        pos
    }

    // === Gating ===

    #[test]
    fun hooked_swap_works_with_witness() {
        let (mut scenario, mut p) = setup_hooked(pool::hook_on_swap(), 3000, false);
        assert!(p.hook().is_some());
        assert!(p.hook_permissions() == pool::hook_on_swap());
        let pos = fund_full_range(&mut p, scenario.ctx());

        let (out_b, receipt) = p.swap_a_for_b_with_hook(
            test_hook::witness(),
            1000000000,
            true,
            tick_math::min_sqrt_price() + 1,
            option::none(),
        );
        // Same market, same math: matches the hookless reference swap.
        assert!(out_b.value() == 996006981);
        let (owed, _) = pool::swap_receipt_amounts(&receipt);
        p.repay_swap_a(receipt, balance::create_for_testing<COIN_A>(owed));

        balance::destroy_for_testing(out_b);
        transfer::public_transfer(pos, ADMIN);
        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::EHookRequired)]
    fun plain_swap_on_gated_pool_aborts() {
        let (mut scenario, mut p) = setup_hooked(pool::hook_on_swap(), 3000, false);
        let pos = fund_full_range(&mut p, scenario.ctx());
        transfer::public_transfer(pos, ADMIN);
        let (out, receipt) = p.swap_a_for_b(1000, true, tick_math::min_sqrt_price() + 1);
        balance::destroy_for_testing(out);
        p.repay_swap_a(receipt, balance::zero());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::EWrongHook)]
    fun wrong_witness_aborts() {
        let (mut scenario, mut p) = setup_hooked(pool::hook_on_swap(), 3000, false);
        let pos = fund_full_range(&mut p, scenario.ctx());
        transfer::public_transfer(pos, ADMIN);
        let (out, receipt) = p.swap_a_for_b_with_hook(
            test_hook::other_witness(),
            1000,
            true,
            tick_math::min_sqrt_price() + 1,
            option::none(),
        );
        balance::destroy_for_testing(out);
        p.repay_swap_a(receipt, balance::zero());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::EWrongHook)]
    fun hook_path_on_hookless_pool_aborts() {
        let mut scenario = ts::begin(ADMIN);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        ts::return_shared(reg);
        scenario.next_tx(ADMIN);
        let mut p = scenario.take_shared<Pool<COIN_A, COIN_B>>();
        let (out, receipt) = p.swap_a_for_b_with_hook(
            test_hook::witness(),
            1000,
            true,
            tick_math::min_sqrt_price() + 1,
            option::none(),
        );
        balance::destroy_for_testing(out);
        p.repay_swap_a(receipt, balance::zero());
        abort 0
    }

    #[test]
    fun ungated_operations_stay_open_on_hooked_pool() {
        // Swap-only gate: liquidity, donations and fee collection keep
        // their plain entry points.
        let (mut scenario, mut p) = setup_hooked(pool::hook_on_swap(), 3000, false);
        let mut pos = fund_full_range(&mut p, scenario.ctx());
        p.donate(
            balance::create_for_testing<COIN_A>(1000),
            balance::create_for_testing<COIN_B>(0),
        );
        let (fee_a, fee_b) = p.collect_fees(&mut pos);
        assert!(fee_a.value() == 999); // floor rounding
        balance::destroy_for_testing(fee_a);
        balance::destroy_for_testing(fee_b);
        let (got_a, got_b) = p.remove_liquidity(&mut pos, L_BIG);
        balance::destroy_for_testing(got_a);
        balance::destroy_for_testing(got_b);
        transfer::public_transfer(pos, ADMIN);
        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::EHookRequired)]
    fun gated_donation_aborts_on_plain_path() {
        let (mut scenario, mut p) = setup_hooked(pool::hook_on_donate(), 3000, false);
        let pos = fund_full_range(&mut p, scenario.ctx());
        transfer::public_transfer(pos, ADMIN);
        p.donate(
            balance::create_for_testing<COIN_A>(1000),
            balance::create_for_testing<COIN_B>(0),
        );
        abort 0
    }

    #[test]
    fun gated_donation_works_with_witness() {
        let (mut scenario, mut p) = setup_hooked(pool::hook_on_donate(), 3000, false);
        let pos = fund_full_range(&mut p, scenario.ctx());
        p.donate_with_hook(
            test_hook::witness(),
            balance::create_for_testing<COIN_A>(1000),
            balance::create_for_testing<COIN_B>(0),
        );
        transfer::public_transfer(pos, ADMIN);
        ts::return_shared(p);
        scenario.end();
    }

    // === Dynamic fees ===

    #[test]
    fun dynamic_fee_lifecycle() {
        // Dynamic pool, no gated operations: the hook only steers fees.
        let (mut scenario, mut p) = setup_hooked(pool::hook_on_swap(), 0, true);
        assert!(p.is_dynamic_fee());
        assert!(p.lp_fee_pips() == 0);
        let pos = fund_full_range(&mut p, scenario.ctx());

        // Hook raises the stored fee to 0.3%.
        p.update_lp_fee(test_hook::witness(), 3000);
        assert!(p.lp_fee_pips() == 3000);

        // A swap at the stored fee matches the static-fee reference.
        let (out1, r1) = p.swap_a_for_b_with_hook(
            test_hook::witness(),
            1000000000,
            true,
            tick_math::min_sqrt_price() + 1,
            option::none(),
        );
        assert!(out1.value() == 996006981);
        let (owed1, _) = pool::swap_receipt_amounts(&r1);
        p.repay_swap_a(r1, balance::create_for_testing<COIN_A>(owed1));

        // A per-swap override to zero fee yields strictly more output.
        let (out2, r2) = p.swap_a_for_b_with_hook(
            test_hook::witness(),
            1000000000,
            true,
            tick_math::min_sqrt_price() + 1,
            option::some(0),
        );
        assert!(out2.value() > 996006981);
        let (owed2, _) = pool::swap_receipt_amounts(&r2);
        p.repay_swap_a(r2, balance::create_for_testing<COIN_A>(owed2));

        balance::destroy_for_testing(out1);
        balance::destroy_for_testing(out2);
        transfer::public_transfer(pos, ADMIN);
        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::ENotDynamicFee)]
    fun updating_fee_on_static_pool_aborts() {
        let (_scenario, mut p) = setup_hooked(pool::hook_on_swap(), 3000, false);
        p.update_lp_fee(test_hook::witness(), 500);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::EWrongHook)]
    fun updating_fee_with_wrong_witness_aborts() {
        let (_scenario, mut p) = setup_hooked(pool::hook_on_swap(), 0, true);
        p.update_lp_fee(test_hook::other_witness(), 500);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::EFeeOverrideOnStaticPool)]
    fun fee_override_on_static_pool_aborts() {
        let (mut scenario, mut p) = setup_hooked(pool::hook_on_swap(), 3000, false);
        let pos = fund_full_range(&mut p, scenario.ctx());
        transfer::public_transfer(pos, ADMIN);
        let (out, receipt) = p.swap_a_for_b_with_hook(
            test_hook::witness(),
            1000,
            true,
            tick_math::min_sqrt_price() + 1,
            option::some(100),
        );
        balance::destroy_for_testing(out);
        p.repay_swap_a(receipt, balance::zero());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::ELpFeeTooLarge)]
    fun oversized_fee_override_aborts() {
        let (mut scenario, mut p) = setup_hooked(pool::hook_on_swap(), 0, true);
        let pos = fund_full_range(&mut p, scenario.ctx());
        transfer::public_transfer(pos, ADMIN);
        let (out, receipt) = p.swap_a_for_b_with_hook(
            test_hook::witness(),
            1000,
            true,
            tick_math::min_sqrt_price() + 1,
            option::some(1000001),
        );
        balance::destroy_for_testing(out);
        p.repay_swap_a(receipt, balance::zero());
        abort 0
    }

    // === Creation validation ===

    #[test]
    #[expected_failure(abort_code = haneul_amm::registry::EUselessHook)]
    fun hook_gating_nothing_aborts() {
        let mut scenario = ts::begin(ADMIN);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool_with_hook<COIN_A, COIN_B, test_hook::Hook>(
            &mut reg,
            test_hook::witness(),
            3000,
            false, // not dynamic
            60,
            0, // gates nothing
            PRICE_1,
            scenario.ctx(),
        );
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::registry::EInvalidHookPermissions)]
    fun unknown_permission_bits_abort() {
        let mut scenario = ts::begin(ADMIN);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool_with_hook<COIN_A, COIN_B, test_hook::Hook>(
            &mut reg,
            test_hook::witness(),
            3000,
            false,
            60,
            0x10,
            PRICE_1,
            scenario.ctx(),
        );
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::EDynamicFeeMustStartZero)]
    fun dynamic_pool_with_nonzero_fee_aborts() {
        let mut scenario = ts::begin(ADMIN);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool_with_hook<COIN_A, COIN_B, test_hook::Hook>(
            &mut reg,
            test_hook::witness(),
            3000,
            true,
            60,
            pool::hook_on_swap(),
            PRICE_1,
            scenario.ctx(),
        );
        abort 0
    }

    #[test]
    fun hooked_and_hookless_pools_coexist_in_registry() {
        let mut scenario = ts::begin(ADMIN);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);
        let mut reg = scenario.take_shared<Registry>();
        let plain_id =
            registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        let hooked_id = registry::create_pool_with_hook<COIN_A, COIN_B, test_hook::Hook>(
            &mut reg,
            test_hook::witness(),
            3000,
            false,
            60,
            pool::hook_on_swap(),
            PRICE_1,
            scenario.ctx(),
        );
        assert!(plain_id != hooked_id);
        assert!(reg.pool_count() == 2);

        let hook_name = std::type_name::with_defining_ids<test_hook::Hook>();
        let found = registry::find_pool<COIN_A, COIN_B>(
            &reg,
            3000,
            false,
            60,
            option::some(hook_name),
        );
        assert!(found.destroy_some() == hooked_id);

        ts::return_shared(reg);
        scenario.end();
    }
}
