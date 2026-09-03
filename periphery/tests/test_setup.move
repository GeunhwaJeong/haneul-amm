// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Shared fixtures: a fresh registry, a standard pool (0.3% fee,
/// spacing 60, price 1.0), and positions funded through the core API.
#[test_only]
module haneul_amm_periphery::test_setup {
    use haneul::balance;
    use haneul::test_scenario as ts;
    use haneul_amm::haneul_amm as amm_init;
    use haneul_amm::i32;
    use haneul_amm::pool::{Self, Pool, ProtocolCap};
    use haneul_amm::position::Position;
    use haneul_amm::registry::{Self, Registry};
    use haneul_amm::test_coins::{COIN_A, COIN_B};

    const ADMIN: address = @0xAD;

    public fun admin(): address {
        ADMIN
    }

    /// Full usable range bounds for tick spacing 60.
    public fun full_lower_bits(): u32 {
        i32::neg_from(443580).bits()
    }

    public fun full_upper_bits(): u32 {
        i32::from(443580).bits()
    }

    public fun setup(fee_pips: u64): (ts::Scenario, Pool<COIN_A, COIN_B>) {
        let mut scenario = ts::begin(ADMIN);
        amm_init::init_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);
        let mut reg = scenario.take_shared<Registry>();
        if (!reg.is_fee_tier_enabled(fee_pips, 60)) {
            let cap = scenario.take_from_sender<ProtocolCap>();
            reg.enable_fee_tier(&cap, fee_pips, 60);
            scenario.return_to_sender(cap);
        };
        registry::create_pool<COIN_A, COIN_B>(&mut reg, fee_pips, 60, 1 << 64, scenario.ctx());
        ts::return_shared(reg);
        scenario.next_tx(ADMIN);
        let p = scenario.take_shared<Pool<COIN_A, COIN_B>>();
        (scenario, p)
    }

    /// Fund a position through the core API, paying whatever it asks.
    public fun fund_range(
        p: &mut Pool<COIN_A, COIN_B>,
        lower_bits: u32,
        upper_bits: u32,
        liquidity: u128,
        ctx: &mut TxContext,
    ): Position {
        let mut pos = p.open_position(lower_bits, upper_bits, ctx);
        let receipt = p.add_liquidity(&mut pos, liquidity);
        let (need_a, need_b) = pool::add_liquidity_receipt_amounts(&receipt);
        p.repay_add_liquidity(
            receipt,
            balance::create_for_testing<COIN_A>(need_a),
            balance::create_for_testing<COIN_B>(need_b),
        );
        pos
    }

    public fun fund_full_range(
        p: &mut Pool<COIN_A, COIN_B>,
        liquidity: u128,
        ctx: &mut TxContext,
    ): Position {
        fund_range(p, full_lower_bits(), full_upper_bits(), liquidity, ctx)
    }
}
