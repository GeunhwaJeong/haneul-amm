// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tick state: per-tick liquidity bookkeeping, fee-growth checkpoints,
/// and a bitmap index for finding the next initialized tick.
///
/// Each initialized tick records:
///  - `liquidity_gross`: total liquidity of all positions touching the
///    tick; the tick is initialized iff this is nonzero.
///  - `liquidity_net`: signed liquidity that comes into range when the
///    price crosses the tick moving upward (and leaves when moving
///    down).
///  - `fee_growth_outside_{a,b}`: fee growth accumulated on the far
///    side of the tick relative to the current price. Only differences
///    of these values are meaningful; the "all growth so far happened
///    below" initialization convention makes the position fee formula
///    exact regardless of when the tick was first used.
///
/// The bitmap packs one bit per spaced tick into 256-bit words keyed by
/// word index, so the swap loop can find the next initialized tick with
/// two table reads and a bit scan instead of walking tick by tick.
module haneul_amm::tick {
    use haneul::table::{Self, Table};
    use haneul_amm::i128::{Self, I128};
    use haneul_amm::i32::{Self, I32};
    use haneul_amm::math_u128;
    use haneul_amm::tick_math;

    /// Tick index is not a multiple of the pool's tick spacing.
    const ETickMisaligned: u64 = 0;
    /// A single tick would carry more liquidity than allowed.
    const ETickLiquidityOverflow: u64 = 1;
    /// Tick outside the globally valid range.
    const ETickOutOfBounds: u64 = 2;
    /// Lower tick must be strictly below upper tick.
    const ETicksMisordered: u64 = 3;

    const MAX_U256: u256 =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const MAX_U128: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    public struct TickInfo has copy, drop, store {
        liquidity_gross: u128,
        liquidity_net: I128,
        fee_growth_outside_a: u128,
        fee_growth_outside_b: u128,
    }

    /// All tick state for one pool.
    public struct TickTable has store {
        spacing: u32,
        /// `max_liquidity_per_tick(spacing)`, fixed at creation so the
        /// hot path does not redo the division on every update.
        max_liquidity: u128,
        ticks: Table<I32, TickInfo>,
        /// word index -> 256 initialized-bits, one per spaced tick.
        bitmap: Table<I32, u256>,
    }

    public(package) fun new(spacing: u32, ctx: &mut TxContext): TickTable {
        TickTable {
            spacing,
            max_liquidity: max_liquidity_per_tick(spacing),
            ticks: table::new(ctx),
            bitmap: table::new(ctx),
        }
    }

    public fun spacing(self: &TickTable): u32 {
        self.spacing
    }

    /// The per-tick liquidity cap this table enforces.
    public fun max_liquidity(self: &TickTable): u128 {
        self.max_liquidity
    }

    /// Cap on `liquidity_gross` per tick, chosen so that the sum over
    /// every usable tick still fits in u128. Guards the pool's global
    /// liquidity accumulator against overflow by construction.
    public fun max_liquidity_per_tick(spacing: u32): u128 {
        let num_ticks =
            ((tick_math::max_tick().abs_u32() / spacing) as u128) * 2 + 1;
        MAX_U128 / num_ticks
    }

    /// Validate a position's tick range against global bounds and the
    /// pool's spacing.
    public fun check_tick_range(self: &TickTable, lower: I32, upper: I32) {
        assert!(i32::lt(lower, upper), ETicksMisordered);
        assert!(i32::gte(lower, tick_math::min_tick()), ETickOutOfBounds);
        assert!(i32::lte(upper, tick_math::max_tick()), ETickOutOfBounds);
        assert!(lower.mod_u32(self.spacing) == 0, ETickMisaligned);
        assert!(upper.mod_u32(self.spacing) == 0, ETickMisaligned);
    }

    /// Apply a liquidity change to one boundary tick of a position.
    /// Returns whether the tick flipped between initialized and
    /// uninitialized (the caller must then flip the bitmap bit).
    public(package) fun update(
        self: &mut TickTable,
        tick: I32,
        current_tick: I32,
        liquidity_delta: I128,
        fee_growth_global_a: u128,
        fee_growth_global_b: u128,
        upper: bool,
    ): bool {
        if (!self.ticks.contains(tick)) {
            self.ticks.add(tick, TickInfo {
                liquidity_gross: 0,
                liquidity_net: i128::zero(),
                fee_growth_outside_a: 0,
                fee_growth_outside_b: 0,
            });
        };
        let info = self.ticks.borrow_mut(tick);

        let gross_before = info.liquidity_gross;
        let gross_after = add_liquidity_delta(gross_before, liquidity_delta);
        assert!(gross_after <= self.max_liquidity, ETickLiquidityOverflow);

        if (gross_before == 0) {
            // Convention: all fee growth before a tick's first use is
            // treated as having happened below the tick.
            if (i32::lte(tick, current_tick)) {
                info.fee_growth_outside_a = fee_growth_global_a;
                info.fee_growth_outside_b = fee_growth_global_b;
            };
        };

        info.liquidity_gross = gross_after;
        // Crossing a lower tick upward brings the position's liquidity
        // into range; crossing an upper tick upward takes it out.
        info.liquidity_net = if (upper) {
            i128::sub(info.liquidity_net, liquidity_delta)
        } else {
            i128::add(info.liquidity_net, liquidity_delta)
        };

        let flipped = (gross_after == 0) != (gross_before == 0);
        if (flipped) {
            self.flip_bit(tick);
        };
        // Note: an emptied tick's entry is intentionally NOT removed
        // here. Its fee-growth checkpoints must survive until the
        // owning position has settled its fees against them; the pool
        // calls `clear` afterwards.
        flipped
    }

    /// Delete an emptied tick's storage. Only called after the position
    /// that emptied it has settled fees against its checkpoints.
    public(package) fun clear(self: &mut TickTable, tick: I32) {
        if (self.ticks.contains(tick)) {
            self.ticks.remove(tick);
        };
    }

    /// Cross a tick during a swap: fold the global fee growth into the
    /// tick's outside checkpoints (they always represent the far side)
    /// and return the net liquidity change for the upward direction.
    public(package) fun cross(
        self: &mut TickTable,
        tick: I32,
        fee_growth_global_a: u128,
        fee_growth_global_b: u128,
    ): I128 {
        let info = self.ticks.borrow_mut(tick);
        info.fee_growth_outside_a =
            math_u128::wrapping_sub(fee_growth_global_a, info.fee_growth_outside_a);
        info.fee_growth_outside_b =
            math_u128::wrapping_sub(fee_growth_global_b, info.fee_growth_outside_b);
        info.liquidity_net
    }

    /// Fee growth per unit of liquidity accumulated strictly inside
    /// [lower, upper], derived from the global counters and the two
    /// boundary checkpoints. Wrapping subtraction throughout: the
    /// counters are modular by design.
    public fun get_fee_growth_inside(
        self: &TickTable,
        lower: I32,
        upper: I32,
        current_tick: I32,
        fee_growth_global_a: u128,
        fee_growth_global_b: u128,
    ): (u128, u128) {
        let (lower_out_a, lower_out_b) = self.outside_growth(lower);
        let (upper_out_a, upper_out_b) = self.outside_growth(upper);

        if (i32::lt(current_tick, lower)) {
            (
                math_u128::wrapping_sub(lower_out_a, upper_out_a),
                math_u128::wrapping_sub(lower_out_b, upper_out_b),
            )
        } else if (i32::gte(current_tick, upper)) {
            (
                math_u128::wrapping_sub(upper_out_a, lower_out_a),
                math_u128::wrapping_sub(upper_out_b, lower_out_b),
            )
        } else {
            (
                math_u128::wrapping_sub(
                    math_u128::wrapping_sub(fee_growth_global_a, lower_out_a),
                    upper_out_a,
                ),
                math_u128::wrapping_sub(
                    math_u128::wrapping_sub(fee_growth_global_b, lower_out_b),
                    upper_out_b,
                ),
            )
        }
    }

    /// Fee growth recorded on the far side of a tick. Uninitialized
    /// ticks read as zero, consistent with the initialization
    /// convention.
    fun outside_growth(self: &TickTable, tick: I32): (u128, u128) {
        if (self.ticks.contains(tick)) {
            let info = self.ticks.borrow(tick);
            (info.fee_growth_outside_a, info.fee_growth_outside_b)
        } else {
            (0, 0)
        }
    }

    /// Net liquidity of a tick (zero if uninitialized). Test/inspection
    /// helper.
    public fun liquidity_net(self: &TickTable, tick: I32): I128 {
        if (self.ticks.contains(tick)) {
            self.ticks.borrow(tick).liquidity_net
        } else {
            i128::zero()
        }
    }

    /// Gross liquidity of a tick (zero if uninitialized).
    public fun liquidity_gross(self: &TickTable, tick: I32): u128 {
        if (self.ticks.contains(tick)) {
            self.ticks.borrow(tick).liquidity_gross
        } else {
            0
        }
    }

    /// Find the next initialized tick within the same 256-bit bitmap
    /// word, searching down (lte = true, inclusive of `tick`) or up
    /// (exclusive of `tick`). Returns the candidate tick and whether it
    /// is initialized; an uninitialized result is the word boundary,
    /// which the swap loop uses as its next step limit and continues
    /// from there.
    public fun next_initialized_tick_within_one_word(
        self: &TickTable,
        tick: I32,
        lte: bool,
    ): (I32, bool) {
        let spacing = self.spacing;
        let compressed = tick.div_floor_u32(spacing);

        if (lte) {
            let word_pos = compressed.div_floor_u32(256);
            let bit_pos = (compressed.mod_u32(256) as u8);
            let word = self.word(word_pos);
            // Bits at or below bit_pos.
            let mask = if (bit_pos == 255) {
                MAX_U256
            } else {
                (1u256 << (bit_pos + 1)) - 1
            };
            let masked = word & mask;
            if (masked != 0) {
                let msb = haneul_amm::math_u256::msb(masked);
                let next_compressed = i32::sub(
                    compressed,
                    i32::from(((bit_pos - msb) as u32)),
                );
                (next_compressed.mul_u32(spacing), true)
            } else {
                let next_compressed = i32::sub(compressed, i32::from((bit_pos as u32)));
                (next_compressed.mul_u32(spacing), false)
            }
        } else {
            // Search starts one spaced tick above.
            let start = i32::add(compressed, i32::from(1));
            let word_pos = start.div_floor_u32(256);
            let bit_pos = (start.mod_u32(256) as u8);
            let word = self.word(word_pos);
            // Bits at or above bit_pos.
            let mask = MAX_U256 - ((1u256 << bit_pos) - 1);
            let masked = word & mask;
            if (masked != 0) {
                let lsb = haneul_amm::math_u256::lsb(masked);
                let next_compressed = i32::add(start, i32::from(((lsb - bit_pos) as u32)));
                (next_compressed.mul_u32(spacing), true)
            } else {
                let next_compressed = i32::add(start, i32::from(((255 - bit_pos) as u32)));
                (next_compressed.mul_u32(spacing), false)
            }
        }
    }

    fun word(self: &TickTable, word_pos: I32): u256 {
        if (self.bitmap.contains(word_pos)) {
            *self.bitmap.borrow(word_pos)
        } else {
            0
        }
    }

    fun flip_bit(self: &mut TickTable, tick: I32) {
        // Alignment is guaranteed by check_tick_range on every path
        // that reaches here.
        let compressed = tick.div_floor_u32(self.spacing);
        let word_pos = compressed.div_floor_u32(256);
        let bit_pos = (compressed.mod_u32(256) as u8);
        let mask = 1u256 << bit_pos;
        if (self.bitmap.contains(word_pos)) {
            let word = self.bitmap.borrow_mut(word_pos);
            *word = *word ^ mask;
            if (*word == 0) {
                self.bitmap.remove(word_pos);
            };
        } else {
            self.bitmap.add(word_pos, mask);
        };
    }

    /// liquidity + delta with overflow/underflow aborts.
    public fun add_liquidity_delta(liquidity: u128, delta: I128): u128 {
        if (delta.is_neg()) {
            let m = delta.abs_u128();
            assert!(liquidity >= m, ETickLiquidityOverflow);
            liquidity - m
        } else {
            let m = delta.bits();
            assert!(MAX_U128 - liquidity >= m, ETickLiquidityOverflow);
            liquidity + m
        }
    }

    #[test_only]
    public fun new_for_testing(spacing: u32, ctx: &mut TxContext): TickTable {
        new(spacing, ctx)
    }

    #[test_only]
    public fun update_for_testing(
        self: &mut TickTable,
        tick: I32,
        current_tick: I32,
        liquidity_delta: I128,
        fee_growth_global_a: u128,
        fee_growth_global_b: u128,
        upper: bool,
    ): bool {
        self.update(
            tick,
            current_tick,
            liquidity_delta,
            fee_growth_global_a,
            fee_growth_global_b,
            upper,
        )
    }

    #[test_only]
    public fun destroy_for_testing(self: TickTable) {
        let TickTable { spacing: _, max_liquidity: _, ticks, bitmap } = self;
        ticks.drop();
        bitmap.drop();
    }
}
