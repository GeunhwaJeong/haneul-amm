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
a witness type owned by another package. Binding takes both an
instance of the witness and the `Publisher` of the package that
defines it, so only the hook's deployer (or code the hook exposes for
the purpose) can create pools for a hook, and a type anyone can
construct, such as a primitive or another package's struct, can never
be bound. Operation classes the pool was configured to gate (swaps,
liquidity changes, donations) then accept only the `*_with_hook` entry
points, which demand an instance of the witness. As long as the hook
keeps its witness constructor private, every gated operation must
route through hook code. Which classes are gated is immutable after
creation, and dynamic-fee pools let their hook re-tune the LP fee per
pool or per swap.

**Positions as objects.** A liquidity position is an owned object.
Ownership is the access control, wallets can display it, and other
packages can build on top of it without any registry or approval
system.

**No pause, no custody.** There is no administrative path that can
hold or move liquidity: a provider can always remove a position and
collect its fees. The protocol capability administers fee tiers and
protocol fees and gates package upgrades through a version check;
that is the whole of its power over live pools.

**Exact math, one word wide.** Prices are square roots in Q32.64 fixed
point over a tick range of plus or minus 443636 (a price span of
2^128). That representation keeps every intermediate product of the
math inside native `u256` arithmetic at full precision, with rounding
always directed in the pool's favor. Amounts are compared against a
swap's budget at full width before being narrowed to coin width, so a
range too deep for a coin balance stops a swap inside it rather than
failing it. The tick conversion functions are exact and are pinned
bit-for-bit by test vectors from an independent big-integer reference
implementation (`tools/clamm_ref.py`), which mirrors the whole engine.

## Package layout

The repository holds two packages that mirror the classic core and
periphery split: the core is meant to be frozen, the periphery is
meant to be replaced as better versions are written.

**Core** (`/`) holds the funds and the invariants:

| Module | Purpose |
| --- | --- |
| `pool` | Swap engine, liquidity management, donations, flash loans, fees, read-only simulation |
| `registry` | Pool creation, uniqueness, discovery, fee tiers, protocol fee defaults |
| `position` | Owned position objects and fee checkpointing |
| `tick` | Per-tick state and the initialized-tick bitmap |
| `tick_math` | Tick index to sqrt price conversions, both exact |
| `sqrt_price_math` | Price movement and token amounts from liquidity |
| `swap_math` | Single-step swap computation and fee carving |
| `i32`, `i128` | Checked signed arithmetic over unsigned words |
| `math_u128`, `math_u256` | Widening, wrapping, and bit-scan helpers |

**Periphery** (`/periphery`) holds the guards users need and the core
deliberately omits. It builds only on the core's public API:

| Module | Purpose |
| --- | --- |
| `router` | Swaps with minimum-output / maximum-input bounds, deadlines, and all-or-nothing fills |
| `liquidity` | Position management in coin terms: budgets in, liquidity out, change back |
| `liquidity_amounts` | Token amounts to liquidity conversion for a price range |
| `quoter` | Exact read-only swap quotes over the core's `simulate_swap` view |

Multi-hop routing needs no path encoding here: chain single hops in
one programmable transaction and put the real minimum on the final
hop. Pools whose operations are hook-gated are served by their hook's
package instead of this router.

## Fees

LP fees are configured per pool in pips (hundredths of a basis point,
1,000,000 = 100%), either fixed at creation or dynamic under hook
control. Hookless pools must use an enabled fee tier, a (fee, tick
spacing) pair; the registry starts with 0.01% / 1, 0.05% / 10,
0.3% / 60 and 1% / 200, and the `ProtocolCap` holder can enable more
but never disable one. Hooked pools choose freely, since the hook
package consents to the pool it is bound to and proves it with its
`Publisher`.

A protocol fee of up to 0.1% per direction is carved from the swap
input before the LP fee. New pools start with the registry's default
(zero until set); the `ProtocolCap` holder can change the default for
future pools and override it per pool.

Flash loans are free: the receipt forces exact repayment in the same
transaction, so the pool takes no risk and charges nothing.

## Status

This package is in active development and has not been audited. Do not
deploy it against real value.

## Building and testing

```bash
haneul move test --build-env mainnet             # core
cd periphery && haneul move test --build-env mainnet
```

The `--build-env` flag selects the framework dependency set; the
packages themselves have no environment-specific code.

The core suite (135 tests) covers the math layer with reference-pinned
vectors, tick bitmap navigation, the full swap pipeline including tick
crossing and fee attribution (a 192-case chained swap matrix and a
ledger-identity sequence), receipt enforcement, hook gating, dynamic
fees, fee tiers, and the edges of the domain (tick ceiling, per-tick
cap, coin width). The periphery suite (33 tests) pins the router
guards, liquidity conversion, and quoter against the same reference
scenarios, including quote-then-execute equality across fee tiers.

`tools/clamm_ref.py` is the reference engine and
`tools/gen_swap_matrix.py` regenerates `tests/swap_matrix_vectors.move`
from it; the generated file must not change unless the engine's
semantics do.

## License

Apache-2.0. See [LICENSE](LICENSE).
