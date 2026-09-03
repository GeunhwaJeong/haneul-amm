// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Signed 32-bit integers as two's complement over `u32`.
///
/// Move has no native signed integers. Tick indices need them, so this
/// module provides the minimal, fully checked arithmetic the AMM uses.
/// All operations abort on overflow; nothing wraps silently.
///
/// Representation: the raw `u32` holds the standard two's complement
/// bit pattern, so ordering is done by flipping the sign bit and values
/// round-trip losslessly through `bits`/`from_bits` (which is also how
/// ticks are passed through transaction arguments).
module haneul_amm::i32 {
    /// Result would not fit in a signed 32-bit integer.
    const EOverflow: u64 = 0;
    /// Division by zero.
    const EDivByZero: u64 = 1;

    /// Bit pattern of the minimum value, -2^31.
    const MIN_BITS: u32 = 0x8000_0000;
    /// Maximum positive value, 2^31 - 1.
    const MAX_MAGNITUDE_POS: u32 = 0x7FFF_FFFF;
    /// Low 32 bits, as a u64 mask for widened arithmetic.
    const MASK: u64 = 0xFFFF_FFFF;

    public struct I32 has copy, drop, store {
        bits: u32,
    }

    public fun zero(): I32 {
        I32 { bits: 0 }
    }

    /// Build a non-negative value.
    public fun from(v: u32): I32 {
        assert!(v <= MAX_MAGNITUDE_POS, EOverflow);
        I32 { bits: v }
    }

    /// Build `-v`. `v` may be up to 2^31 (the magnitude of the minimum).
    public fun neg_from(v: u32): I32 {
        assert!(v <= MIN_BITS, EOverflow);
        if (v == 0) return I32 { bits: 0 };
        I32 { bits: (((MASK + 1) - (v as u64)) & MASK) as u32 }
    }

    /// Reinterpret a raw two's complement bit pattern.
    public fun from_bits(bits: u32): I32 {
        I32 { bits }
    }

    /// The raw two's complement bit pattern.
    public fun bits(self: I32): u32 {
        self.bits
    }

    public fun is_neg(self: I32): bool {
        self.bits >= MIN_BITS
    }

    /// Absolute value as an unsigned magnitude (total: |MIN| = 2^31 fits).
    public fun abs_u32(self: I32): u32 {
        if (self.is_neg()) {
            ((((MASK + 1) - (self.bits as u64)) & MASK) as u32)
        } else {
            self.bits
        }
    }

    public fun neg(self: I32): I32 {
        if (self.is_neg()) {
            from(self.abs_u32())
        } else {
            neg_from(self.bits)
        }
    }

    public fun add(a: I32, b: I32): I32 {
        let r = I32 { bits: (((a.bits as u64) + (b.bits as u64)) & MASK) as u32 };
        // Overflow iff both operands share a sign and the result does not.
        assert!(a.is_neg() != b.is_neg() || r.is_neg() == a.is_neg(), EOverflow);
        r
    }

    public fun sub(a: I32, b: I32): I32 {
        let r = I32 {
            bits: (((a.bits as u64) + (MASK + 1) - (b.bits as u64)) & MASK) as u32,
        };
        // Overflow iff operands have different signs and the result has b's sign.
        assert!(a.is_neg() == b.is_neg() || r.is_neg() == a.is_neg(), EOverflow);
        r
    }

    public fun eq(a: I32, b: I32): bool {
        a.bits == b.bits
    }

    public fun lt(a: I32, b: I32): bool {
        // Flipping the sign bit maps two's complement to unsigned order.
        (a.bits ^ MIN_BITS) < (b.bits ^ MIN_BITS)
    }

    public fun lte(a: I32, b: I32): bool {
        (a.bits ^ MIN_BITS) <= (b.bits ^ MIN_BITS)
    }

    public fun gt(a: I32, b: I32): bool {
        (a.bits ^ MIN_BITS) > (b.bits ^ MIN_BITS)
    }

    public fun gte(a: I32, b: I32): bool {
        (a.bits ^ MIN_BITS) >= (b.bits ^ MIN_BITS)
    }

    /// Multiply by an unsigned factor, preserving sign.
    public fun mul_u32(a: I32, b: u32): I32 {
        let m = (a.abs_u32() as u64) * (b as u64);
        if (a.is_neg()) {
            assert!(m <= (MIN_BITS as u64), EOverflow);
            neg_from((m as u32))
        } else {
            assert!(m <= (MAX_MAGNITUDE_POS as u64), EOverflow);
            from((m as u32))
        }
    }

    /// Floor division by a positive divisor (rounds toward negative
    /// infinity, e.g. -5 / 2 = -3). This is the rounding tick
    /// compression requires so that negative ticks land on the correct
    /// spacing boundary.
    public fun div_floor_u32(a: I32, b: u32): I32 {
        assert!(b > 0, EDivByZero);
        if (a.is_neg()) {
            let m = a.abs_u32();
            // ceil(m / b), negated, equals floor(-m / b).
            let q = (m / b) + (if (m % b > 0) 1 else 0);
            neg_from(q)
        } else {
            from(a.bits / b)
        }
    }

    /// Euclidean remainder against a positive divisor; always in [0, b).
    /// A tick is aligned to its spacing iff this is zero.
    public fun mod_u32(a: I32, b: u32): u32 {
        assert!(b > 0, EDivByZero);
        let r = a.abs_u32() % b;
        if (a.is_neg() && r > 0) {
            b - r
        } else {
            r
        }
    }

    public fun min(a: I32, b: I32): I32 {
        if (lt(a, b)) a else b
    }

    public fun max(a: I32, b: I32): I32 {
        if (gt(a, b)) a else b
    }
}
