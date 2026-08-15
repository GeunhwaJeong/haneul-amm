// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Liquidity positions as first-class owned objects.
///
/// A position is a claim on liquidity between two ticks of a specific
/// pool. Because it is an object with `store`, it can be held, sent, or
/// composed by other packages without any registry: ownership *is* the
/// access control. Only this package can mutate the numeric fields; the
/// pool module drives every state change.
///
/// Fee accounting uses checkpoint differences: the position remembers
/// the fee-growth-inside values at its last touch, and any later touch
/// converts (current - last) * liquidity into concrete token amounts
/// credited to `fees_owed_*`. The counters are modular (they may wrap),
/// which is sound because a position is always settled against a
/// difference of two snapshots taken within its own lifetime.
module haneul_amm::position {
    use haneul_amm::i128::I128;
    use haneul_amm::i32::I32;
    use haneul_amm::math_u128;
    use haneul_amm::tick;

    /// The position still holds liquidity or uncollected fees.
    const EPositionNotEmpty: u64 = 0;
    /// Accumulated fees exceed what a coin balance can represent.
    const EFeeOverflow: u64 = 1;

    const MAX_U64: u256 = 0xFFFFFFFFFFFFFFFF;

    public struct Position has key, store {
        id: UID,
        pool_id: ID,
        tick_lower: I32,
        tick_upper: I32,
        liquidity: u128,
        fee_growth_inside_a_last: u128,
        fee_growth_inside_b_last: u128,
        fees_owed_a: u64,
        fees_owed_b: u64,
    }

    public(package) fun new(
        pool_id: ID,
        tick_lower: I32,
        tick_upper: I32,
        ctx: &mut TxContext,
    ): Position {
        Position {
            id: object::new(ctx),
            pool_id,
            tick_lower,
            tick_upper,
            liquidity: 0,
            fee_growth_inside_a_last: 0,
            fee_growth_inside_b_last: 0,
            fees_owed_a: 0,
            fees_owed_b: 0,
        }
    }

    /// Apply a liquidity change and settle fees accrued since the last
    /// touch into `fees_owed_*`. Fee settlement happens before the
    /// liquidity change so the old liquidity earns exactly up to this
    /// moment and the new liquidity earns from it.
    public(package) fun update(
        self: &mut Position,
        liquidity_delta: I128,
        fee_growth_inside_a: u128,
        fee_growth_inside_b: u128,
    ) {
        let owed_a = fees_from_growth(
            fee_growth_inside_a,
            self.fee_growth_inside_a_last,
            self.liquidity,
        );
        let owed_b = fees_from_growth(
            fee_growth_inside_b,
            self.fee_growth_inside_b_last,
            self.liquidity,
        );
        self.fees_owed_a = checked_add_u64(self.fees_owed_a, owed_a);
        self.fees_owed_b = checked_add_u64(self.fees_owed_b, owed_b);
        self.fee_growth_inside_a_last = fee_growth_inside_a;
        self.fee_growth_inside_b_last = fee_growth_inside_b;

        if (!liquidity_delta.is_zero()) {
            self.liquidity = tick::add_liquidity_delta(self.liquidity, liquidity_delta);
        };
    }

    /// Zero out and return the owed fees; the pool pays them out.
    public(package) fun take_fees_owed(self: &mut Position): (u64, u64) {
        let (a, b) = (self.fees_owed_a, self.fees_owed_b);
        self.fees_owed_a = 0;
        self.fees_owed_b = 0;
        (a, b)
    }

    /// Delete an emptied position. Aborts if any liquidity or fees
    /// remain, so value can never be destroyed by mistake.
    public fun close(self: Position) {
        let Position {
            id,
            pool_id: _,
            tick_lower: _,
            tick_upper: _,
            liquidity,
            fee_growth_inside_a_last: _,
            fee_growth_inside_b_last: _,
            fees_owed_a,
            fees_owed_b,
        } = self;
        assert!(liquidity == 0 && fees_owed_a == 0 && fees_owed_b == 0, EPositionNotEmpty);
        id.delete();
    }

    // === Views ===

    public fun pool_id(self: &Position): ID {
        self.pool_id
    }

    public fun tick_lower(self: &Position): I32 {
        self.tick_lower
    }

    public fun tick_upper(self: &Position): I32 {
        self.tick_upper
    }

    public fun liquidity(self: &Position): u128 {
        self.liquidity
    }

    public fun fees_owed(self: &Position): (u64, u64) {
        (self.fees_owed_a, self.fees_owed_b)
    }

    // === Internals ===

    /// (growth_now - growth_last) * liquidity / 2^64, with the modular
    /// difference intact.
    fun fees_from_growth(growth_now: u128, growth_last: u128, liquidity: u128): u64 {
        if (liquidity == 0) return 0;
        let diff = math_u128::wrapping_sub(growth_now, growth_last);
        let owed = math_u128::full_mul(diff, liquidity) >> 64;
        // A garbage-large value can only arise from a wrapped counter
        // being consumed across more than one wrap period, which real
        // fee volume cannot produce; abort rather than mint value.
        assert!(owed <= MAX_U64, EFeeOverflow);
        (owed as u64)
    }

    fun checked_add_u64(a: u64, b: u64): u64 {
        let r = (a as u128) + (b as u128);
        assert!(r <= 0xFFFFFFFFFFFFFFFF, EFeeOverflow);
        (r as u64)
    }
}
