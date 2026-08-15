// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Conversions between tick indices and square-root prices.
///
/// A pool's price is tracked as sqrt(B per A) in Q32.64 fixed point
/// (a `u128` whose low 64 bits are fractional). Ticks discretize price
/// space in steps of 1.0001: tick t corresponds to sqrt(1.0001^t) * 2^64.
///
/// The supported tick range is [-443636, 443636], i.e. prices between
/// 2^-64 and 2^64. That is a 3.4e38-fold price span, unbounded for any
/// real market, and it keeps every intermediate product in this package
/// inside native `u256` arithmetic with no precision loss.
///
/// `get_sqrt_price_at_tick` evaluates the power by multiplying, for each
/// set bit i of |tick|, a precomputed Q128.128 constant equal to
/// 1/sqrt(1.0001)^(2^i), then inverting for positive ticks and rounding
/// up into Q32.64. Rounding up makes the two conversions consistent:
/// `get_tick_at_sqrt_price(get_sqrt_price_at_tick(t)) == t` for every
/// valid t (verified exhaustively in tests against an independent
/// big-integer reference).
///
/// `get_tick_at_sqrt_price` computes log_1.0001 via a base-2 logarithm:
/// the integer part comes from the position of the most significant
/// bit, fourteen squaring steps extract fractional bits, and the fixed
/// constant 255738958999603826347141 rescales log2 to log_1.0001 in
/// Q22.128. The two error-bound constants bracket the approximation
/// error; when the bracket spans two ticks, an exact forward evaluation
/// picks the correct one, so the result is exact, not approximate.
module haneul_amm::tick_math {
    use haneul_amm::i32::{Self, I32};

    /// Tick outside [-MAX_TICK, MAX_TICK].
    const EInvalidTick: u64 = 0;
    /// Square-root price outside [MIN_SQRT_PRICE, MAX_SQRT_PRICE).
    const EInvalidSqrtPrice: u64 = 1;

    /// Magnitude of the largest valid tick: log_1.0001(2^128) rounded down.
    const MAX_TICK_MAGNITUDE: u32 = 443636;

    /// sqrt price at tick -443636; the smallest representable pool price.
    const MIN_SQRT_PRICE_X64: u128 = 4295048017;
    /// sqrt price at tick 443636; prices must stay strictly below this.
    const MAX_SQRT_PRICE_X64: u128 = 79226673515401279992447579062;

    /// log_1.0001(x) = log2(x) * this constant, in Q22.128 out of Q.128 in.
    const LOG_SCALE: u256 = 255738958999603826347141;
    /// Upper bound of the log approximation error (subtracted bound).
    const ERR_LOW: u256 = 3402992956809132418596140100660247210;
    /// Lower bound magnitude of the log approximation error (added bound).
    const ERR_HIGH: u256 = 291339464771989622907027621153398088495;

    const MAX_U256: u256 =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    public fun max_tick(): I32 {
        i32::from(MAX_TICK_MAGNITUDE)
    }

    public fun min_tick(): I32 {
        i32::neg_from(MAX_TICK_MAGNITUDE)
    }

    public fun min_sqrt_price(): u128 {
        MIN_SQRT_PRICE_X64
    }

    public fun max_sqrt_price(): u128 {
        MAX_SQRT_PRICE_X64
    }

    /// Largest tick that is a multiple of `tick_spacing`.
    public fun max_usable_tick(tick_spacing: u32): I32 {
        i32::from((MAX_TICK_MAGNITUDE / tick_spacing) * tick_spacing)
    }

    /// Smallest tick that is a multiple of `tick_spacing`.
    public fun min_usable_tick(tick_spacing: u32): I32 {
        i32::neg_from((MAX_TICK_MAGNITUDE / tick_spacing) * tick_spacing)
    }

    /// sqrt(1.0001^tick) in Q32.64. Aborts outside the valid tick range.
    public fun get_sqrt_price_at_tick(tick: I32): u128 {
        let abs_tick = tick.abs_u32();
        assert!(abs_tick <= MAX_TICK_MAGNITUDE, EInvalidTick);

        // Q128.128 accumulator; each constant is 1/sqrt(1.0001)^(2^i).
        let mut price: u256 = if (abs_tick & 0x1 != 0) {
            0xFFFCB933BD6FAD37AA2D162D1A594001
        } else {
            1 << 128
        };
        if (abs_tick & 0x2 != 0)
            price = (price * 0xFFF97272373D413259A46990580E213A) >> 128;
        if (abs_tick & 0x4 != 0)
            price = (price * 0xFFF2E50F5F656932EF12357CF3C7FDCC) >> 128;
        if (abs_tick & 0x8 != 0)
            price = (price * 0xFFE5CACA7E10E4E61C3624EAA0941CD0) >> 128;
        if (abs_tick & 0x10 != 0)
            price = (price * 0xFFCB9843D60F6159C9DB58835C926644) >> 128;
        if (abs_tick & 0x20 != 0)
            price = (price * 0xFF973B41FA98C081472E6896DFB254C0) >> 128;
        if (abs_tick & 0x40 != 0)
            price = (price * 0xFF2EA16466C96A3843EC78B326B52861) >> 128;
        if (abs_tick & 0x80 != 0)
            price = (price * 0xFE5DEE046A99A2A811C461F1969C3053) >> 128;
        if (abs_tick & 0x100 != 0)
            price = (price * 0xFCBE86C7900A88AEDCFFC83B479AA3A4) >> 128;
        if (abs_tick & 0x200 != 0)
            price = (price * 0xF987A7253AC413176F2B074CF7815E54) >> 128;
        if (abs_tick & 0x400 != 0)
            price = (price * 0xF3392B0822B70005940C7A398E4B70F3) >> 128;
        if (abs_tick & 0x800 != 0)
            price = (price * 0xE7159475A2C29B7443B29C7FA6E889D9) >> 128;
        if (abs_tick & 0x1000 != 0)
            price = (price * 0xD097F3BDFD2022B8845AD8F792AA5825) >> 128;
        if (abs_tick & 0x2000 != 0)
            price = (price * 0xA9F746462D870FDF8A65DC1F90E061E5) >> 128;
        if (abs_tick & 0x4000 != 0)
            price = (price * 0x70D869A156D2A1B890BB3DF62BAF32F7) >> 128;
        if (abs_tick & 0x8000 != 0)
            price = (price * 0x31BE135F97D08FD981231505542FCFA6) >> 128;
        if (abs_tick & 0x10000 != 0)
            price = (price * 0x9AA508B5B7A84E1C677DE54F3E99BC9) >> 128;
        if (abs_tick & 0x20000 != 0)
            price = (price * 0x5D6AF8DEDB81196699C329225EE604) >> 128;
        if (abs_tick & 0x40000 != 0)
            price = (price * 0x2216E584F5FA1EA926041BEDFE98) >> 128;

        // The constants encode negative powers; invert for positive ticks.
        if (!tick.is_neg() && abs_tick != 0) {
            price = MAX_U256 / price;
        };

        // Q128.128 -> Q32.64, rounding up so that converting the result
        // back to a tick with the floor-based log recovers exactly `tick`.
        (((price + ((1 << 64) - 1)) >> 64) as u128)
    }

    /// Largest tick t with get_sqrt_price_at_tick(t) <= sqrt_price.
    /// Aborts unless MIN_SQRT_PRICE <= sqrt_price < MAX_SQRT_PRICE
    /// (the maximum itself is unreachable by swaps, matching the strict
    /// upper bound).
    public fun get_tick_at_sqrt_price(sqrt_price_x64: u128): I32 {
        assert!(
            sqrt_price_x64 >= MIN_SQRT_PRICE_X64 && sqrt_price_x64 < MAX_SQRT_PRICE_X64,
            EInvalidSqrtPrice,
        );

        // Normalize into Q128.128 so that 1.0 sits at bit 128.
        let price: u256 = (sqrt_price_x64 as u256) << 64;
        let m = haneul_amm::math_u256::msb(price);

        // r is price scaled into [2^127, 2^128): a mantissa for the
        // fractional-bit extraction below.
        let mut r = if (m >= 128) {
            price >> ((m - 127) as u8)
        } else {
            price << ((127 - m) as u8)
        };

        // log2(price) in signed Q64.64, tracked as sign + magnitude
        // because the value is negative below tick 0.
        let integer_part = m; // log2 integer part is m - 128
        let neg = integer_part < 128;
        let mut log2_mag: u256 = if (neg) {
            ((128 - (integer_part as u16)) as u256) << 64
        } else {
            (((integer_part as u16) - 128) as u256) << 64
        };

        // Extract 14 fractional bits: squaring doubles the log, and the
        // carry out of the mantissa range is the next bit. For negative
        // logs the magnitude accumulates the complement, so fractional
        // bits are subtracted rather than or-ed in.
        let mut shift: u8 = 63;
        while (shift >= 50) {
            r = (r * r) >> 127;
            let f = ((r >> 128) as u8);
            if (f == 1) {
                if (neg) {
                    log2_mag = log2_mag - (1 << shift);
                } else {
                    log2_mag = log2_mag + (1 << shift);
                };
                r = r >> 1;
            };
            shift = shift - 1;
        };

        // Rescale to log_1.0001 in Q22.128 and bracket the true tick.
        let scaled = log2_mag * LOG_SCALE;
        let tick_low = shr128_floor_signed(neg, scaled, true, ERR_LOW);
        let tick_high = shr128_floor_signed(neg, scaled, false, ERR_HIGH);

        if (i32::eq(tick_low, tick_high)) {
            tick_low
        } else if (get_sqrt_price_at_tick(tick_high) <= sqrt_price_x64) {
            tick_high
        } else {
            tick_low
        }
    }

    /// floor((a + b) / 2^128) where a = (a_neg ? -a_mag : a_mag) and
    /// b = (b_neg ? -b_mag : b_mag), returned as a tick-sized I32.
    /// Floor of a negative quotient rounds away from zero, i.e. it is
    /// the negated ceiling of the magnitude quotient.
    fun shr128_floor_signed(a_neg: bool, a_mag: u256, b_neg: bool, b_mag: u256): I32 {
        // Combine the two signed terms into one sign + magnitude.
        let (neg, mag) = if (a_neg == b_neg) {
            (a_neg, a_mag + b_mag)
        } else if (a_mag >= b_mag) {
            (a_neg, a_mag - b_mag)
        } else {
            (b_neg, b_mag - a_mag)
        };
        if (neg) {
            let q = (mag + ((1 << 128) - 1)) >> 128; // ceil(mag / 2^128)
            i32::neg_from((q as u32))
        } else {
            i32::from(((mag >> 128) as u32))
        }
    }
}
