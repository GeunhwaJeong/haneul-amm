// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Quoter matrix: quote-then-execute agreement across fee tiers,
/// directions, exactness and amount scales, on a banded pool whose
/// state evolves between cases (each execution feeds the next quote).
/// The quoter's contract is bit-for-bit agreement with the pool on
/// every field: the amount in, the amount out, and the post-swap price.
#[test_only]
module haneul_amm_periphery::quoter_matrix_tests {
    use haneul::balance;
    use haneul::test_scenario as ts;
    use haneul_amm::i32;
    use haneul_amm::pool::{Self, Pool};
    use haneul_amm::test_coins::{COIN_A, COIN_B};
    use haneul_amm::tick_math;
    use haneul_amm_periphery::quoter;
    use haneul_amm_periphery::test_setup as setup;

    /// Quote, execute, and require agreement. Codes are
    /// `case * 10 + field`: 0 out, 1 in, 2 price.
    fun quote_and_execute(
        p: &mut Pool<COIN_A, COIN_B>,
        a_to_b: bool,
        exact_in: bool,
        amount: u64,
        code: u64,
    ) {
        let limit = if (a_to_b) {
            tick_math::min_sqrt_price() + 1
        } else {
            tick_math::max_sqrt_price() - 1
        };

        let (quoted_in, quoted_out, quoted_price) = if (exact_in) {
            let (out, in_, price) = quoter::quote_exact_in(p, a_to_b, amount, limit);
            (in_, out, price)
        } else {
            let (in_, filled, price) = quoter::quote_exact_out(p, a_to_b, amount, limit);
            (in_, filled, price)
        };

        if (a_to_b) {
            let (out, receipt) = p.swap_a_for_b(amount, exact_in, limit);
            let (owed, _) = pool::swap_receipt_amounts(&receipt);
            p.repay_swap_a(receipt, balance::create_for_testing<COIN_A>(owed));
            assert!(out.value() == quoted_out, code);
            assert!(owed == quoted_in, code + 1);
            balance::destroy_for_testing(out);
        } else {
            let (out, receipt) = p.swap_b_for_a(amount, exact_in, limit);
            let (owed, _) = pool::swap_receipt_amounts(&receipt);
            p.repay_swap_b(receipt, balance::create_for_testing<COIN_B>(owed));
            assert!(out.value() == quoted_out, code);
            assert!(owed == quoted_in, code + 1);
            balance::destroy_for_testing(out);
        };
        assert!(p.sqrt_price_x64() == quoted_price, code + 2);
    }

    /// Banded topology (full range + inner band + one-sided band) and
    /// 12 chained quote/execute rounds: 3 amounts x 2 directions x
    /// exact-in/exact-out. Large amounts cross the inner band edges.
    fun run_matrix(fee_pips: u64) {
        let (mut scenario, mut p) = setup::setup(fee_pips);
        let pos_full = setup::fund_full_range(&mut p, 1000000000000, scenario.ctx());
        let pos_band = setup::fund_range(
            &mut p,
            i32::neg_from(600).bits(),
            i32::from(600).bits(),
            5000000000000,
            scenario.ctx(),
        );
        let pos_high = setup::fund_range(
            &mut p,
            i32::from(600).bits(),
            i32::from(1800).bits(),
            2000000000000,
            scenario.ctx(),
        );

        let amounts = vector<u64>[1000, 1000000000, 40000000000];
        let mut case = 0;
        let mut k = 0;
        while (k < amounts.length()) {
            let amount = amounts[k];
            quote_and_execute(&mut p, true, true, amount, case * 10);
            case = case + 1;
            quote_and_execute(&mut p, true, false, amount, case * 10);
            case = case + 1;
            quote_and_execute(&mut p, false, true, amount, case * 10);
            case = case + 1;
            quote_and_execute(&mut p, false, false, amount, case * 10);
            case = case + 1;
            k = k + 1;
        };

        transfer::public_transfer(pos_full, setup::admin());
        transfer::public_transfer(pos_band, setup::admin());
        transfer::public_transfer(pos_high, setup::admin());
        ts::return_shared(p);
        scenario.end();
    }

    #[test]
    fun quoter_matrix_fee_500() {
        run_matrix(500);
    }

    #[test]
    fun quoter_matrix_fee_3000() {
        run_matrix(3000);
    }

    #[test]
    fun quoter_matrix_fee_10000() {
        run_matrix(10000);
    }
}
