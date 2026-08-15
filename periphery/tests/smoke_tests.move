// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Confirms the periphery test environment can drive the core package:
/// its test-only initializer, test coins, and a live pool.
#[test_only]
module haneul_amm_periphery::smoke_tests {
    use haneul::test_scenario as ts;
    use haneul_amm::haneul_amm as amm_init;
    use haneul_amm::pool::Pool;
    use haneul_amm::registry::{Self, Registry};
    use haneul_amm::test_coins::{COIN_A, COIN_B};

    #[test]
    fun core_test_fixtures_are_reachable() {
        let mut scenario = ts::begin(@0xAD);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(@0xAD);
        let mut reg = scenario.take_shared<Registry>();
        registry::create_pool<COIN_A, COIN_B>(&mut reg, 3000, 60, 1 << 64, scenario.ctx());
        ts::return_shared(reg);
        scenario.next_tx(@0xAD);
        let p = scenario.take_shared<Pool<COIN_A, COIN_B>>();
        assert!(p.liquidity() == 0);
        ts::return_shared(p);
        scenario.end();
    }
}
