// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Price movement and token amounts as functions of liquidity.
///
/// Within one tick range, the pool behaves as a constant-product curve
/// with virtual reserves. With sqrt price P (Q32.64) and liquidity L:
///
///   amount_a between prices Pa < Pb:  L * (Pb - Pa) / (Pb * Pa) * 2^64
///   amount_b between prices Pa < Pb:  L * (Pb - Pa) / 2^64
///
/// Rounding is always directed in the pool's favor: amounts a swapper
/// or LP must pay round up, amounts paid out round down. The pool can
/// therefore never be under-collateralized by rounding drift.
///
/// Domain: token amounts are u64 (the coin balance width), liquidity is
/// u128, prices are u128. Every product below is bounded by 2^256:
///   - L * price       < 2^128 * 2^128 = 2^256 (exact via full_mul)
///   - (L * dP) << 64 requires L * dP < 2^192. Aggregate in-range
///     liquidity is not bounded tightly enough to rule that out (a
///     single token-A position priced near the tick ceiling can exceed
///     it), so the functions below never rely on it: the price-movement
///     formula falls back to an equivalent that divides first, and the
///     `*_wide` amount functions report "does not fit in u64" instead
///     of aborting, so a swap can compare against its budget and stop
///     inside the range rather than fail on a quantity it would never
///     have moved.
module haneul_amm::sqrt_price_math {
    use haneul_amm::math_u128;
    use haneul_amm::math_u256;

    /// Price or liquidity input was zero.
    const EInvalidInput: u64 = 0;
    /// The requested output exceeds what the available liquidity can
    /// provide in this direction.
    const ENotEnoughLiquidity: u64 = 1;
    /// Computed price left the representable range.
    const EPriceOverflow: u64 = 2;
    /// Computed token amount does not fit in a coin balance (u64).
    const EAmountOverflow: u64 = 3;

    const MAX_U64: u256 = 0xFFFFFFFFFFFFFFFF;
    const MAX_U128: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    /// Sentinel returned by `get_amount_a_delta_wide` when the amount
    /// provably exceeds u64: the smallest value that fails a u64 fit.
    const DOES_NOT_FIT_U64: u256 = 1 << 64;

    /// Next sqrt price after adding (`add = true`) or removing amount_a
    /// of token A to/from the virtual reserves. Adding A pushes the
    /// price down; removing pushes it up. Rounds up in both cases so the
    /// price moves no further than the exact-math price.
    ///
    /// Formula: L * P * 2^64 / (L * 2^64 +- amount * P), full precision.
    public fun next_sqrt_price_from_amount_a_rounding_up(
        sqrt_price_x64: u128,
        liquidity: u128,
        amount: u64,
        add: bool,
    ): u128 {
        if (amount == 0) return sqrt_price_x64;
        let liquidity_shl = (liquidity as u256) << 64;
        let product = (amount as u256) * (sqrt_price_x64 as u256);
        let lp = math_u128::full_mul(liquidity, sqrt_price_x64);

        let r = if (lp < (1 << 192)) {
            // Full-precision form: one division, exact numerator.
            let numerator = lp << 64;
            let denominator = if (add) {
                liquidity_shl + product
            } else {
                // Removing A: price rises. The virtual reserve of A
                // must stay positive after removal.
                assert!(liquidity_shl > product, ENotEnoughLiquidity);
                liquidity_shl - product
            };
            math_u256::div_round(numerator, denominator, true)
        } else {
            // L * P would not fit, so divide first: P' = L / (L / P +- a)
            // in reserve terms. The reserve L * 2^64 / P is carried
            // with 63 extra fractional bits (L < 2^128, so L << 127
            // fits), which makes the flooring error below 2^-63 of one
            // unit of `amount`: indistinguishable from the exact form
            // in practice, and still never below it, so rounding stays
            // in the pool's favor.
            let scaled = (liquidity as u256) << 127;
            let reserve_a = scaled / (sqrt_price_x64 as u256);
            let amount_scaled = (amount as u256) << 63;
            let denominator = if (add) {
                reserve_a + amount_scaled
            } else {
                assert!(reserve_a > amount_scaled, ENotEnoughLiquidity);
                reserve_a - amount_scaled
            };
            math_u256::div_round(scaled, denominator, true)
        };
        assert!(r <= MAX_U128, EPriceOverflow);
        (r as u128)
    }

    /// Next sqrt price after adding or removing amount_b of token B.
    /// Adding B pushes the price up; removing pushes it down. Rounds
    /// down (the price moves no further than the exact-math price:
    /// the delta added is floored, the delta subtracted is ceiled).
    ///
    /// Formula: P +- amount * 2^64 / L, full precision.
    public fun next_sqrt_price_from_amount_b_rounding_down(
        sqrt_price_x64: u128,
        liquidity: u128,
        amount: u64,
        add: bool,
    ): u128 {
        let numerator = (amount as u256) << 64;
        if (add) {
            let quotient = numerator / (liquidity as u256);
            let r = (sqrt_price_x64 as u256) + quotient;
            assert!(r <= MAX_U128, EPriceOverflow);
            (r as u128)
        } else {
            let quotient = math_u256::div_round(numerator, (liquidity as u256), true);
            assert!((sqrt_price_x64 as u256) > quotient, ENotEnoughLiquidity);
            sqrt_price_x64 - (quotient as u128)
        }
    }

    /// Next sqrt price given an exact input amount of the appropriate
    /// token for the swap direction. `a_to_b = true` means token A goes
    /// in and the price falls.
    public fun next_sqrt_price_from_input(
        sqrt_price_x64: u128,
        liquidity: u128,
        amount_in: u64,
        a_to_b: bool,
    ): u128 {
        assert!(sqrt_price_x64 > 0 && liquidity > 0, EInvalidInput);
        if (a_to_b) {
            next_sqrt_price_from_amount_a_rounding_up(sqrt_price_x64, liquidity, amount_in, true)
        } else {
            next_sqrt_price_from_amount_b_rounding_down(
                sqrt_price_x64,
                liquidity,
                amount_in,
                true,
            )
        }
    }

    /// Next sqrt price given an exact output amount. `a_to_b = true`
    /// means token B comes out and the price falls.
    public fun next_sqrt_price_from_output(
        sqrt_price_x64: u128,
        liquidity: u128,
        amount_out: u64,
        a_to_b: bool,
    ): u128 {
        assert!(sqrt_price_x64 > 0 && liquidity > 0, EInvalidInput);
        if (a_to_b) {
            next_sqrt_price_from_amount_b_rounding_down(
                sqrt_price_x64,
                liquidity,
                amount_out,
                false,
            )
        } else {
            next_sqrt_price_from_amount_a_rounding_up(
                sqrt_price_x64,
                liquidity,
                amount_out,
                false,
            )
        }
    }

    /// Amount of token A held between two prices at the given liquidity.
    /// Price argument order does not matter. Aborts if the amount does
    /// not fit a coin balance.
    public fun get_amount_a_delta(
        sqrt_price_0: u128,
        sqrt_price_1: u128,
        liquidity: u128,
        round_up: bool,
    ): u64 {
        let r = get_amount_a_delta_wide(sqrt_price_0, sqrt_price_1, liquidity, round_up);
        assert!(r <= MAX_U64, EAmountOverflow);
        (r as u64)
    }

    /// Amount of token B held between two prices at the given liquidity.
    /// Price argument order does not matter. Aborts if the amount does
    /// not fit a coin balance.
    public fun get_amount_b_delta(
        sqrt_price_0: u128,
        sqrt_price_1: u128,
        liquidity: u128,
        round_up: bool,
    ): u64 {
        let r = get_amount_b_delta_wide(sqrt_price_0, sqrt_price_1, liquidity, round_up);
        assert!(r <= MAX_U64, EAmountOverflow);
        (r as u64)
    }

    /// `get_amount_a_delta` without the coin-width abort. The result is
    /// exact whenever it fits in u64. When the true amount is at least
    /// 2^64 the function may return any value >= 2^64 rather than the
    /// exact one; callers compare against u64 budgets, and a budget can
    /// never cover such an amount, so the exact figure is never needed.
    public fun get_amount_a_delta_wide(
        sqrt_price_0: u128,
        sqrt_price_1: u128,
        liquidity: u128,
        round_up: bool,
    ): u256 {
        let (lo, hi) = sort(sqrt_price_0, sqrt_price_1);
        assert!(lo > 0, EInvalidInput);
        if (liquidity == 0 || lo == hi) return 0;

        // L * (hi - lo) * 2^64 / (hi * lo), rounded once in the caller's
        // direction (a single full-precision division, so no compounded
        // rounding error).
        let scaled = math_u128::full_mul(liquidity, hi - lo);
        if (scaled >= (1 << 192)) {
            // The shift would overflow. Since hi * lo < 2^192, the true
            // quotient is at least scaled * 2^64 / 2^192 >= 2^64, so
            // reporting "does not fit" is exact enough.
            return DOES_NOT_FIT_U64
        };
        let numerator = scaled << 64;
        let denominator = math_u128::full_mul(hi, lo);
        math_u256::div_round(numerator, denominator, round_up)
    }

    /// `get_amount_b_delta` without the coin-width abort; always exact
    /// (the product fits in u256 by construction).
    public fun get_amount_b_delta_wide(
        sqrt_price_0: u128,
        sqrt_price_1: u128,
        liquidity: u128,
        round_up: bool,
    ): u256 {
        let (lo, hi) = sort(sqrt_price_0, sqrt_price_1);
        if (liquidity == 0 || lo == hi) return 0;

        // L * (hi - lo) / 2^64.
        let product = math_u128::full_mul(liquidity, hi - lo);
        math_u256::div_round(product, 1 << 64, round_up)
    }

    fun sort(a: u128, b: u128): (u128, u128) {
        if (a <= b) (a, b) else (b, a)
    }
}
