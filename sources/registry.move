// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Pool discovery and uniqueness.
///
/// Anyone may create a pool. The registry guarantees that at most one
/// pool exists per (currency pair, fee, tick spacing, hook) parameter
/// set, so integrators can resolve a canonical pool for a market
/// instead of guessing among duplicates. Currency pairs are stored in
/// a single canonical order (lexicographic by fully qualified type
/// name), which also rules out an (A, B) / (B, A) doppelganger.
module haneul_amm::registry {
    use haneul::table::{Self, Table};
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

    const VERSION: u64 = 1;

    /// All hook permission bits that exist.
    const ALL_HOOK_PERMISSIONS: u8 = 0xF;

    public struct Registry has key {
        id: UID,
        version: u64,
        pools: Table<PoolKey, ID>,
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
        transfer::share_object(Registry {
            id: object::new(ctx),
            version: VERSION,
            pools: table::new(ctx),
        });
    }

    /// Create a hookless, static-fee pool. Permissionless.
    public fun create_pool<A, B>(
        registry: &mut Registry,
        lp_fee_pips: u64,
        tick_spacing: u32,
        sqrt_price_x64: u128,
        ctx: &mut TxContext,
    ): ID {
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
            sqrt_price_x64,
            ctx,
        );
        let pool_id = object::id(&p);
        registry.pools.add(key, pool_id);
        pool::share(p);
        pool_id
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
