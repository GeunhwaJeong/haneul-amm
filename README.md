# Haneul AMM

A concentrated liquidity automated market maker for the Haneul
blockchain, written in Move.

Haneul AMM implements the full concentrated liquidity model: liquidity
providers allocate capital to explicit price ranges (tick ranges), the
pool tracks a single aggregated curve per market, and swaps walk the
tick space with exact fixed-point arithmetic. On top of that base it
adds a settlement and extension architecture designed around Move's
type system rather than ported around it.

## Design highlights

**Receipts instead of trust.** Every operation that lets value leave
the pool before payment arrives returns a receipt with no abilities.
Such a value cannot be dropped, stored, or transferred, so the
transaction cannot complete until the matching `repay_*` call consumes
it with exact payment. Deferred settlement, flash loans, and
output-funds-the-input routing all fall out of this one mechanism, and
"all debts settle before the end" is enforced by the type system at
compile time instead of by a runtime counter.

**Hooks as witness types.** A pool may be bound at creation to a hook:
a witness type owned by another package. Operation classes the pool
was configured to gate (swaps, liquidity changes, donations) then
accept only the `*_with_hook` entry points, which demand an instance
of the witness. Only the hook's package can construct its witness, so
every gated operation must route through hook code. Which classes are
gated is immutable after creation, and dynamic-fee pools let their
hook re-tune the LP fee per pool or per swap.

**Positions as objects.** A liquidity position is an owned object.
Ownership is the access control, wallets can display it, and other
packages can build on top of it without any registry or approval
system.

**Exact math, one word wide.** Prices are square roots in Q32.64 fixed
point over a tick range of plus or minus 443636 (a price span of
2^128). That representation keeps every intermediate product of the
math inside native `u256` arithmetic at full precision, with rounding
always directed in the pool's favor. The tick conversion functions are
exact and are pinned bit-for-bit by test vectors from an independent
big-integer reference implementation.

## Module map

| Module | Purpose |
| --- | --- |
| `pool` | Swap engine, liquidity management, donations, flash loans, fees |
| `registry` | Pool creation, uniqueness, and discovery |
| `position` | Owned position objects and fee checkpointing |
| `tick` | Per-tick state and the initialized-tick bitmap |
| `tick_math` | Tick index to sqrt price conversions, both exact |
| `sqrt_price_math` | Price movement and token amounts from liquidity |
| `swap_math` | Single-step swap computation and fee carving |
| `i32`, `i128` | Checked signed arithmetic over unsigned words |
| `math_u128`, `math_u256` | Widening, wrapping, and bit-scan helpers |

## Fees

LP fees are configured per pool in pips (hundredths of a basis point,
1,000,000 = 100%), either fixed at creation or dynamic under hook
control. A protocol fee of up to 0.1% per direction can be switched on
by the holder of the `ProtocolCap`; it is carved from the swap input
before the LP fee.

## Status

This package is in active development and has not been audited. Do not
deploy it against real value.

## Building and testing

```bash
haneul move build
haneul move test
```

The test suite (111 tests) covers the math layer with reference-pinned
vectors, tick bitmap navigation, the full swap pipeline including tick
crossing and fee attribution, receipt enforcement, hook gating, and
dynamic fees.

## License

Apache-2.0. See [LICENSE](LICENSE).
