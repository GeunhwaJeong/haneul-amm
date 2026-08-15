// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

module haneul_amm::math_tests {
    use haneul_amm::i128;
    use haneul_amm::i32;
    use haneul_amm::math_u128;
    use haneul_amm::math_u256;

    // === i32 ===

    #[test]
    fun i32_construction_and_bits() {
        assert!(i32::zero().bits() == 0);
        assert!(i32::from(1).bits() == 1);
        assert!(i32::neg_from(1).bits() == 0xFFFFFFFF);
        assert!(i32::neg_from(2).bits() == 0xFFFFFFFE);
        assert!(i32::from_bits(0xFFFFFFFF).abs_u32() == 1);
        assert!(i32::neg_from(0x80000000).bits() == 0x80000000);
        assert!(!i32::from(5).is_neg());
        assert!(i32::neg_from(5).is_neg());
        assert!(!i32::zero().is_neg());
    }

    #[test]
    fun i32_arithmetic() {
        let a = i32::from(100);
        let b = i32::neg_from(30);
        assert!(i32::eq(i32::add(a, b), i32::from(70)));
        assert!(i32::eq(i32::sub(a, b), i32::from(130)));
        assert!(i32::eq(i32::sub(b, a), i32::neg_from(130)));
        assert!(i32::eq(i32::add(b, b), i32::neg_from(60)));
        assert!(i32::eq(i32::neg(a), i32::neg_from(100)));
        assert!(i32::eq(i32::neg(b), i32::from(30)));
        assert!(i32::eq(i32::neg(i32::zero()), i32::zero()));
    }

    #[test]
    fun i32_ordering() {
        assert!(i32::lt(i32::neg_from(1), i32::zero()));
        assert!(i32::lt(i32::neg_from(100), i32::neg_from(1)));
        assert!(i32::lt(i32::zero(), i32::from(1)));
        assert!(i32::gt(i32::from(2), i32::neg_from(1000000)));
        assert!(i32::lte(i32::from(7), i32::from(7)));
        assert!(i32::gte(i32::neg_from(7), i32::neg_from(7)));
        assert!(i32::eq(i32::min(i32::neg_from(5), i32::from(3)), i32::neg_from(5)));
        assert!(i32::eq(i32::max(i32::neg_from(5), i32::from(3)), i32::from(3)));
    }

    #[test]
    fun i32_floor_division_rounds_toward_negative_infinity() {
        assert!(i32::eq(i32::from(7).div_floor_u32(2), i32::from(3)));
        assert!(i32::eq(i32::neg_from(7).div_floor_u32(2), i32::neg_from(4)));
        assert!(i32::eq(i32::neg_from(6).div_floor_u32(2), i32::neg_from(3)));
        assert!(i32::eq(i32::neg_from(1).div_floor_u32(256), i32::neg_from(1)));
        assert!(i32::eq(i32::from(255).div_floor_u32(256), i32::zero()));
    }

    #[test]
    fun i32_euclidean_mod() {
        assert!(i32::from(7).mod_u32(3) == 1);
        assert!(i32::neg_from(7).mod_u32(3) == 2);
        assert!(i32::neg_from(6).mod_u32(3) == 0);
        assert!(i32::neg_from(1).mod_u32(256) == 255);
    }

    #[test]
    fun i32_mul_u32() {
        assert!(i32::eq(i32::from(100).mul_u32(60), i32::from(6000)));
        assert!(i32::eq(i32::neg_from(100).mul_u32(60), i32::neg_from(6000)));
        assert!(i32::eq(i32::zero().mul_u32(999), i32::zero()));
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::i32::EOverflow)]
    fun i32_from_overflow_aborts() {
        i32::from(0x80000000);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::i32::EOverflow)]
    fun i32_add_overflow_aborts() {
        i32::add(i32::from(0x7FFFFFFF), i32::from(1));
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::i32::EOverflow)]
    fun i32_sub_underflow_aborts() {
        i32::sub(i32::neg_from(0x80000000), i32::from(1));
    }

    // === i128 ===

    #[test]
    fun i128_construction_and_arithmetic() {
        assert!(i128::zero().is_zero());
        assert!(i128::from(5).bits() == 5);
        assert!(i128::neg_from(1).bits() == 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
        assert!(i128::neg_from(7).abs_u128() == 7);
        let a = i128::from(1000);
        let b = i128::neg_from(400);
        assert!(i128::eq(i128::add(a, b), i128::from(600)));
        assert!(i128::eq(i128::sub(b, a), i128::neg_from(1400)));
        assert!(i128::eq(i128::neg(b), i128::from(400)));
        assert!(i128::neg_from(0).is_zero());
    }

    #[test]
    fun i128_min_magnitude() {
        let min = i128::neg_from(1 << 127);
        assert!(min.is_neg());
        assert!(min.abs_u128() == 1 << 127);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::i128::EOverflow)]
    fun i128_from_overflow_aborts() {
        i128::from(1 << 127);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::i128::EOverflow)]
    fun i128_neg_of_min_aborts() {
        i128::neg(i128::neg_from(1 << 127));
    }

    // === math_u128 ===

    #[test]
    fun u128_full_mul_and_mul_div() {
        let max = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        // (2^128 - 1)^2 = 2^256 - 2^129 + 1, top bits exercise u256.
        assert!(math_u128::full_mul(max, max) == (max as u256) * (max as u256));
        assert!(math_u128::mul_div_floor(10, 10, 3) == 33);
        assert!(math_u128::mul_div_ceil(10, 10, 3) == 34);
        assert!(math_u128::mul_div_floor(max, max, max) == max);
    }

    #[test]
    fun u128_wrapping_arithmetic() {
        let max = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        assert!(math_u128::wrapping_add(max, 1) == 0);
        assert!(math_u128::wrapping_add(max, max) == max - 1);
        assert!(math_u128::wrapping_sub(0, 1) == max);
        assert!(math_u128::wrapping_sub(5, 3) == 2);
        // The round-trip identity fee accounting relies on:
        // wrapping_sub(wrapping_add(a, d), a) == d.
        assert!(math_u128::wrapping_sub(math_u128::wrapping_add(max - 2, 7), max - 2) == 7);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::math_u128::EOverflow)]
    fun u128_mul_div_overflow_aborts() {
        let max = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        math_u128::mul_div_floor(max, max, 1);
    }

    // === math_u256 ===

    #[test]
    fun u256_div_round() {
        assert!(math_u256::div_round(10, 3, false) == 3);
        assert!(math_u256::div_round(10, 3, true) == 4);
        assert!(math_u256::div_round(9, 3, true) == 3);
        assert!(math_u256::div_round(0, 7, true) == 0);
    }

    #[test]
    fun u256_checked_shlw() {
        assert!(math_u256::checked_shlw(1) == 1 << 64);
        assert!(math_u256::checked_shlw((1 << 192) - 1) == ((1 << 192) - 1) << 64);
    }

    #[test]
    fun u256_bit_scans() {
        assert!(math_u256::msb(1) == 0);
        assert!(math_u256::msb(2) == 1);
        assert!(math_u256::msb(3) == 1);
        assert!(math_u256::msb(1 << 255) == 255);
        assert!(math_u256::msb((1 << 200) + 12345) == 200);
        assert!(math_u256::lsb(1) == 0);
        assert!(math_u256::lsb(1 << 255) == 255);
        assert!(math_u256::lsb(88) == 3); // 0x58 = 0101_1000
        assert!(math_u256::lsb((1 << 200) + (1 << 12)) == 12);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::math_u256::EShiftOverflow)]
    fun u256_shlw_overflow_aborts() {
        math_u256::checked_shlw(1 << 192);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::math_u256::EZeroInput)]
    fun u256_msb_zero_aborts() {
        math_u256::msb(0);
    }

    #[test]
    #[expected_failure(abort_code = haneul_amm::math_u256::EDivByZero)]
    fun u256_div_zero_aborts() {
        math_u256::div_round(1, 0, false);
    }
}
