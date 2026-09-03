// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

module haneul_amm::registry_tests {
    use haneul::test_scenario as ts;
    use haneul_amm::haneul_amm as amm_init;
    use haneul_amm::pool::{Pool, ProtocolCap};
    use haneul_amm::registry::{Self, Registry};
    use haneul_amm::test_coins::{COIN_A, COIN_B, COIN_C};
    use haneul_amm::test_hook;

    const ADMIN: address = @0xAD;
    const PRICE_1: u128 = 1 << 64;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);
        scenario
    }

    #[test]
    fun create_and_find_pool() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();

        assert!(reg.pool_count() == 0);
        let pool_id =
            registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        assert!(reg.pool_count() == 1);

        let found = registry::find_pool<COIN_A, COIN_B>(&reg, 3000, false, 60, option::none());
        assert!(found.is_some() && found.destroy_some() == pool_id);
        // Different fee tier: distinct market, not found.
        let missing = registry::find_pool<COIN_A, COIN_B>(&reg, 500, false, 60, option::none());
        assert!(missing.is_none());

        ts::return_shared(reg);
        scenario.end();
    }

    #[test]
    fun same_pair_different_parameters_coexist() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();

        registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 500, 10, PRICE_1, scenario.ctx());
        registry::create_pool<COIN_A, COIN_C>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        registry::create_pool<COIN_B, COIN_C>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        assert!(reg.pool_count() == 4);

        ts::return_shared(reg);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::registry::EPoolAlreadyExists)]
    fun duplicate_pool_aborts() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::registry::ECurrenciesOutOfOrder)]
    fun reversed_currency_order_aborts() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_B, COIN_A>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::registry::ECurrenciesOutOfOrder)]
    fun identical_currencies_abort() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_A, COIN_A>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());
        abort 0
    }

    // === Fee tiers ===

    #[test]
    fun default_fee_tiers_are_enabled() {
        let scenario = setup();
        let reg = scenario.take_shared<Registry>();
        assert!(reg.is_fee_tier_enabled(100, 1));
        assert!(reg.is_fee_tier_enabled(500, 10));
        assert!(reg.is_fee_tier_enabled(3000, 60));
        assert!(reg.is_fee_tier_enabled(10000, 200));
        assert!(!reg.is_fee_tier_enabled(500, 60));
        assert!(registry::fee_tiers(&reg).length() == 4);
        ts::return_shared(reg);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::registry::EFeeTierNotEnabled)]
    fun pool_on_disabled_tier_aborts() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 500, 60, PRICE_1, scenario.ctx());
        abort 0
    }

    #[test]
    fun enabling_a_tier_allows_pools_on_it() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        let cap = scenario.take_from_sender<ProtocolCap>();
        reg.enable_fee_tier(&cap, 500, 60);
        assert!(reg.is_fee_tier_enabled(500, 60));
        let tiers = registry::fee_tiers(&reg);
        assert!(tiers.length() == 5);
        let last = &tiers[4];
        assert!(registry::fee_tier_lp_fee_pips(last) == 500);
        assert!(registry::fee_tier_tick_spacing(last) == 60);
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 500, 60, PRICE_1, scenario.ctx());
        assert!(reg.pool_count() == 1);
        scenario.return_to_sender(cap);
        ts::return_shared(reg);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::registry::EFeeTierAlreadyEnabled)]
    fun enabling_a_tier_twice_aborts() {
        let scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        let cap = scenario.take_from_sender<ProtocolCap>();
        reg.enable_fee_tier(&cap, 3000, 60);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::ETickSpacingOutOfRange)]
    fun zero_tick_spacing_tier_aborts() {
        let scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        let cap = scenario.take_from_sender<ProtocolCap>();
        reg.enable_fee_tier(&cap, 3000, 0);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::ETickSpacingOutOfRange)]
    fun oversized_tick_spacing_tier_aborts() {
        let scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        let cap = scenario.take_from_sender<ProtocolCap>();
        reg.enable_fee_tier(&cap, 3000, 32768);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::ELpFeeTooLarge)]
    fun fee_above_100_percent_tier_aborts() {
        let scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        let cap = scenario.take_from_sender<ProtocolCap>();
        reg.enable_fee_tier(&cap, 1000001, 60);
        abort 0
    }

    #[test]
    fun hooked_pools_are_not_tier_gated() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        // 0.07% at spacing 7 is no tier, but the hook consents.
        registry::create_pool_with_hook<COIN_A, COIN_B, test_hook::Hook>(
            &mut reg,
            test_hook::witness(),
            700,
            false,
            7,
            haneul_amm::pool::hook_on_swap(),
            PRICE_1,
            scenario.ctx(),
        );
        assert!(reg.pool_count() == 1);
        ts::return_shared(reg);
        scenario.end();
    }

    // === Default protocol fee ===

    #[test]
    fun default_protocol_fee_applies_to_new_pools_only() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        let (a, b) = reg.default_protocol_fee();
        assert!(a == 0 && b == 0);
        let before_id =
            registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 60, PRICE_1, scenario.ctx());

        let cap = scenario.take_from_sender<ProtocolCap>();
        reg.set_default_protocol_fee(&cap, 1000, 500);
        let (a, b) = reg.default_protocol_fee();
        assert!(a == 1000 && b == 500);
        let after_id =
            registry::create_pool<COIN_A, COIN_B>(&mut reg, 500, 10, PRICE_1, scenario.ctx());
        scenario.return_to_sender(cap);
        ts::return_shared(reg);

        scenario.next_tx(ADMIN);
        let before = scenario.take_shared_by_id<Pool<COIN_A, COIN_B>>(before_id);
        let after = scenario.take_shared_by_id<Pool<COIN_A, COIN_B>>(after_id);
        let (a0, b0) = before.protocol_fees_pips();
        let (a1, b1) = after.protocol_fees_pips();
        assert!(a0 == 0 && b0 == 0);
        assert!(a1 == 1000 && b1 == 500);
        ts::return_shared(before);
        ts::return_shared(after);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::EProtocolFeeTooLarge)]
    fun default_protocol_fee_above_cap_aborts() {
        let scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        let cap = scenario.take_from_sender<ProtocolCap>();
        reg.set_default_protocol_fee(&cap, 1001, 0);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::tick_math::EInvalidSqrtPrice)]
    fun out_of_range_initial_price_aborts() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 60, 1, scenario.ctx());
        abort 0
    }
}
