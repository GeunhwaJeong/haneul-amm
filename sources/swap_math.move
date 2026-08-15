// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// One step of a swap: how far the price moves inside a single tick
/// range, and what amounts and fees that movement produces.
///
/// The pool's swap loop calls this once per tick range crossed. Each
/// step swaps up to the target price (the nearer of the next
/// initialized tick and the caller's price limit), or less if the
/// remaining amount runs out first.
///
/// Fees are taken from the input token. For exact-input swaps the fee
/// comes out of the remaining budget before computing price movement;
/// if the step exhausts the budget, whatever the price movement did not
/// consume becomes the fee, so input + fee never exceeds the budget.
module haneul_amm::swap_math {
    use haneul_amm::sqrt_price_math;

    /// The whole fee scale: 1_000_000 pips = 100%. A pip here is a
    /// hundredth of a basis point.
    const FEE_SCALE: u64 = 1_000_000;

    /// Fee of 100% makes exact-output swaps impossible.
    const EFeeConsumesEverything: u64 = 0;

    public fun fee_scale(): u64 {
        FEE_SCALE
    }

    /// The price a step may move to: the tick boundary price unless the
    /// caller's limit is nearer in the direction of travel.
    public fun get_target_sqrt_price(
        a_to_b: bool,
        next_tick_sqrt_price: u128,
        sqrt_price_limit: u128,
    ): u128 {
        if (a_to_b) {
            // Price falls; do not fall below the limit.
            if (next_tick_sqrt_price < sqrt_price_limit) {
                sqrt_price_limit
            } else {
                next_tick_sqrt_price
            }
        } else {
            // Price rises; do not rise above the limit.
            if (next_tick_sqrt_price > sqrt_price_limit) {
                sqrt_price_limit
            } else {
                next_tick_sqrt_price
            }
        }
    }

    /// Compute one swap step.
    ///
    /// - `amount_remaining`: budget left; input tokens if `exact_in`,
    ///   otherwise output tokens still owed.
    /// - `fee_pips`: total swap fee for this pool and direction.
    ///
    /// Returns (next_sqrt_price, amount_in, amount_out, fee_amount).
    /// `amount_in` excludes the fee; the swapper pays amount_in + fee.
    public fun compute_swap_step(
        sqrt_price_current: u128,
        sqrt_price_target: u128,
        liquidity: u128,
        amount_remaining: u64,
        exact_in: bool,
        fee_pips: u64,
    ): (u128, u64, u64, u64) {
        let a_to_b = sqrt_price_current >= sqrt_price_target;

        let next_sqrt_price;
        let amount_in;
        let amount_out;
        let fee_amount;

        if (exact_in) {
            // Fee is carved out of the budget up front (floor, so the
            // amount available for price movement is not overstated).
            let amount_remaining_less_fee = (
                ((amount_remaining as u128) * ((FEE_SCALE - fee_pips) as u128)
                    / (FEE_SCALE as u128)) as u64
            );
            // Input needed to reach the target price (round up: swapper
            // pays at least the exact amount).
            let amount_in_to_target = if (a_to_b) {
                sqrt_price_math::get_amount_a_delta(
                    sqrt_price_target,
                    sqrt_price_current,
                    liquidity,
                    true,
                )
            } else {
                sqrt_price_math::get_amount_b_delta(
                    sqrt_price_current,
                    sqrt_price_target,
                    liquidity,
                    true,
                )
            };

            if (amount_remaining_less_fee >= amount_in_to_target) {
                // Budget reaches the target price.
                amount_in = amount_in_to_target;
                next_sqrt_price = sqrt_price_target;
                fee_amount = if (fee_pips == FEE_SCALE) {
                    // 100% fee: everything is fee, no price movement
                    // (amount_in is necessarily 0 here).
                    amount_in
                } else {
                    // ceil so fees round in the pool's favor.
                    mul_div_ceil_u64(amount_in, fee_pips, FEE_SCALE - fee_pips)
                };
            } else {
                // Budget exhausted inside this range: all of it is
                // consumed, and the slice not spent on price movement
                // becomes the fee. input + fee == amount_remaining.
                amount_in = amount_remaining_less_fee;
                next_sqrt_price = sqrt_price_math::next_sqrt_price_from_input(
                    sqrt_price_current,
                    liquidity,
                    amount_in,
                    a_to_b,
                );
                fee_amount = amount_remaining - amount_in;
            };

            // Output for the actual movement (round down: pool pays out
            // no more than the exact amount).
            amount_out = if (a_to_b) {
                sqrt_price_math::get_amount_b_delta(
                    next_sqrt_price,
                    sqrt_price_current,
                    liquidity,
                    false,
                )
            } else {
                sqrt_price_math::get_amount_a_delta(
                    sqrt_price_current,
                    next_sqrt_price,
                    liquidity,
                    false,
                )
            };
        } else {
            assert!(fee_pips < FEE_SCALE, EFeeConsumesEverything);
            // Output available down to the target price (round down).
            let amount_out_to_target = if (a_to_b) {
                sqrt_price_math::get_amount_b_delta(
                    sqrt_price_target,
                    sqrt_price_current,
                    liquidity,
                    false,
                )
            } else {
                sqrt_price_math::get_amount_a_delta(
                    sqrt_price_current,
                    sqrt_price_target,
                    liquidity,
                    false,
                )
            };

            let capped_out;
            if (amount_remaining >= amount_out_to_target) {
                capped_out = amount_out_to_target;
                next_sqrt_price = sqrt_price_target;
            } else {
                capped_out = amount_remaining;
                next_sqrt_price = sqrt_price_math::next_sqrt_price_from_output(
                    sqrt_price_current,
                    liquidity,
                    capped_out,
                    a_to_b,
                );
            };
            amount_out = capped_out;

            amount_in = if (a_to_b) {
                sqrt_price_math::get_amount_a_delta(
                    next_sqrt_price,
                    sqrt_price_current,
                    liquidity,
                    true,
                )
            } else {
                sqrt_price_math::get_amount_b_delta(
                    sqrt_price_current,
                    next_sqrt_price,
                    liquidity,
                    true,
                )
            };
            fee_amount = mul_div_ceil_u64(amount_in, fee_pips, FEE_SCALE - fee_pips);
        };

        (next_sqrt_price, amount_in, amount_out, fee_amount)
    }

    /// ceil(a * b / d) over u64 operands, widened through u128.
    /// Aborts if the result exceeds u64 (a fee that large could never
    /// be paid from a coin balance anyway).
    fun mul_div_ceil_u64(a: u64, b: u64, d: u64): u64 {
        let n = (a as u128) * (b as u128);
        let r = n / (d as u128) + (if (n % (d as u128) > 0) 1 else 0);
        assert!(r <= 0xFFFFFFFFFFFFFFFF, 1);
        (r as u64)
    }
}
