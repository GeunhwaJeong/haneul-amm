// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Widening and wrapping arithmetic on `u128`.
///
/// Two distinct needs live here:
///  - Full-width products. A `u128 * u128` product always fits in
///    `u256`, so multiply-then-divide sequences never lose precision.
///  - Wrapping addition/subtraction for fee-growth accumulators. Fee
///    growth per unit of liquidity is a monotone counter that is allowed
///    to overflow by design: positions only ever consume *differences*
///    of snapshots taken over the position's lifetime, and differences
///    remain correct under modular arithmetic.
module haneul_amm::math_u128 {
    /// Result would not fit in the return type.
    const EOverflow: u64 = 0;

    const MASK: u256 = (1 << 128) - 1;
    const MAX_U128: u256 = (1 << 128) - 1;

    /// Exact 256-bit product of two 128-bit values. Never aborts.
    public fun full_mul(a: u128, b: u128): u256 {
        (a as u256) * (b as u256)
    }

    /// floor(a * b / d) computed at full precision. Aborts if the result
    /// does not fit in a u128 or if `d` is zero.
    public fun mul_div_floor(a: u128, b: u128, d: u128): u128 {
        let r = full_mul(a, b) / (d as u256);
        assert!(r <= MAX_U128, EOverflow);
        (r as u128)
    }

    /// ceil(a * b / d) computed at full precision. Aborts if the result
    /// does not fit in a u128 or if `d` is zero.
    public fun mul_div_ceil(a: u128, b: u128, d: u128): u128 {
        let n = full_mul(a, b);
        let r = n / (d as u256) + (if (n % (d as u256) > 0) 1 else 0);
        assert!(r <= MAX_U128, EOverflow);
        (r as u128)
    }

    /// (a + b) mod 2^128. Intentional wrap-around; see module doc.
    public fun wrapping_add(a: u128, b: u128): u128 {
        ((((a as u256) + (b as u256)) & MASK) as u128)
    }

    /// (a - b) mod 2^128. Intentional wrap-around; see module doc.
    public fun wrapping_sub(a: u128, b: u128): u128 {
        ((((a as u256) + (MASK + 1) - (b as u256)) & MASK) as u128)
    }
}
