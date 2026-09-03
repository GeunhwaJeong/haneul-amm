// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// The pool: concentrated liquidity, swaps, donations, flash loans,
/// and fee accounting for one currency pair.
///
/// # Settlement model
///
/// The pool never trusts a caller to pay later; it makes not-paying
/// unrepresentable. Every operation that puts the pool temporarily out
/// of balance returns a receipt with no abilities (it cannot be
/// dropped, stored, or transferred), so the transaction cannot finish
/// until the matching `repay_*` call consumes it with exact payment.
/// This turns deferred settlement into a type-system guarantee:
///
///  - `swap_*` hands the output over immediately and returns a
///    `SwapReceipt` for the input, so the output can fund the input
///    (multi-hop routes and arbitrage need no working capital).
///  - `add_liquidity` returns an `AddLiquidityReceipt` for the two
///    principal amounts.
///  - `flash_loan` lends any amounts against a `FlashLoanReceipt`.
///
/// Any number of these can be interleaved in one transaction; each
/// receipt pins its own pool and amounts.
///
/// # Hooks
///
/// A pool may be bound at creation to a hook: a witness type `W` from
/// another package. For each operation class the pool was configured
/// to gate, the plain entry point aborts and only the `*_with_hook`
/// variant, which demands an instance of `W`, works. Since only the
/// hook's package can construct its witness, every gated operation
/// must route through hook code, which may run arbitrary logic before
/// and after and, on dynamic-fee pools, override the fee per swap.
/// Which operation classes are gated is fixed forever at creation.
///
/// # Immutability
///
/// There is no pause switch and no administrative path that can hold
/// or move liquidity: a provider can always remove a position and
/// collect its fees, whatever the protocol capability holder does.
/// The one lever the capability has over live pools is the version
/// gate: publishing a new package version makes every pool refuse
/// state changes until `migrate` is called on it, which is meant for
/// upgrades, not for operations. State that a future version may need
/// hangs off the pool's `id` as dynamic fields, so the object layout
/// never has to change.
///
/// Flash loans are free and never hook-gated. Reserves are lent
/// against a receipt that demands exact repayment in the same
/// transaction, so the pool takes no risk and the loan touches no
/// price or fee state; charging for it would only push the same
/// capital toward the swap path, where it already pays the LP fee.
module haneul_amm::pool {
    use haneul::balance::{Self, Balance};
    use haneul::event;
    use std::type_name::{Self, TypeName};
    use haneul_amm::i128::{Self, I128};
    use haneul_amm::i32::{Self, I32};
    use haneul_amm::math_u128;
    use haneul_amm::position::{Self, Position};
    use haneul_amm::swap_math;
    use haneul_amm::sqrt_price_math;
    use haneul_amm::tick::{Self, TickTable};
    use haneul_amm::tick_math;

    // === Errors ===

    /// Package was upgraded; call `migrate` first.
    const EVersionMismatch: u64 = 0;
    /// Swap amount must be nonzero.
    const ESwapAmountZero: u64 = 1;
    /// The price limit is on the wrong side of the current price.
    const EPriceLimitAlreadyExceeded: u64 = 2;
    /// The price limit is outside the representable price range.
    const EPriceLimitOutOfBounds: u64 = 3;
    /// A 100% fee makes exact-output swaps impossible.
    const EInvalidFeeForExactOut: u64 = 4;
    /// This operation is gated by the pool's hook; use the hook path.
    const EHookRequired: u64 = 5;
    /// Witness type does not match the pool's hook, or pool has none.
    const EWrongHook: u64 = 6;
    /// Receipt belongs to a different pool.
    const EReceiptPoolMismatch: u64 = 7;
    /// Payment must match the receipt amount exactly.
    const EIncorrectRepayAmount: u64 = 8;
    /// Repaying the wrong currency for this receipt's direction.
    const EWrongRepayDirection: u64 = 9;
    /// Position belongs to a different pool.
    const EPositionPoolMismatch: u64 = 10;
    /// Liquidity change must be nonzero.
    const EZeroLiquidity: u64 = 11;
    /// Donations require in-range liquidity to receive them.
    const ENoLiquidityToReceiveFees: u64 = 12;
    /// Protocol fee above the hard cap.
    const EProtocolFeeTooLarge: u64 = 13;
    /// LP fee above 100%.
    const ELpFeeTooLarge: u64 = 14;
    /// Fee updates are only allowed on dynamic-fee pools.
    const ENotDynamicFee: u64 = 15;
    /// Tick spacing outside [1, 32767].
    const ETickSpacingOutOfRange: u64 = 16;
    /// Dynamic-fee pools must start with a zero LP fee.
    const EDynamicFeeMustStartZero: u64 = 17;
    /// Accumulated amount exceeds a coin balance.
    const EAmountOverflow: u64 = 18;
    /// Fee override only applies to dynamic-fee pools.
    const EFeeOverrideOnStaticPool: u64 = 19;
    /// Nothing is migrated on an up-to-date object.
    const ENotUpgraded: u64 = 20;

    // === Constants ===

    const VERSION: u64 = 1;

    /// Hook permission bits; fixed at pool creation.
    const HOOK_ON_SWAP: u8 = 1 << 0;
    const HOOK_ON_ADD_LIQUIDITY: u8 = 1 << 1;
    const HOOK_ON_REMOVE_LIQUIDITY: u8 = 1 << 2;
    const HOOK_ON_DONATE: u8 = 1 << 3;

    /// Protocol fee hard cap per direction: 1000 pips = 0.1%.
    const MAX_PROTOCOL_FEE_PIPS: u64 = 1000;
    /// Tick spacing bounds.
    const MIN_TICK_SPACING: u32 = 1;
    const MAX_TICK_SPACING: u32 = 32767;

    const MAX_U64: u128 = 0xFFFFFFFFFFFFFFFF;

    // === Objects ===

    public struct Pool<phantom A, phantom B> has key {
        id: UID,
        version: u64,
        // Immutable configuration.
        tick_spacing_: u32,
        is_dynamic_fee: bool,
        hook: Option<TypeName>,
        hook_permissions: u8,
        // Fees. `lp_fee_pips` is fixed for static pools and mutable by
        // the hook for dynamic ones.
        lp_fee_pips: u64,
        protocol_fee_a_to_b: u64,
        protocol_fee_b_to_a: u64,
        // Price state.
        sqrt_price_x64: u128,
        tick_current: I32,
        liquidity: u128,
        fee_growth_global_a: u128,
        fee_growth_global_b: u128,
        // Tick and bitmap state.
        ticks: TickTable,
        // Vaults.
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        protocol_fees_a: Balance<A>,
        protocol_fees_b: Balance<B>,
    }

    /// Authorizes protocol fee administration and migrations.
    public struct ProtocolCap has key, store {
        id: UID,
    }

    // === Receipts (no abilities: must be consumed this transaction) ===

    /// Debt for a swap's input currency: A if `a_to_b`, otherwise B.
    /// `protocol_fee` is carved out of the repayment into the protocol
    /// vault; the rest joins pool reserves.
    public struct SwapReceipt {
        pool_id: ID,
        a_to_b: bool,
        amount_owed: u64,
        protocol_fee: u64,
    }

    /// Debt for the principal backing freshly added liquidity.
    public struct AddLiquidityReceipt {
        pool_id: ID,
        amount_a: u64,
        amount_b: u64,
    }

    /// Debt for a flash loan; repayment is exact, with no fee.
    public struct FlashLoanReceipt {
        pool_id: ID,
        amount_a: u64,
        amount_b: u64,
    }

    // === Events ===

    public struct PoolCreated has copy, drop {
        pool_id: ID,
        coin_a: TypeName,
        coin_b: TypeName,
        tick_spacing: u32,
        lp_fee_pips: u64,
        is_dynamic_fee: bool,
        hook: Option<TypeName>,
        hook_permissions: u8,
        protocol_fee_a_to_b: u64,
        protocol_fee_b_to_a: u64,
        sqrt_price_x64: u128,
        tick_bits: u32,
    }

    public struct Swapped has copy, drop {
        pool_id: ID,
        a_to_b: bool,
        amount_in: u64,
        amount_out: u64,
        protocol_fee: u64,
        lp_fee_pips: u64,
        sqrt_price_x64: u128,
        liquidity: u128,
        tick_bits: u32,
    }

    public struct LiquidityModified has copy, drop {
        pool_id: ID,
        position_id: ID,
        tick_lower_bits: u32,
        tick_upper_bits: u32,
        is_add: bool,
        liquidity_delta: u128,
        amount_a: u64,
        amount_b: u64,
        /// The position's liquidity after this change.
        position_liquidity: u128,
        /// The pool's in-range liquidity after this change.
        pool_liquidity: u128,
    }

    public struct FeesCollected has copy, drop {
        pool_id: ID,
        position_id: ID,
        amount_a: u64,
        amount_b: u64,
    }

    public struct Donated has copy, drop {
        pool_id: ID,
        amount_a: u64,
        amount_b: u64,
    }

    public struct FlashLoaned has copy, drop {
        pool_id: ID,
        amount_a: u64,
        amount_b: u64,
    }

    public struct ProtocolFeeSet has copy, drop {
        pool_id: ID,
        fee_a_to_b_pips: u64,
        fee_b_to_a_pips: u64,
    }

    public struct ProtocolFeesCollected has copy, drop {
        pool_id: ID,
        amount_a: u64,
        amount_b: u64,
    }

    public struct LpFeeUpdated has copy, drop {
        pool_id: ID,
        lp_fee_pips: u64,
    }

    // === Pool creation (registry only) ===

    public(package) fun new<A, B>(
        lp_fee_pips: u64,
        is_dynamic_fee: bool,
        tick_spacing: u32,
        hook: Option<TypeName>,
        hook_permissions: u8,
        protocol_fee_a_to_b: u64,
        protocol_fee_b_to_a: u64,
        sqrt_price_x64: u128,
        ctx: &mut TxContext,
    ): Pool<A, B> {
        assert_tick_spacing(tick_spacing);
        if (is_dynamic_fee) {
            // The hook decides the fee; it starts at zero and can be
            // set in the same transaction that creates the pool.
            assert!(lp_fee_pips == 0, EDynamicFeeMustStartZero);
        } else {
            assert_lp_fee(lp_fee_pips);
        };
        assert_protocol_fees(protocol_fee_a_to_b, protocol_fee_b_to_a);
        // Validates the price range and derives the starting tick.
        let tick_current = tick_math::get_tick_at_sqrt_price(sqrt_price_x64);

        let pool = Pool<A, B> {
            id: object::new(ctx),
            version: VERSION,
            tick_spacing_: tick_spacing,
            is_dynamic_fee,
            hook,
            hook_permissions,
            lp_fee_pips,
            protocol_fee_a_to_b,
            protocol_fee_b_to_a,
            sqrt_price_x64,
            tick_current,
            liquidity: 0,
            fee_growth_global_a: 0,
            fee_growth_global_b: 0,
            ticks: tick::new(tick_spacing, ctx),
            balance_a: balance::zero(),
            balance_b: balance::zero(),
            protocol_fees_a: balance::zero(),
            protocol_fees_b: balance::zero(),
        };

        event::emit(PoolCreated {
            pool_id: pool.id.to_inner(),
            coin_a: type_name::with_defining_ids<A>(),
            coin_b: type_name::with_defining_ids<B>(),
            tick_spacing,
            lp_fee_pips,
            is_dynamic_fee,
            hook,
            hook_permissions,
            protocol_fee_a_to_b,
            protocol_fee_b_to_a,
            sqrt_price_x64,
            tick_bits: tick_current.bits(),
        });

        pool
    }

    public(package) fun share<A, B>(pool: Pool<A, B>) {
        transfer::share_object(pool);
    }

    public(package) fun new_protocol_cap(ctx: &mut TxContext): ProtocolCap {
        ProtocolCap { id: object::new(ctx) }
    }

    // === Swaps ===

    /// Swap A for B on a pool whose swaps are not hook-gated. Returns
    /// the output immediately plus the debt receipt for the input.
    /// `exact_in`: `amount` is the input budget (fees included);
    /// otherwise `amount` is the exact output requested.
    public fun swap_a_for_b<A, B>(
        pool: &mut Pool<A, B>,
        amount: u64,
        exact_in: bool,
        sqrt_price_limit: u128,
    ): (Balance<B>, SwapReceipt) {
        pool.assert_no_hook_gate(HOOK_ON_SWAP);
        pool.swap_impl(true, exact_in, amount, sqrt_price_limit, option::none())
    }

    /// Swap B for A on a pool whose swaps are not hook-gated.
    public fun swap_b_for_a<A, B>(
        pool: &mut Pool<A, B>,
        amount: u64,
        exact_in: bool,
        sqrt_price_limit: u128,
    ): (Balance<A>, SwapReceipt) {
        pool.assert_no_hook_gate(HOOK_ON_SWAP);
        pool.swap_impl2(false, exact_in, amount, sqrt_price_limit, option::none())
    }

    /// Hook-gated swap A for B. `lp_fee_override`, if provided, replaces
    /// the stored LP fee for this swap only (dynamic-fee pools only).
    public fun swap_a_for_b_with_hook<A, B, W: drop>(
        pool: &mut Pool<A, B>,
        _witness: W,
        amount: u64,
        exact_in: bool,
        sqrt_price_limit: u128,
        lp_fee_override: Option<u64>,
    ): (Balance<B>, SwapReceipt) {
        pool.assert_hook<A, B, W>();
        pool.swap_impl(true, exact_in, amount, sqrt_price_limit, lp_fee_override)
    }

    /// Hook-gated swap B for A.
    public fun swap_b_for_a_with_hook<A, B, W: drop>(
        pool: &mut Pool<A, B>,
        _witness: W,
        amount: u64,
        exact_in: bool,
        sqrt_price_limit: u128,
        lp_fee_override: Option<u64>,
    ): (Balance<A>, SwapReceipt) {
        pool.assert_hook<A, B, W>();
        pool.swap_impl2(false, exact_in, amount, sqrt_price_limit, lp_fee_override)
    }

    /// Settle the input side of an A-to-B swap. The payment must equal
    /// the receipt amount exactly; the protocol's cut moves to its own
    /// vault and the rest joins reserves.
    public fun repay_swap_a<A, B>(
        pool: &mut Pool<A, B>,
        receipt: SwapReceipt,
        mut payment: Balance<A>,
    ) {
        let SwapReceipt { pool_id, a_to_b, amount_owed, protocol_fee } = receipt;
        assert!(pool_id == pool.id.to_inner(), EReceiptPoolMismatch);
        assert!(a_to_b, EWrongRepayDirection);
        assert!(payment.value() == amount_owed, EIncorrectRepayAmount);
        pool.protocol_fees_a.join(payment.split(protocol_fee));
        pool.balance_a.join(payment);
    }

    /// Settle the input side of a B-to-A swap.
    public fun repay_swap_b<A, B>(
        pool: &mut Pool<A, B>,
        receipt: SwapReceipt,
        mut payment: Balance<B>,
    ) {
        let SwapReceipt { pool_id, a_to_b, amount_owed, protocol_fee } = receipt;
        assert!(pool_id == pool.id.to_inner(), EReceiptPoolMismatch);
        assert!(!a_to_b, EWrongRepayDirection);
        assert!(payment.value() == amount_owed, EIncorrectRepayAmount);
        pool.protocol_fees_b.join(payment.split(protocol_fee));
        pool.balance_b.join(payment);
    }

    // === Liquidity ===

    /// Create an empty position for a tick range of this pool. Not
    /// hook-gated: an empty position moves no value.
    public fun open_position<A, B>(
        pool: &Pool<A, B>,
        tick_lower_bits: u32,
        tick_upper_bits: u32,
        ctx: &mut TxContext,
    ): Position {
        pool.assert_version();
        let lower = i32::from_bits(tick_lower_bits);
        let upper = i32::from_bits(tick_upper_bits);
        pool.ticks.check_tick_range(lower, upper);
        position::new(pool.id.to_inner(), lower, upper, ctx)
    }

    /// Add liquidity to a position; returns the debt receipt for the
    /// principal. Settle with `repay_add_liquidity` in this transaction.
    public fun add_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
        liquidity_delta: u128,
    ): AddLiquidityReceipt {
        pool.assert_no_hook_gate(HOOK_ON_ADD_LIQUIDITY);
        pool.add_liquidity_impl(pos, liquidity_delta)
    }

    /// Hook-gated variant of `add_liquidity`.
    public fun add_liquidity_with_hook<A, B, W: drop>(
        pool: &mut Pool<A, B>,
        _witness: W,
        pos: &mut Position,
        liquidity_delta: u128,
    ): AddLiquidityReceipt {
        pool.assert_hook<A, B, W>();
        pool.add_liquidity_impl(pos, liquidity_delta)
    }

    /// Settle an `add_liquidity` debt with exact amounts.
    public fun repay_add_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        receipt: AddLiquidityReceipt,
        payment_a: Balance<A>,
        payment_b: Balance<B>,
    ) {
        let AddLiquidityReceipt { pool_id, amount_a, amount_b } = receipt;
        assert!(pool_id == pool.id.to_inner(), EReceiptPoolMismatch);
        assert!(payment_a.value() == amount_a, EIncorrectRepayAmount);
        assert!(payment_b.value() == amount_b, EIncorrectRepayAmount);
        pool.balance_a.join(payment_a);
        pool.balance_b.join(payment_b);
    }

    /// Remove liquidity and receive the principal immediately. Fees
    /// accrued so far are settled into the position; collect them with
    /// `collect_fees`.
    public fun remove_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
        liquidity_delta: u128,
    ): (Balance<A>, Balance<B>) {
        pool.assert_no_hook_gate(HOOK_ON_REMOVE_LIQUIDITY);
        pool.remove_liquidity_impl(pos, liquidity_delta)
    }

    /// Hook-gated variant of `remove_liquidity`.
    public fun remove_liquidity_with_hook<A, B, W: drop>(
        pool: &mut Pool<A, B>,
        _witness: W,
        pos: &mut Position,
        liquidity_delta: u128,
    ): (Balance<A>, Balance<B>) {
        pool.assert_hook<A, B, W>();
        pool.remove_liquidity_impl(pos, liquidity_delta)
    }

    /// Pay out all fees owed to a position. Gated with the remove
    /// class: fee collection extracts value from the pool exactly like
    /// removal, so a hook that supervises one must supervise both.
    public fun collect_fees<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
    ): (Balance<A>, Balance<B>) {
        pool.assert_no_hook_gate(HOOK_ON_REMOVE_LIQUIDITY);
        pool.collect_fees_impl(pos)
    }

    /// Hook-gated variant of `collect_fees`.
    public fun collect_fees_with_hook<A, B, W: drop>(
        pool: &mut Pool<A, B>,
        _witness: W,
        pos: &mut Position,
    ): (Balance<A>, Balance<B>) {
        pool.assert_hook<A, B, W>();
        pool.collect_fees_impl(pos)
    }

    // === Donations ===

    /// Give tokens to current in-range liquidity providers through the
    /// fee accumulators. Note that the credit goes to whoever is in
    /// range at this instant; donations are frontrunnable by just-in-
    /// time liquidity, so donors should prefer mechanisms that do not
    /// telegraph the donation.
    public fun donate<A, B>(
        pool: &mut Pool<A, B>,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
    ) {
        pool.assert_no_hook_gate(HOOK_ON_DONATE);
        pool.donate_impl(balance_a, balance_b)
    }

    /// Hook-gated variant of `donate`.
    public fun donate_with_hook<A, B, W: drop>(
        pool: &mut Pool<A, B>,
        _witness: W,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
    ) {
        pool.assert_hook<A, B, W>();
        pool.donate_impl(balance_a, balance_b)
    }

    // === Flash loans ===

    /// Borrow any amounts from reserves for the duration of the
    /// transaction. Free of fee; the receipt forces exact repayment.
    public fun flash_loan<A, B>(
        pool: &mut Pool<A, B>,
        amount_a: u64,
        amount_b: u64,
    ): (Balance<A>, Balance<B>, FlashLoanReceipt) {
        pool.assert_version();
        let receipt = FlashLoanReceipt {
            pool_id: pool.id.to_inner(),
            amount_a,
            amount_b,
        };
        event::emit(FlashLoaned {
            pool_id: pool.id.to_inner(),
            amount_a,
            amount_b,
        });
        (pool.balance_a.split(amount_a), pool.balance_b.split(amount_b), receipt)
    }

    /// Repay a flash loan exactly.
    public fun repay_flash_loan<A, B>(
        pool: &mut Pool<A, B>,
        receipt: FlashLoanReceipt,
        payment_a: Balance<A>,
        payment_b: Balance<B>,
    ) {
        let FlashLoanReceipt { pool_id, amount_a, amount_b } = receipt;
        assert!(pool_id == pool.id.to_inner(), EReceiptPoolMismatch);
        assert!(payment_a.value() == amount_a, EIncorrectRepayAmount);
        assert!(payment_b.value() == amount_b, EIncorrectRepayAmount);
        pool.balance_a.join(payment_a);
        pool.balance_b.join(payment_b);
    }

    // === Fee administration ===

    /// Set per-direction protocol fees, capped at 0.1%. The protocol
    /// fee is taken from the swap input before the LP fee.
    public fun set_protocol_fee<A, B>(
        pool: &mut Pool<A, B>,
        _cap: &ProtocolCap,
        fee_a_to_b_pips: u64,
        fee_b_to_a_pips: u64,
    ) {
        pool.assert_version();
        assert_protocol_fees(fee_a_to_b_pips, fee_b_to_a_pips);
        pool.protocol_fee_a_to_b = fee_a_to_b_pips;
        pool.protocol_fee_b_to_a = fee_b_to_a_pips;
        event::emit(ProtocolFeeSet {
            pool_id: pool.id.to_inner(),
            fee_a_to_b_pips,
            fee_b_to_a_pips,
        });
    }

    /// Withdraw all accrued protocol fees.
    public fun collect_protocol_fees<A, B>(
        pool: &mut Pool<A, B>,
        _cap: &ProtocolCap,
    ): (Balance<A>, Balance<B>) {
        pool.assert_version();
        let a = pool.protocol_fees_a.withdraw_all();
        let b = pool.protocol_fees_b.withdraw_all();
        event::emit(ProtocolFeesCollected {
            pool_id: pool.id.to_inner(),
            amount_a: a.value(),
            amount_b: b.value(),
        });
        (a, b)
    }

    /// Update the LP fee of a dynamic-fee pool. Only the pool's hook
    /// can call this, by presenting its witness.
    public fun update_lp_fee<A, B, W: drop>(
        pool: &mut Pool<A, B>,
        _witness: W,
        new_lp_fee_pips: u64,
    ) {
        pool.assert_version();
        assert!(pool.is_dynamic_fee, ENotDynamicFee);
        pool.assert_hook_type<A, B, W>();
        assert!(new_lp_fee_pips <= swap_math::fee_scale(), ELpFeeTooLarge);
        pool.lp_fee_pips = new_lp_fee_pips;
        event::emit(LpFeeUpdated {
            pool_id: pool.id.to_inner(),
            lp_fee_pips: new_lp_fee_pips,
        });
    }

    /// Bring an old pool object up to the current package version.
    public fun migrate<A, B>(pool: &mut Pool<A, B>, _cap: &ProtocolCap) {
        assert!(pool.version < VERSION, ENotUpgraded);
        pool.version = VERSION;
    }

    // === Views ===

    public fun sqrt_price_x64<A, B>(pool: &Pool<A, B>): u128 {
        pool.sqrt_price_x64
    }

    public fun tick_current<A, B>(pool: &Pool<A, B>): I32 {
        pool.tick_current
    }

    public fun liquidity<A, B>(pool: &Pool<A, B>): u128 {
        pool.liquidity
    }

    public fun tick_spacing<A, B>(pool: &Pool<A, B>): u32 {
        pool.tick_spacing_
    }

    public fun lp_fee_pips<A, B>(pool: &Pool<A, B>): u64 {
        pool.lp_fee_pips
    }

    public fun is_dynamic_fee<A, B>(pool: &Pool<A, B>): bool {
        pool.is_dynamic_fee
    }

    public fun protocol_fees_pips<A, B>(pool: &Pool<A, B>): (u64, u64) {
        (pool.protocol_fee_a_to_b, pool.protocol_fee_b_to_a)
    }

    public fun fee_growth_globals<A, B>(pool: &Pool<A, B>): (u128, u128) {
        (pool.fee_growth_global_a, pool.fee_growth_global_b)
    }

    public fun reserves<A, B>(pool: &Pool<A, B>): (u64, u64) {
        (pool.balance_a.value(), pool.balance_b.value())
    }

    public fun protocol_fees_accrued<A, B>(pool: &Pool<A, B>): (u64, u64) {
        (pool.protocol_fees_a.value(), pool.protocol_fees_b.value())
    }

    public fun hook<A, B>(pool: &Pool<A, B>): Option<TypeName> {
        pool.hook
    }

    public fun hook_permissions<A, B>(pool: &Pool<A, B>): u8 {
        pool.hook_permissions
    }

    public fun ticks<A, B>(pool: &Pool<A, B>): &TickTable {
        &pool.ticks
    }

    /// Principal that `liquidity` between `lower` and `upper` represents
    /// at the pool's current price: what an add would charge when
    /// `round_up`, what a remove would pay out otherwise. The position
    /// classification uses the stored tick, exactly as the liquidity
    /// paths do, so this is the figure those paths will use.
    public fun amounts_for_liquidity<A, B>(
        pool: &Pool<A, B>,
        lower: I32,
        upper: I32,
        liquidity: u128,
        round_up: bool,
    ): (u64, u64) {
        let price_lower = tick_math::get_sqrt_price_at_tick(lower);
        let price_upper = tick_math::get_sqrt_price_at_tick(upper);

        if (i32::lt(pool.tick_current, lower)) {
            // Range entirely above the price: becomes active only when
            // the price rises into it, so it is denominated in A.
            (
                sqrt_price_math::get_amount_a_delta(
                    price_lower,
                    price_upper,
                    liquidity,
                    round_up,
                ),
                0,
            )
        } else if (i32::lt(pool.tick_current, upper)) {
            // Range straddles the price: both tokens.
            (
                sqrt_price_math::get_amount_a_delta(
                    pool.sqrt_price_x64,
                    price_upper,
                    liquidity,
                    round_up,
                ),
                sqrt_price_math::get_amount_b_delta(
                    price_lower,
                    pool.sqrt_price_x64,
                    liquidity,
                    round_up,
                ),
            )
        } else {
            // Range entirely below the price: denominated in B.
            (
                0,
                sqrt_price_math::get_amount_b_delta(
                    price_lower,
                    price_upper,
                    liquidity,
                    round_up,
                ),
            )
        }
    }

    /// Replay a swap against the current state without applying it.
    /// Returns (amount_in including fees, amount_out, protocol fee,
    /// sqrt price after, tick after, in-range liquidity after). Exact
    /// for the state it reads; it is the same walk `swap_*` performs.
    /// Hook gating is not consulted: a quote moves nothing.
    public fun simulate_swap<A, B>(
        pool: &Pool<A, B>,
        a_to_b: bool,
        exact_in: bool,
        amount: u64,
        sqrt_price_limit: u128,
        lp_fee_override: Option<u64>,
    ): (u64, u64, u64, u128, I32, u128) {
        let w = pool.walk(a_to_b, exact_in, amount, sqrt_price_limit, lp_fee_override);
        (w.amount_in, w.amount_out, w.protocol_fee, w.sqrt_price, w.tick, w.liquidity)
    }

    /// Amounts of the receipt a swap must repay: (owed, protocol cut).
    public fun swap_receipt_amounts(receipt: &SwapReceipt): (u64, u64) {
        (receipt.amount_owed, receipt.protocol_fee)
    }

    public fun add_liquidity_receipt_amounts(receipt: &AddLiquidityReceipt): (u64, u64) {
        (receipt.amount_a, receipt.amount_b)
    }

    /// Hook permission bit constants, for pool creators.
    public fun hook_on_swap(): u8 { HOOK_ON_SWAP }

    public fun hook_on_add_liquidity(): u8 { HOOK_ON_ADD_LIQUIDITY }

    public fun hook_on_remove_liquidity(): u8 { HOOK_ON_REMOVE_LIQUIDITY }

    public fun hook_on_donate(): u8 { HOOK_ON_DONATE }

    public fun max_protocol_fee_pips(): u64 { MAX_PROTOCOL_FEE_PIPS }

    public fun min_tick_spacing(): u32 { MIN_TICK_SPACING }

    public fun max_tick_spacing(): u32 { MAX_TICK_SPACING }

    /// Parameter validation shared with the registry, so that a fee
    /// tier can be rejected when it is enabled rather than when the
    /// first pool tries to use it.
    public fun assert_tick_spacing(tick_spacing: u32) {
        assert!(
            tick_spacing >= MIN_TICK_SPACING && tick_spacing <= MAX_TICK_SPACING,
            ETickSpacingOutOfRange,
        );
    }

    public fun assert_lp_fee(lp_fee_pips: u64) {
        assert!(lp_fee_pips <= swap_math::fee_scale(), ELpFeeTooLarge);
    }

    public fun assert_protocol_fees(fee_a_to_b_pips: u64, fee_b_to_a_pips: u64) {
        assert!(
            fee_a_to_b_pips <= MAX_PROTOCOL_FEE_PIPS
                && fee_b_to_a_pips <= MAX_PROTOCOL_FEE_PIPS,
            EProtocolFeeTooLarge,
        );
    }

    // === Internals: swaps ===

    /// A-to-B path: output currency is B.
    fun swap_impl<A, B>(
        pool: &mut Pool<A, B>,
        a_to_b: bool,
        exact_in: bool,
        amount: u64,
        sqrt_price_limit: u128,
        lp_fee_override: Option<u64>,
    ): (Balance<B>, SwapReceipt) {
        let (amount_in, amount_out, protocol_fee) =
            pool.swap_engine(a_to_b, exact_in, amount, sqrt_price_limit, lp_fee_override);
        let receipt = SwapReceipt {
            pool_id: pool.id.to_inner(),
            a_to_b,
            amount_owed: amount_in,
            protocol_fee,
        };
        (pool.balance_b.split(amount_out), receipt)
    }

    /// B-to-A path: output currency is A. Identical engine; Move needs
    /// a second signature because the output type differs.
    fun swap_impl2<A, B>(
        pool: &mut Pool<A, B>,
        a_to_b: bool,
        exact_in: bool,
        amount: u64,
        sqrt_price_limit: u128,
        lp_fee_override: Option<u64>,
    ): (Balance<A>, SwapReceipt) {
        let (amount_in, amount_out, protocol_fee) =
            pool.swap_engine(a_to_b, exact_in, amount, sqrt_price_limit, lp_fee_override);
        let receipt = SwapReceipt {
            pool_id: pool.id.to_inner(),
            a_to_b,
            amount_owed: amount_in,
            protocol_fee,
        };
        (pool.balance_a.split(amount_out), receipt)
    }

    /// A tick crossed during a walk, with the global fee growth at the
    /// moment of crossing (which is what the tick's outside checkpoint
    /// must be folded against).
    public struct Crossing has copy, drop {
        tick: I32,
        fee_growth_a: u128,
        fee_growth_b: u128,
    }

    /// Everything a swap changes, computed against `&Pool` so the same
    /// code serves quotes and executions.
    public struct Walk has drop {
        amount_in: u64,
        amount_out: u64,
        protocol_fee: u64,
        lp_fee: u64,
        sqrt_price: u128,
        tick: I32,
        liquidity: u128,
        fee_growth_input: u128,
        crossings: vector<Crossing>,
    }

    /// Apply a walk: fold crossed ticks, write the new price state,
    /// emit the event. Returns (input owed including all fees, output
    /// owed to the swapper, protocol's cut of the input).
    fun swap_engine<A, B>(
        pool: &mut Pool<A, B>,
        a_to_b: bool,
        exact_in: bool,
        amount: u64,
        sqrt_price_limit: u128,
        lp_fee_override: Option<u64>,
    ): (u64, u64, u64) {
        pool.assert_version();
        let w = pool.walk(a_to_b, exact_in, amount, sqrt_price_limit, lp_fee_override);

        let mut i = 0;
        let n = w.crossings.length();
        while (i < n) {
            let c = &w.crossings[i];
            pool.ticks.cross(c.tick, c.fee_growth_a, c.fee_growth_b);
            i = i + 1;
        };

        pool.sqrt_price_x64 = w.sqrt_price;
        pool.tick_current = w.tick;
        pool.liquidity = w.liquidity;
        if (a_to_b) {
            pool.fee_growth_global_a = w.fee_growth_input;
        } else {
            pool.fee_growth_global_b = w.fee_growth_input;
        };

        event::emit(Swapped {
            pool_id: pool.id.to_inner(),
            a_to_b,
            amount_in: w.amount_in,
            amount_out: w.amount_out,
            protocol_fee: w.protocol_fee,
            lp_fee_pips: w.lp_fee,
            sqrt_price_x64: w.sqrt_price,
            liquidity: w.liquidity,
            tick_bits: w.tick.bits(),
        });

        (w.amount_in, w.amount_out, w.protocol_fee)
    }

    /// The tick-walking swap loop, read-only. Crossed ticks are
    /// recorded rather than folded so the walk can serve as a quote.
    fun walk<A, B>(
        pool: &Pool<A, B>,
        a_to_b: bool,
        exact_in: bool,
        amount: u64,
        sqrt_price_limit: u128,
        lp_fee_override: Option<u64>,
    ): Walk {
        assert!(amount > 0, ESwapAmountZero);

        // The limit must sit strictly between the current price and the
        // representable bound in the direction of travel.
        if (a_to_b) {
            assert!(sqrt_price_limit < pool.sqrt_price_x64, EPriceLimitAlreadyExceeded);
            assert!(sqrt_price_limit > tick_math::min_sqrt_price(), EPriceLimitOutOfBounds);
        } else {
            assert!(sqrt_price_limit > pool.sqrt_price_x64, EPriceLimitAlreadyExceeded);
            assert!(sqrt_price_limit < tick_math::max_sqrt_price(), EPriceLimitOutOfBounds);
        };

        let protocol_fee_pips = if (a_to_b) {
            pool.protocol_fee_a_to_b
        } else {
            pool.protocol_fee_b_to_a
        };
        let lp_fee = if (lp_fee_override.is_some()) {
            assert!(pool.is_dynamic_fee, EFeeOverrideOnStaticPool);
            let fee = lp_fee_override.destroy_some();
            assert!(fee <= swap_math::fee_scale(), ELpFeeTooLarge);
            fee
        } else {
            pool.lp_fee_pips
        };
        // Protocol fee applies to the gross input, LP fee to what is
        // left, so the combined rate is p + lp * (1 - p).
        let swap_fee = if (protocol_fee_pips == 0) {
            lp_fee
        } else {
            protocol_fee_pips + lp_fee
                - protocol_fee_pips * lp_fee / swap_math::fee_scale()
        };
        if (swap_fee >= swap_math::fee_scale()) {
            assert!(exact_in, EInvalidFeeForExactOut);
        };

        let mut amount_remaining = amount;
        // The other side of the trade, accumulated wide then narrowed.
        let mut amount_calculated: u128 = 0;
        let mut sqrt_price = pool.sqrt_price_x64;
        let mut tick_cur = pool.tick_current;
        let mut liq = pool.liquidity;
        let mut fee_growth_input = if (a_to_b) {
            pool.fee_growth_global_a
        } else {
            pool.fee_growth_global_b
        };
        let mut protocol_fee_total: u128 = 0;
        let mut crossings = vector[];

        while (amount_remaining > 0 && sqrt_price != sqrt_price_limit) {
            let sqrt_price_start = sqrt_price;

            let (mut tick_next, initialized) =
                pool.ticks.next_initialized_tick_within_one_word(tick_cur, a_to_b);
            // The bitmap is unaware of global tick bounds; clamp.
            if (i32::lt(tick_next, tick_math::min_tick())) {
                tick_next = tick_math::min_tick();
            };
            if (i32::gt(tick_next, tick_math::max_tick())) {
                tick_next = tick_math::max_tick();
            };
            let sqrt_price_next = tick_math::get_sqrt_price_at_tick(tick_next);
            let target =
                swap_math::get_target_sqrt_price(a_to_b, sqrt_price_next, sqrt_price_limit);

            let (new_sqrt_price, step_in, step_out, mut step_fee) =
                swap_math::compute_swap_step(
                    sqrt_price,
                    target,
                    liq,
                    amount_remaining,
                    exact_in,
                    swap_fee,
                );
            sqrt_price = new_sqrt_price;

            if (exact_in) {
                // compute_swap_step guarantees in + fee <= remaining.
                amount_remaining = amount_remaining - step_in - step_fee;
                amount_calculated = amount_calculated + (step_out as u128);
            } else {
                amount_remaining = amount_remaining - step_out;
                amount_calculated =
                    amount_calculated + (step_in as u128) + (step_fee as u128);
            };

            if (protocol_fee_pips > 0) {
                // When the LP fee is zero the whole fee is the
                // protocol's; otherwise the protocol's share is its
                // rate applied to the gross input of this step,
                // rounded down in favor of LPs.
                let delta = if (swap_fee == protocol_fee_pips) {
                    step_fee
                } else {
                    ((((step_in as u128) + (step_fee as u128))
                        * (protocol_fee_pips as u128)
                        / (swap_math::fee_scale() as u128)) as u64)
                };
                step_fee = step_fee - delta;
                protocol_fee_total = protocol_fee_total + (delta as u128);
            };

            if (liq > 0 && step_fee > 0) {
                fee_growth_input = math_u128::wrapping_add(
                    fee_growth_input,
                    ((((step_fee as u256) << 64) / (liq as u256)) as u128),
                );
            };

            if (sqrt_price == sqrt_price_next) {
                // Reached a tick boundary; cross it if initialized.
                if (initialized) {
                    let (fg_a, fg_b) = if (a_to_b) {
                        (fee_growth_input, pool.fee_growth_global_b)
                    } else {
                        (pool.fee_growth_global_a, fee_growth_input)
                    };
                    crossings.push_back(Crossing {
                        tick: tick_next,
                        fee_growth_a: fg_a,
                        fee_growth_b: fg_b,
                    });
                    let mut liquidity_net = pool.ticks.liquidity_net(tick_next);
                    // Moving down, in-range liquidity changes by the
                    // negated net amount.
                    if (a_to_b) {
                        liquidity_net = liquidity_net.neg();
                    };
                    liq = tick::add_liquidity_delta(liq, liquidity_net);
                };
                // Moving down, the region below the boundary belongs to
                // tick_next - 1. The stored tick may therefore end one
                // below the tick implied by the price when a swap stops
                // exactly on a boundary; donations credit the LPs of the
                // stored tick.
                tick_cur = if (a_to_b) {
                    i32::sub(tick_next, i32::from(1))
                } else {
                    tick_next
                };
            } else if (sqrt_price != sqrt_price_start) {
                tick_cur = tick_math::get_tick_at_sqrt_price(sqrt_price);
            };
        };

        assert!(protocol_fee_total <= (MAX_U64 as u128), EAmountOverflow);
        assert!(amount_calculated <= (MAX_U64 as u128), EAmountOverflow);
        let consumed = amount - amount_remaining;
        let (amount_in, amount_out) = if (exact_in) {
            (consumed, (amount_calculated as u64))
        } else {
            ((amount_calculated as u64), consumed)
        };

        Walk {
            amount_in,
            amount_out,
            protocol_fee: (protocol_fee_total as u64),
            lp_fee,
            sqrt_price,
            tick: tick_cur,
            liquidity: liq,
            fee_growth_input,
            crossings,
        }
    }

    // === Internals: liquidity ===

    fun add_liquidity_impl<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
        liquidity_delta: u128,
    ): AddLiquidityReceipt {
        assert!(liquidity_delta > 0, EZeroLiquidity);
        let (amount_a, amount_b) =
            pool.modify_liquidity(pos, i128::from(liquidity_delta));
        event::emit(LiquidityModified {
            pool_id: pool.id.to_inner(),
            position_id: object::id(pos),
            tick_lower_bits: pos.tick_lower().bits(),
            tick_upper_bits: pos.tick_upper().bits(),
            is_add: true,
            liquidity_delta,
            amount_a,
            amount_b,
            position_liquidity: pos.liquidity(),
            pool_liquidity: pool.liquidity,
        });
        AddLiquidityReceipt {
            pool_id: pool.id.to_inner(),
            amount_a,
            amount_b,
        }
    }

    fun remove_liquidity_impl<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
        liquidity_delta: u128,
    ): (Balance<A>, Balance<B>) {
        assert!(liquidity_delta > 0, EZeroLiquidity);
        let (amount_a, amount_b) =
            pool.modify_liquidity(pos, i128::neg_from(liquidity_delta));
        event::emit(LiquidityModified {
            pool_id: pool.id.to_inner(),
            position_id: object::id(pos),
            tick_lower_bits: pos.tick_lower().bits(),
            tick_upper_bits: pos.tick_upper().bits(),
            is_add: false,
            liquidity_delta,
            amount_a,
            amount_b,
            position_liquidity: pos.liquidity(),
            pool_liquidity: pool.liquidity,
        });
        (pool.balance_a.split(amount_a), pool.balance_b.split(amount_b))
    }

    fun collect_fees_impl<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
    ): (Balance<A>, Balance<B>) {
        pool.assert_version();
        assert!(pos.pool_id() == pool.id.to_inner(), EPositionPoolMismatch);
        // Bring the fee checkpoint up to now (a zero-delta touch), then
        // pay out everything owed. Skipped for empty positions, whose
        // owed amounts are already final.
        if (pos.liquidity() > 0) {
            let (fg_in_a, fg_in_b) = pool.ticks.get_fee_growth_inside(
                pos.tick_lower(),
                pos.tick_upper(),
                pool.tick_current,
                pool.fee_growth_global_a,
                pool.fee_growth_global_b,
            );
            pos.update(i128::zero(), fg_in_a, fg_in_b);
        };
        let (owed_a, owed_b) = pos.take_fees_owed();
        event::emit(FeesCollected {
            pool_id: pool.id.to_inner(),
            position_id: object::id(pos),
            amount_a: owed_a,
            amount_b: owed_b,
        });
        (pool.balance_a.split(owed_a), pool.balance_b.split(owed_b))
    }

    /// Shared liquidity-change core. Returns the unsigned principal
    /// amounts: owed to the pool when adding, owed to the caller when
    /// removing. Rounding always favors the pool (up when adding, down
    /// when removing).
    fun modify_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        pos: &mut Position,
        liquidity_delta: I128,
    ): (u64, u64) {
        pool.assert_version();
        assert!(pos.pool_id() == pool.id.to_inner(), EPositionPoolMismatch);
        let lower = pos.tick_lower();
        let upper = pos.tick_upper();
        let removing = liquidity_delta.is_neg();

        // 1. Update boundary ticks (this also applies the fee-growth
        //    initialization convention for fresh ticks).
        let flipped_lower = pool.ticks.update(
            lower,
            pool.tick_current,
            liquidity_delta,
            pool.fee_growth_global_a,
            pool.fee_growth_global_b,
            false,
        );
        let flipped_upper = pool.ticks.update(
            upper,
            pool.tick_current,
            liquidity_delta,
            pool.fee_growth_global_a,
            pool.fee_growth_global_b,
            true,
        );

        // 2. Settle the position's fees against checkpoints that still
        //    exist (emptied ticks are cleared only afterwards).
        let (fg_in_a, fg_in_b) = pool.ticks.get_fee_growth_inside(
            lower,
            upper,
            pool.tick_current,
            pool.fee_growth_global_a,
            pool.fee_growth_global_b,
        );
        pos.update(liquidity_delta, fg_in_a, fg_in_b);

        // 3. Drop storage for ticks no position references anymore.
        if (removing) {
            if (flipped_lower) {
                pool.ticks.clear(lower);
            };
            if (flipped_upper) {
                pool.ticks.clear(upper);
            };
        };

        // 4. Principal amounts depend on where the current price sits
        //    relative to the range; a range that straddles the price
        //    also changes the pool's in-range liquidity right now.
        if (i32::gte(pool.tick_current, lower) && i32::lt(pool.tick_current, upper)) {
            pool.liquidity = tick::add_liquidity_delta(pool.liquidity, liquidity_delta);
        };
        pool.amounts_for_liquidity(lower, upper, liquidity_delta.abs_u128(), !removing)
    }

    fun donate_impl<A, B>(
        pool: &mut Pool<A, B>,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
    ) {
        pool.assert_version();
        assert!(pool.liquidity > 0, ENoLiquidityToReceiveFees);
        let amount_a = balance_a.value();
        let amount_b = balance_b.value();
        if (amount_a > 0) {
            pool.fee_growth_global_a = math_u128::wrapping_add(
                pool.fee_growth_global_a,
                ((((amount_a as u256) << 64) / (pool.liquidity as u256)) as u128),
            );
        };
        if (amount_b > 0) {
            pool.fee_growth_global_b = math_u128::wrapping_add(
                pool.fee_growth_global_b,
                ((((amount_b as u256) << 64) / (pool.liquidity as u256)) as u128),
            );
        };
        pool.balance_a.join(balance_a);
        pool.balance_b.join(balance_b);
        event::emit(Donated {
            pool_id: pool.id.to_inner(),
            amount_a,
            amount_b,
        });
    }

    // === Internals: guards ===

    fun assert_version<A, B>(pool: &Pool<A, B>) {
        assert!(pool.version == VERSION, EVersionMismatch);
    }

    /// For plain entry points: abort if this operation class is gated.
    fun assert_no_hook_gate<A, B>(pool: &Pool<A, B>, permission: u8) {
        pool.assert_version();
        assert!(pool.hook_permissions & permission == 0, EHookRequired);
    }

    /// For hook entry points: the witness type must be the pool's hook.
    fun assert_hook<A, B, W: drop>(pool: &Pool<A, B>) {
        pool.assert_version();
        pool.assert_hook_type<A, B, W>();
    }

    fun assert_hook_type<A, B, W: drop>(pool: &Pool<A, B>) {
        assert!(pool.hook.is_some(), EWrongHook);
        assert!(
            pool.hook.borrow() == type_name::with_defining_ids<W>(),
            EWrongHook,
        );
    }
}
