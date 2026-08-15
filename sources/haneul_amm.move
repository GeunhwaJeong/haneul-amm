// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Package initialization: shares the pool registry, mints the
/// protocol capability, and registers the display standard for
/// positions so wallets can render them.
module haneul_amm::haneul_amm {
    use haneul::display;
    use haneul::package;
    use std::string::utf8;
    use haneul_amm::pool;
    use haneul_amm::position::Position;
    use haneul_amm::registry;

    /// One-time witness.
    public struct HANEUL_AMM has drop {}

    fun init(otw: HANEUL_AMM, ctx: &mut TxContext) {
        registry::create(ctx);
        transfer::public_transfer(pool::new_protocol_cap(ctx), ctx.sender());

        let publisher = package::claim(otw, ctx);
        let mut position_display = display::new<Position>(&publisher, ctx);
        position_display.add(
            utf8(b"name"),
            utf8(b"Haneul AMM Liquidity Position"),
        );
        position_display.add(
            utf8(b"description"),
            utf8(b"A concentrated liquidity position on a Haneul AMM pool."),
        );
        position_display.update_version();
        transfer::public_transfer(position_display, ctx.sender());
        transfer::public_transfer(publisher, ctx.sender());
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(HANEUL_AMM {}, ctx);
    }
}
