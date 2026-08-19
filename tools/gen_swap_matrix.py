# Copyright (c) Haneul Labs
# SPDX-License-Identifier: Apache-2.0
#
# Generates tests/swap_matrix_vectors.move: reference-pinned expected
# values for the swap matrix suite.
#
# The matrix: 4 liquidity topologies x 4 fee configurations = 16 pools;
# each pool runs 12 chained swaps (3 amounts x 2 directions x
# exact-in/exact-out) in a fixed order, so later cases execute on state
# evolved by earlier ones. Every case pins 8 state fields produced by
# the independent big-integer reference (clamm_ref.py).
#
# Run:  python3 tools/gen_swap_matrix.py > tests/swap_matrix_vectors.move

import clamm_ref as ref

SPACING = 60
PRICE_1 = 1 << 64

# (lower, upper, liquidity) per topology.
TOPOLOGIES = [
    # T0: single full-range position.
    [(-443580, 443580, 10**12)],
    # T1: full range plus a concentrated inner band.
    [(-443580, 443580, 10**12), (-600, 600, 5 * 10**12)],
    # T2: thin full range with two side bands and a gap at the price.
    [(-443580, 443580, 10**9), (-1200, -600, 3 * 10**12), (600, 1200, 3 * 10**12)],
    # T3: two bands meeting exactly at the starting tick (net zero
    # liquidity at tick 0, but the tick is initialized).
    [(-600, 0, 2 * 10**12), (0, 600, 2 * 10**12)],
]

# (lp_fee_pips, protocol_fee_pips) per fee configuration.
FEE_CONFIGS = [(500, 0), (3000, 0), (10000, 0), (3000, 1000)]

AMOUNTS = [1_000, 1_000_000_000, 50_000_000_000]


def run():
    cases = []
    for topo_idx, topo in enumerate(TOPOLOGIES):
        for fee_idx, (lp_fee, protocol_fee) in enumerate(FEE_CONFIGS):
            pool = ref.Pool(lp_fee, SPACING, PRICE_1)
            pool.protocol_fee_a_to_b = protocol_fee
            pool.protocol_fee_b_to_a = protocol_fee
            for lower, upper, liq in topo:
                pool.add_position(lower, upper, liq)
            for amount in AMOUNTS:
                for a_to_b in (True, False):
                    for exact_in in (True, False):
                        limit = (
                            ref.MIN_SQRT_PRICE + 1
                            if a_to_b
                            else ref.MAX_SQRT_PRICE - 1
                        )
                        amount_in, amount_out, pf = pool.swap(
                            a_to_b, exact_in, amount, limit
                        )
                        cases.append({
                            "pool": topo_idx * len(FEE_CONFIGS) + fee_idx,
                            "a_to_b": a_to_b,
                            "exact_in": exact_in,
                            "amount": amount,
                            "in": amount_in,
                            "out": amount_out,
                            "pf": pf,
                            "price": pool.sqrt_price,
                            "tick_bits": ref.i32_bits(pool.tick_current),
                            "liq": pool.liquidity,
                            "fga": pool.fee_growth_a,
                            "fgb": pool.fee_growth_b,
                        })
    return cases


def move_vec(name, values, typ):
    body = ", ".join(str(v) for v in values)
    return (
        f"    public fun {name}(): vector<{typ}> {{\n"
        f"        vector[{body}]\n"
        f"    }}\n"
    )


def move_vec_bool(name, values):
    body = ", ".join("true" if v else "false" for v in values)
    return (
        f"    public fun {name}(): vector<bool> {{\n"
        f"        vector[{body}]\n"
        f"    }}\n"
    )


def main():
    cases = run()
    lines = []
    lines.append("// Copyright (c) Haneul Labs")
    lines.append("// SPDX-License-Identifier: Apache-2.0")
    lines.append("")
    lines.append("/// GENERATED FILE - do not edit by hand.")
    lines.append("/// Produced by tools/gen_swap_matrix.py from the independent")
    lines.append("/// big-integer reference (tools/clamm_ref.py). Each index is one")
    lines.append("/// chained swap case; see swap_matrix_tests.move for the driver")
    lines.append("/// and tools/gen_swap_matrix.py for the matrix definition.")
    lines.append("#[test_only]")
    lines.append("module haneul_amm::swap_matrix_vectors {")
    lines.append(move_vec("pool_index", [c["pool"] for c in cases], "u8"))
    lines.append(move_vec_bool("a_to_b", [c["a_to_b"] for c in cases]))
    lines.append(move_vec_bool("exact_in", [c["exact_in"] for c in cases]))
    lines.append(move_vec("amount", [c["amount"] for c in cases], "u64"))
    lines.append(move_vec("expected_in", [c["in"] for c in cases], "u64"))
    lines.append(move_vec("expected_out", [c["out"] for c in cases], "u64"))
    lines.append(move_vec("expected_protocol_fee", [c["pf"] for c in cases], "u64"))
    lines.append(move_vec("expected_sqrt_price", [c["price"] for c in cases], "u128"))
    lines.append(move_vec("expected_tick_bits", [c["tick_bits"] for c in cases], "u32"))
    lines.append(move_vec("expected_liquidity", [c["liq"] for c in cases], "u128"))
    lines.append(move_vec("expected_fee_growth_a", [c["fga"] for c in cases], "u128"))
    lines.append(move_vec("expected_fee_growth_b", [c["fgb"] for c in cases], "u128"))
    lines.append("}")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
