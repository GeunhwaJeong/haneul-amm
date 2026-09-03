// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Pool discovery, uniqueness, and the protocol-wide defaults.
///
/// Anyone may create a pool. The registry guarantees that at most one
/// pool exists per (currency pair, fee, tick spacing, hook) parameter
/// set, so integrators can resolve a canonical pool for a market
/// instead of guessing among duplicates. Currency pairs are stored in
/// a single canonical order (lexicographic by fully qualified type
/// name), which also rules out an (A, B) / (B, A) doppelganger.
///
/// # Fee tiers
///
/// Hookless pools may only use an enabled (LP fee, tick spacing) pair.
/// Without that, every fee and spacing a creator can type is a
/// distinct canonical pool, and liquidity for one market scatters
/// across near-duplicates that no router can aggregate. Tiers are
/// enabled by the `ProtocolCap` holder and never disabled: pools that
/// exist must stay creatable-looking to integrators. The registry
/// starts with four: 0.01% / 1, 0.05% / 10, 0.3% / 60, 1% / 200.
/// Hooked pools are exempt; a hook is a deployed package that has
/// consented to the pool, not a typo.
///
/// # Default protocol fee
///
/// New pools start with the registry's default protocol fee rather
/// than zero, so turning the fee on does not require touching every
/// pool ever created; per-pool `set_protocol_fee` still overrides.
module haneul_amm::registry {
    use haneul::event;
    use haneul::table::{Self, Table};
    use haneul::vec_set::{Self, VecSet};
    use std::type_name::{Self, TypeName};
    use haneul_amm::pool::{Self, ProtocolCap};

    /// Package was upgraded; call `migrate` first.
    const EVersionMismatch: u64 = 0;
    /// Currency types must be distinct and in canonical order.
    const ECurrenciesOutOfOrder: u64 = 1;
    /// A pool with these exact parameters already exists.
    const EPoolAlreadyExists: u64 = 2;
    /// Unknown hook permission bits.
    const EInvalidHookPermissions: u64 = 3;
    /// A hook that gates nothing and controls no dynamic fee is a
    /// misconfiguration, not a pool variant.
    const EUselessHook: u64 = 4;
    /// Nothing is migrated on an up-to-date object.
    const ENotUpgraded: u64 = 5;
    /// Hookless pools must use an enabled (fee, tick spacing) tier.
    const EFeeTierNotEnabled: u64 = 6;
    /// The tier is already enabled.
    const EFeeTierAlreadyEnabled: u64 = 7;

    const VERSION: u64 = 1;

    /// All hook permission bits that exist.
    const ALL_HOOK_PERMISSIONS: u8 = 0xF;

    public struct Registry has key {
        id: UID,
        version: u64,
        pools: Table<PoolKey, ID>,
        /// Enabled (LP fee, tick spacing) pairs for hookless pools.
        fee_tiers: VecSet<FeeTier>,
        /// Applied to every new pool; per direction, in pips.
        default_protocol_fee_a_to_b: u64,
        default_protocol_fee_b_to_a: u64,
    }

    public struct FeeTier has copy, drop, store {
        lp_fee_pips: u64,
        tick_spacing: u32,
    }

    public struct FeeTierEnabled has copy, drop {
        lp_fee_pips: u64,
        tick_spacing: u32,
    }

    public struct DefaultProtocolFeeSet has copy, drop {
        fee_a_to_b_pips: u64,
        fee_b_to_a_pips: u64,
    }

    public struct PoolKey has copy, drop, store {
        coin_a: TypeName,
        coin_b: TypeName,
        lp_fee_pips: u64,
        is_dynamic_fee: bool,
        tick_spacing: u32,
        hook: Option<TypeName>,
    }

    public(package) fun create(ctx: &mut TxContext) {
        let mut registry = Registry {
            id: object::new(ctx),
            version: VERSION,
            pools: table::new(ctx),
            fee_tiers: vec_set::empty(),
            default_protocol_fee_a_to_b: 0,
            default_protocol_fee_b_to_a: 0,
        };
        registry.add_fee_tier(100, 1);
        registry.add_fee_tier(500, 10);
        registry.add_fee_tier(3000, 60);
        registry.add_fee_tier(10000, 200);
        transfer::share_object(registry);
    }

    /// Create a hookless, static-fee pool on an enabled fee tier.
    /// Permissionless.
    public fun create_pool<A, B>(
        registry: &mut Registry,
        lp_fee_pips: u64,
        tick_spacing: u32,
        sqrt_price_x64: u128,
        ctx: &mut TxContext,
    ): ID {
        assert!(
            registry.is_fee_tier_enabled(lp_fee_pips, tick_spacing),
            EFeeTierNotEnabled,
        );
        registry.register<A, B>(
            lp_fee_pips,
            false,
            tick_spacing,
            option::none(),
            0,
            sqrt_price_x64,
            ctx,
        )
    }

    /// Create a pool bound to hook witness `W`. Requiring an instance
    /// of `W` means only the hook's own package can bind pools to it,
    /// so a hook always consents to (and can configure) the pools it
    /// supervises. `hook_permissions` fixes forever which operation
    /// classes must route through the hook (see `pool::hook_on_*`).
    /// `is_dynamic_fee` lets the hook adjust the LP fee later and
    /// requires `lp_fee_pips == 0` at creation.
    public fun create_pool_with_hook<A, B, W: drop>(
        registry: &mut Registry,
        _witness: W,
        lp_fee_pips: u64,
        is_dynamic_fee: bool,
        tick_spacing: u32,
        hook_permissions: u8,
        sqrt_price_x64: u128,
        ctx: &mut TxContext,
    ): ID {
        assert!(hook_permissions <= ALL_HOOK_PERMISSIONS, EInvalidHookPermissions);
        assert!(hook_permissions != 0 || is_dynamic_fee, EUselessHook);
        registry.register<A, B>(
            lp_fee_pips,
            is_dynamic_fee,
            tick_spacing,
            option::some(type_name::with_defining_ids<W>()),
            hook_permissions,
            sqrt_price_x64,
            ctx,
        )
    }

    /// Whether a pool with these parameters exists, and its ID.
    public fun find_pool<A, B>(
        registry: &Registry,
        lp_fee_pips: u64,
        is_dynamic_fee: bool,
        tick_spacing: u32,
        hook: Option<TypeName>,
    ): Option<ID> {
        let key = PoolKey {
            coin_a: type_name::with_defining_ids<A>(),
            coin_b: type_name::with_defining_ids<B>(),
            lp_fee_pips,
            is_dynamic_fee,
            tick_spacing,
            hook,
        };
        if (registry.pools.contains(key)) {
            option::some(*registry.pools.borrow(key))
        } else {
            option::none()
        }
    }

    public fun pool_count(registry: &Registry): u64 {
        registry.pools.length()
    }

    public fun is_fee_tier_enabled(
        registry: &Registry,
        lp_fee_pips: u64,
        tick_spacing: u32,
    ): bool {
        registry.fee_tiers.contains(&FeeTier { lp_fee_pips, tick_spacing })
    }

    /// Every enabled tier as (lp_fee_pips, tick_spacing) pairs.
    public fun fee_tiers(registry: &Registry): vector<FeeTier> {
        registry.fee_tiers.into_keys()
    }

    public fun fee_tier_lp_fee_pips(tier: &FeeTier): u64 {
        tier.lp_fee_pips
    }

    public fun fee_tier_tick_spacing(tier: &FeeTier): u32 {
        tier.tick_spacing
    }

    /// The protocol fee new pools start with: (a_to_b, b_to_a) pips.
    public fun default_protocol_fee(registry: &Registry): (u64, u64) {
        (registry.default_protocol_fee_a_to_b, registry.default_protocol_fee_b_to_a)
    }

    // === Administration ===

    /// Enable a (LP fee, tick spacing) tier for hookless pools. Tiers
    /// cannot be disabled.
    public fun enable_fee_tier(
        registry: &mut Registry,
        _cap: &ProtocolCap,
        lp_fee_pips: u64,
        tick_spacing: u32,
    ) {
        assert!(registry.version == VERSION, EVersionMismatch);
        pool::assert_lp_fee(lp_fee_pips);
        pool::assert_tick_spacing(tick_spacing);
        assert!(
            !registry.is_fee_tier_enabled(lp_fee_pips, tick_spacing),
            EFeeTierAlreadyEnabled,
        );
        registry.add_fee_tier(lp_fee_pips, tick_spacing);
    }

    /// Set the protocol fee applied to pools created from now on.
    /// Existing pools keep theirs; use `pool::set_protocol_fee`.
    public fun set_default_protocol_fee(
        registry: &mut Registry,
        _cap: &ProtocolCap,
        fee_a_to_b_pips: u64,
        fee_b_to_a_pips: u64,
    ) {
        assert!(registry.version == VERSION, EVersionMismatch);
        pool::assert_protocol_fees(fee_a_to_b_pips, fee_b_to_a_pips);
        registry.default_protocol_fee_a_to_b = fee_a_to_b_pips;
        registry.default_protocol_fee_b_to_a = fee_b_to_a_pips;
        event::emit(DefaultProtocolFeeSet { fee_a_to_b_pips, fee_b_to_a_pips });
    }

    /// Bring an old registry object up to the current package version.
    public fun migrate(registry: &mut Registry, _cap: &ProtocolCap) {
        assert!(registry.version < VERSION, ENotUpgraded);
        registry.version = VERSION;
    }

    // === Internals ===

    fun register<A, B>(
        registry: &mut Registry,
        lp_fee_pips: u64,
        is_dynamic_fee: bool,
        tick_spacing: u32,
        hook: Option<TypeName>,
        hook_permissions: u8,
        sqrt_price_x64: u128,
        ctx: &mut TxContext,
    ): ID {
        assert!(registry.version == VERSION, EVersionMismatch);

        let coin_a = type_name::with_defining_ids<A>();
        let coin_b = type_name::with_defining_ids<B>();
        assert!(is_strictly_ordered(&coin_a, &coin_b), ECurrenciesOutOfOrder);

        let key = PoolKey {
            coin_a,
            coin_b,
            lp_fee_pips,
            is_dynamic_fee,
            tick_spacing,
            hook,
        };
        assert!(!registry.pools.contains(key), EPoolAlreadyExists);

        let p = pool::new<A, B>(
            lp_fee_pips,
            is_dynamic_fee,
            tick_spacing,
            hook,
            hook_permissions,
            registry.default_protocol_fee_a_to_b,
            registry.default_protocol_fee_b_to_a,
            sqrt_price_x64,
            ctx,
        );
        let pool_id = object::id(&p);
        registry.pools.add(key, pool_id);
        pool::share(p);
        pool_id
    }

    fun add_fee_tier(registry: &mut Registry, lp_fee_pips: u64, tick_spacing: u32) {
        registry.fee_tiers.insert(FeeTier { lp_fee_pips, tick_spacing });
        event::emit(FeeTierEnabled { lp_fee_pips, tick_spacing });
    }

    /// Lexicographic comparison of fully qualified type names; strict,
    /// so equal types (an A/A pool) are rejected too.
    fun is_strictly_ordered(a: &TypeName, b: &TypeName): bool {
        let a_bytes = a.as_string().as_bytes();
        let b_bytes = b.as_string().as_bytes();
        let a_len = a_bytes.length();
        let b_len = b_bytes.length();
        let shorter = if (a_len < b_len) a_len else b_len;
        let mut i = 0;
        while (i < shorter) {
            let (ca, cb) = (a_bytes[i], b_bytes[i]);
            if (ca != cb) return ca < cb;
            i = i + 1;
        };
        a_len < b_len
    }
}
