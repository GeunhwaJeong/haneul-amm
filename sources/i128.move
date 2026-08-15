// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Signed 128-bit integers as two's complement over `u128`.
///
/// Used for signed liquidity quantities: a liquidity change is positive
/// when adding and negative when removing, and the net liquidity a tick
/// contributes when crossed left-to-right is signed by construction.
/// Arithmetic is widened through `u256`, so every operation is checked
/// and aborts on overflow.
module haneul_amm::i128 {
    /// Result would not fit in a signed 128-bit integer.
    const EOverflow: u64 = 0;

    /// Bit pattern of the minimum value, -2^127.
    const MIN_BITS: u128 = 1 << 127;
    /// Maximum positive value, 2^127 - 1.
    const MAX_MAGNITUDE_POS: u128 = (1 << 127) - 1;
    /// Low 128 bits, as a u256 mask for widened arithmetic.
    const MASK: u256 = (1 << 128) - 1;

    public struct I128 has copy, drop, store {
        bits: u128,
    }

    public fun zero(): I128 {
        I128 { bits: 0 }
    }

    /// Build a non-negative value.
    public fun from(v: u128): I128 {
        assert!(v <= MAX_MAGNITUDE_POS, EOverflow);
        I128 { bits: v }
    }

    /// Build `-v`. `v` may be up to 2^127 (the magnitude of the minimum).
    public fun neg_from(v: u128): I128 {
        assert!(v <= MIN_BITS, EOverflow);
        if (v == 0) return I128 { bits: 0 };
        I128 { bits: (((MASK + 1) - (v as u256)) & MASK) as u128 }
    }

    public fun from_bits(bits: u128): I128 {
        I128 { bits }
    }

    public fun bits(self: I128): u128 {
        self.bits
    }

    public fun is_neg(self: I128): bool {
        self.bits >= MIN_BITS
    }

    public fun is_zero(self: I128): bool {
        self.bits == 0
    }

    /// Absolute value as an unsigned magnitude (total: |MIN| = 2^127 fits).
    public fun abs_u128(self: I128): u128 {
        if (self.is_neg()) {
            ((((MASK + 1) - (self.bits as u256)) & MASK) as u128)
        } else {
            self.bits
        }
    }

    public fun neg(self: I128): I128 {
        if (self.is_neg()) {
            from(self.abs_u128())
        } else {
            neg_from(self.bits)
        }
    }

    public fun add(a: I128, b: I128): I128 {
        let r = I128 { bits: (((a.bits as u256) + (b.bits as u256)) & MASK) as u128 };
        // Overflow iff both operands share a sign and the result does not.
        assert!(a.is_neg() != b.is_neg() || r.is_neg() == a.is_neg(), EOverflow);
        r
    }

    public fun sub(a: I128, b: I128): I128 {
        let r = I128 {
            bits: (((a.bits as u256) + (MASK + 1) - (b.bits as u256)) & MASK) as u128,
        };
        // Overflow iff operands have different signs and the result has b's sign.
        assert!(a.is_neg() == b.is_neg() || r.is_neg() == a.is_neg(), EOverflow);
        r
    }

    public fun eq(a: I128, b: I128): bool {
        a.bits == b.bits
    }
}
