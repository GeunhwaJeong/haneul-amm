// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Converts token amounts into liquidity for a given price range.
///
/// The core prices liquidity; users hold tokens. This library answers
/// the inverse question the core deliberately does not: "given these
/// token amounts and this range, how much liquidity can I mint?"
///
/// All results round down, so the liquidity computed here never
/// requires more principal than the amounts it was computed from,
/// up to one unit of counter-rounding that `liquidity` compensates
/// for explicitly.
module haneul_amm_periphery::liquidity_amounts {
    /// Computed liquidity does not fit in u128.
    const ELiquidityOverflow: u64 = 0;
    /// A range must span at least one price unit.
    const EEmptyRange: u64 = 1;

    const MAX_U128: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /// Liquidity purchasable with `amount_a` of token A between two
    /// prices: amount_a * (pa * pb / 2^64) / (pb - pa).
    public fun liquidity_for_amount_a(
        sqrt_price_0: u128,
        sqrt_price_1: u128,
        amount_a: u64,
    ): u128 {
        let (lo, hi) = sort(sqrt_price_0, sqrt_price_1);
        assert!(lo < hi, EEmptyRange);
        let intermediate = haneul_amm::math_u128::full_mul(lo, hi) >> 64;
        let l = (amount_a as u256) * intermediate / ((hi - lo) as u256);
        assert!(l <= MAX_U128, ELiquidityOverflow);
        (l as u128)
    }

    /// Liquidity purchasable with `amount_b` of token B between two
    /// prices: amount_b * 2^64 / (pb - pa).
    public fun liquidity_for_amount_b(
        sqrt_price_0: u128,
        sqrt_price_1: u128,
        amount_b: u64,
    ): u128 {
        let (lo, hi) = sort(sqrt_price_0, sqrt_price_1);
        assert!(lo < hi, EEmptyRange);
        let l = ((amount_b as u256) << 64) / ((hi - lo) as u256);
        assert!(l <= MAX_U128, ELiquidityOverflow);
        (l as u128)
    }

    /// Maximum liquidity purchasable with both amounts at the current
    /// price. Below the range only A buys liquidity, above it only B;
    /// inside, the scarcer side binds.
    public fun liquidity_for_amounts(
        sqrt_price_current: u128,
        sqrt_price_0: u128,
        sqrt_price_1: u128,
        amount_a: u64,
        amount_b: u64,
    ): u128 {
        let (lo, hi) = sort(sqrt_price_0, sqrt_price_1);
        if (sqrt_price_current <= lo) {
            liquidity_for_amount_a(lo, hi, amount_a)
        } else if (sqrt_price_current < hi) {
            let l_a = liquidity_for_amount_a(sqrt_price_current, hi, amount_a);
            let l_b = liquidity_for_amount_b(lo, sqrt_price_current, amount_b);
            if (l_a < l_b) l_a else l_b
        } else {
            liquidity_for_amount_b(lo, hi, amount_b)
        }
    }

    fun sort(a: u128, b: u128): (u128, u128) {
        if (a <= b) (a, b) else (b, a)
    }
}
