// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Long-sequence solvency and ledger-identity tests.
///
/// Each test drives a pool through a deterministic sequence of swaps
/// (and, where relevant, liquidity changes and donations), then
/// withdraws everything: LP fees, all principals, protocol fees. Two
/// properties must hold with no reference values at all:
///
/// 1. Solvency: every withdrawal succeeds; the pool can always pay
///    what it owes, in any order, after any swap history.
/// 2. Ledger identity: final reserves equal exactly
///    deposits + swap inputs (net of the protocol's cut) - swap
///    outputs - principals returned - fees paid out. Rounding dust is
///    the only value the pool may retain, and it is bounded.
#[test_only]
module haneul_amm::sequence_tests {
    use haneul::balance::{Self, Balance};
    use haneul::test_scenario as ts;
    use haneul_amm::i32;
    use haneul_amm::pool::{Self, Pool};
    use haneul_amm::position::Position;
    use haneul_amm::test_coins::{COIN_A, COIN_B};
    use haneul_amm::tick_math;

    const ADMIN: address = @0xAD;
    const PRICE_1: u128 = 1 << 64;
    const FULL: u32 = 443580;

    /// Ledger accumulators, all in u128 to avoid summing overflow.
    public struct Ledger has drop {
        deposited_a: u128,
        deposited_b: u128,
        swapped_in_a: u128,
        swapped_in_b: u128,
        swapped_out_a: u128,
        swapped_out_b: u128,
        protocol_cut_a: u128,
        protocol_cut_b: u128,
        paid_out_a: u128,
        paid_out_b: u128,
    }

    fun ledger(): Ledger {
        Ledger {
            deposited_a: 0,
            deposited_b: 0,
            swapped_in_a: 0,
            swapped_in_b: 0,
            swapped_out_a: 0,
            swapped_out_b: 0,
            protocol_cut_a: 0,
            protocol_cut_b: 0,
            paid_out_a: 0,
            paid_out_b: 0,
        }
    }

    fun fund(
        p: &mut Pool<COIN_A, COIN_B>,
        l: &mut Ledger,
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
        l.deposited_a = l.deposited_a + (need_a as u128);
        l.deposited_b = l.deposited_b + (need_b as u128);
        pos
    }

    fun swap(
        p: &mut Pool<COIN_A, COIN_B>,
        l: &mut Ledger,
        a_to_b: bool,
        exact_in: bool,
        amount: u64,
    ) {
        if (a_to_b) {
            let (out, receipt) = p.swap_a_for_b(
                amount,
                exact_in,
                tick_math::min_sqrt_price() + 1,
            );
            let (owed, pf) = pool::swap_receipt_amounts(&receipt);
            p.repay_swap_a(receipt, balance::create_for_testing<COIN_A>(owed));
            l.swapped_in_a = l.swapped_in_a + (owed as u128);
            l.protocol_cut_a = l.protocol_cut_a + (pf as u128);
            l.swapped_out_b = l.swapped_out_b + (out.value() as u128);
            balance::destroy_for_testing(out);
        } else {
            let (out, receipt) = p.swap_b_for_a(
                amount,
                exact_in,
                tick_math::max_sqrt_price() - 1,
            );
            let (owed, pf) = pool::swap_receipt_amounts(&receipt);
            p.repay_swap_b(receipt, balance::create_for_testing<COIN_B>(owed));
            l.swapped_in_b = l.swapped_in_b + (owed as u128);
            l.protocol_cut_b = l.protocol_cut_b + (pf as u128);
            l.swapped_out_a = l.swapped_out_a + (out.value() as u128);
            balance::destroy_for_testing(out);
        };
    }

    fun absorb(l: &mut Ledger, a: Balance<COIN_A>, b: Balance<COIN_B>) {
        l.paid_out_a = l.paid_out_a + (a.value() as u128);
        l.paid_out_b = l.paid_out_b + (b.value() as u128);
        balance::destroy_for_testing(a);
        balance::destroy_for_testing(b);
    }

    /// Drain a position completely: collect its fees, remove all its
    /// liquidity, collect the residual fees the removal settled.
    fun drain_position(
        p: &mut Pool<COIN_A, COIN_B>,
        l: &mut Ledger,
        pos: &mut Position,
    ) {
        let liq = pos.liquidity();
        if (liq > 0) {
            let (pa, pb) = p.remove_liquidity(pos, liq);
            absorb(l, pa, pb);
        };
        let (fa, fb) = p.collect_fees(pos);
        absorb(l, fa, fb);
    }

    /// Assert the exact ledger identity and the dust bound, then check
    /// the pool is fully unwound.
    fun check_final(
        p: &Pool<COIN_A, COIN_B>,
        l: &Ledger,
        max_dust: u128,
    ) {
        assert!(p.liquidity() == 0, 100);
        let (ra, rb) = p.reserves();

        // What flowed in, minus what flowed out, must sit in reserves.
        let in_a = l.deposited_a + l.swapped_in_a - l.protocol_cut_a;
        let in_b = l.deposited_b + l.swapped_in_b - l.protocol_cut_b;
        let out_a = l.swapped_out_a + l.paid_out_a;
        let out_b = l.swapped_out_b + l.paid_out_b;
        assert!(in_a >= out_a, 101);
        assert!(in_b >= out_b, 102);
        assert!((ra as u128) == in_a - out_a, 103);
        assert!((rb as u128) == in_b - out_b, 104);

        // Rounding dust only: the pool retains crumbs, never value.
        assert!((ra as u128) <= max_dust, 105);
        assert!((rb as u128) <= max_dust, 106);
    }

    #[test]
    fun alternating_sequence_full_ledger_identity() {
        let mut scenario = ts::begin(ADMIN);
        let ctx = scenario.ctx();
        let mut l = ledger();
        let mut p = pool::new<COIN_A, COIN_B>(
            3000, false, 60, option::none(), 0, 0, 0, PRICE_1, ctx,
        );
        let cap = pool::new_protocol_cap(ctx);
        p.set_protocol_fee(&cap, 1000, 1000);

        let mut pos_full = fund(
            &mut p, &mut l,
            i32::neg_from(FULL).bits(), i32::from(FULL).bits(),
            1000000000000, ctx,
        );
        let mut pos_band = fund(
            &mut p, &mut l,
            i32::neg_from(60).bits(), i32::from(60).bits(),
            5000000000000, ctx,
        );
        let mut pos_high = fund(
            &mut p, &mut l,
            i32::from(600).bits(), i32::from(1800).bits(),
            2000000000000, ctx,
        );

        // Deterministic mixed sizes; the large entries push the price
        // in and out of the inner band and across the one-sided range.
        let amounts = vector<u64>[
            1000000, 25000000000, 3000000, 900000000, 25000000000,
            50000000, 12000000000, 7, 4000000000, 30000000000,
            123456789, 2500000000, 18000000000, 999, 26000000000,
            777777777, 5000000000, 21000000000,
        ];
        let mut i = 0;
        while (i < amounts.length()) {
            // Direction and exactness cycle out of phase so all four
            // combinations occur against varied states.
            let a_to_b = i % 2 == 0;
            let exact_in = i % 3 != 0;
            swap(&mut p, &mut l, a_to_b, exact_in, amounts[i]);
            i = i + 1;
        };

        drain_position(&mut p, &mut l, &mut pos_full);
        drain_position(&mut p, &mut l, &mut pos_band);
        drain_position(&mut p, &mut l, &mut pos_high);

        let (proto_a, proto_b) = p.collect_protocol_fees(&cap);
        assert!((proto_a.value() as u128) == l.protocol_cut_a, 107);
        assert!((proto_b.value() as u128) == l.protocol_cut_b, 108);
        balance::destroy_for_testing(proto_a);
        balance::destroy_for_testing(proto_b);

        // 18 swaps + 3 positions, a few units of rounding each.
        check_final(&p, &l, 200);

        transfer::public_transfer(pos_full, ADMIN);
        transfer::public_transfer(pos_band, ADMIN);
        transfer::public_transfer(pos_high, ADMIN);
        transfer::public_transfer(cap, ADMIN);
        pool::share(p);
        scenario.end();
    }

    #[test]
    fun interleaved_liquidity_changes_stay_solvent() {
        let mut scenario = ts::begin(ADMIN);
        let ctx = scenario.ctx();
        let mut l = ledger();
        let mut p = pool::new<COIN_A, COIN_B>(
            500, false, 60, option::none(), 0, 0, 0, PRICE_1, ctx,
        );

        let mut pos_full = fund(
            &mut p, &mut l,
            i32::neg_from(FULL).bits(), i32::from(FULL).bits(),
            1000000000000, ctx,
        );

        swap(&mut p, &mut l, true, true, 8000000000);
        swap(&mut p, &mut l, false, false, 3000000000);

        // A band arrives mid-history, in range at the drifted price.
        let mut pos_band = fund(
            &mut p, &mut l,
            i32::neg_from(1200).bits(), i32::from(1200).bits(),
            4000000000000, ctx,
        );

        swap(&mut p, &mut l, false, true, 20000000000);
        swap(&mut p, &mut l, true, false, 9000000000);

        // Partially unwind the band while it is earning, then keep
        // trading against the remainder.
        let (pa, pb) = p.remove_liquidity(&mut pos_band, 1500000000000);
        absorb(&mut l, pa, pb);

        swap(&mut p, &mut l, true, true, 26000000000);
        swap(&mut p, &mut l, false, true, 1000000);
        swap(&mut p, &mut l, true, false, 12000000000);

        // A second tranche into the same position after earning fees.
        let receipt = p.add_liquidity(&mut pos_band, 700000000000);
        let (need_a, need_b) = pool::add_liquidity_receipt_amounts(&receipt);
        p.repay_add_liquidity(
            receipt,
            balance::create_for_testing<COIN_A>(need_a),
            balance::create_for_testing<COIN_B>(need_b),
        );
        l.deposited_a = l.deposited_a + (need_a as u128);
        l.deposited_b = l.deposited_b + (need_b as u128);

        swap(&mut p, &mut l, false, false, 15000000000);
        swap(&mut p, &mut l, true, true, 400000000);

        drain_position(&mut p, &mut l, &mut pos_band);
        drain_position(&mut p, &mut l, &mut pos_full);

        check_final(&p, &l, 200);

        transfer::public_transfer(pos_full, ADMIN);
        transfer::public_transfer(pos_band, ADMIN);
        pool::share(p);
        scenario.end();
    }

    #[test]
    fun donations_settle_into_lp_fees() {
        let mut scenario = ts::begin(ADMIN);
        let ctx = scenario.ctx();
        let mut l = ledger();
        let mut p = pool::new<COIN_A, COIN_B>(
            3000, false, 60, option::none(), 0, 0, 0, PRICE_1, ctx,
        );

        let mut pos = fund(
            &mut p, &mut l,
            i32::neg_from(FULL).bits(), i32::from(FULL).bits(),
            2000000000000, ctx,
        );

        swap(&mut p, &mut l, true, true, 5000000000);

        p.donate(
            balance::create_for_testing<COIN_A>(1000000),
            balance::create_for_testing<COIN_B>(2000000),
        );
        l.deposited_a = l.deposited_a + 1000000;
        l.deposited_b = l.deposited_b + 2000000;

        swap(&mut p, &mut l, false, true, 5000000000);
        swap(&mut p, &mut l, true, false, 2000000000);

        p.donate(
            balance::create_for_testing<COIN_A>(3000000),
            balance::create_for_testing<COIN_B>(0),
        );
        l.deposited_a = l.deposited_a + 3000000;

        swap(&mut p, &mut l, false, false, 1000000000);

        drain_position(&mut p, &mut l, &mut pos);

        // The sole LP recovers principal, swap fees AND both donations;
        // the ledger identity plus the dust bound proves the donations
        // were not stranded.
        check_final(&p, &l, 200);

        transfer::public_transfer(pos, ADMIN);
        pool::share(p);
        scenario.end();
    }
}
