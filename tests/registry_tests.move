// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

module haneul_amm::registry_tests {
    use haneul::test_scenario as ts;
    use haneul_amm::haneul_amm as amm_init;
    use haneul_amm::registry::{Self, Registry};
    use haneul_amm::test_coins::{COIN_A, COIN_B, COIN_C};

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

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::ETickSpacingOutOfRange)]
    fun zero_tick_spacing_aborts() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 0, PRICE_1, scenario.ctx());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::ETickSpacingOutOfRange)]
    fun oversized_tick_spacing_aborts() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 32768, PRICE_1, scenario.ctx());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::pool::ELpFeeTooLarge)]
    fun fee_above_100_percent_aborts() {
        let mut scenario = setup();
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 1000001, 60, PRICE_1, scenario.ctx());
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
