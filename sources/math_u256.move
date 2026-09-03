// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// `u256` helpers: directed-rounding division, checked word shifts, and
/// bit scans.
///
/// Every quantity the pool computes fits in `u256` by construction (see
/// `sqrt_price_math` for the domain argument), so these helpers are the
/// widest arithmetic the package ever needs.
module haneul_amm::math_u256 {
    /// Division by zero.
    const EDivByZero: u64 = 0;
    /// Left shift would discard set bits.
    const EShiftOverflow: u64 = 1;
    /// Bit scan of zero is undefined.
    const EZeroInput: u64 = 2;

    const MAX_U256: u256 =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /// floor or ceil of `n / d` depending on `round_up`.
    public fun div_round(n: u256, d: u256, round_up: bool): u256 {
        assert!(d > 0, EDivByZero);
        let q = n / d;
        if (round_up && n % d > 0) {
            q + 1
        } else {
            q
        }
    }

    /// `n << 64`, aborting if any of the top 64 bits are set. Used to
    /// scale full-width products by the price radix without silently
    /// truncating.
    public fun checked_shlw(n: u256): u256 {
        assert!(n < (1 << 192), EShiftOverflow);
        n << 64
    }

    /// Index of the most significant set bit (0-based, so msb(1) == 0
    /// and msb(2^255) == 255). Aborts on zero.
    public fun msb(x: u256): u8 {
        assert!(x > 0, EZeroInput);
        let mut x = x;
        let mut r: u8 = 0;
        if (x >= (1 << 128)) { x = x >> 128; r = r + 128; };
        if (x >= (1 << 64)) { x = x >> 64; r = r + 64; };
        if (x >= (1 << 32)) { x = x >> 32; r = r + 32; };
        if (x >= (1 << 16)) { x = x >> 16; r = r + 16; };
        if (x >= (1 << 8)) { x = x >> 8; r = r + 8; };
        if (x >= (1 << 4)) { x = x >> 4; r = r + 4; };
        if (x >= (1 << 2)) { x = x >> 2; r = r + 2; };
        if (x >= 2) { r = r + 1; };
        r
    }

    /// Index of the least significant set bit. Aborts on zero.
    public fun lsb(x: u256): u8 {
        assert!(x > 0, EZeroInput);
        // x & -x isolates the lowest set bit. -x mod 2^256 is written
        // as (MAX - x) + 1, which cannot overflow because x > 0.
        let neg = (MAX_U256 - x) + 1;
        msb(x & neg)
    }
}
