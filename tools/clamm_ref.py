# Copyright (c) Haneul Labs
# SPDX-License-Identifier: Apache-2.0
#
# Independent big-integer reference of the haneul_amm swap engine.
#
# Every function mirrors its Move counterpart operation by operation
# (same widening, same rounding direction, same abort conditions), so
# results match the on-chain engine bit for bit. Used by
# gen_swap_matrix.py to produce pinned test vectors, and kept in the
# repo so the reference survives scratchpad lifetimes.
#
# Mirrored modules: tick_math, sqrt_price_math, swap_math, and the
# pool swap engine / modify_liquidity principal math from pool.move.

MAX_U64 = (1 << 64) - 1
MAX_U128 = (1 << 128) - 1
MAX_U256 = (1 << 256) - 1

FEE_SCALE = 1_000_000

MAX_TICK = 443636
MIN_SQRT_PRICE = 4295048017
MAX_SQRT_PRICE = 79226673515401279992447579062

LOG_SCALE = 255738958999603826347141
ERR_LOW = 3402992956809132418596140100660247210
ERR_HIGH = 291339464771989622907027621153398088495

_TICK_CONSTANTS = [
    0xFFFCB933BD6FAD37AA2D162D1A594001,
    0xFFF97272373D413259A46990580E213A,
    0xFFF2E50F5F656932EF12357CF3C7FDCC,
    0xFFE5CACA7E10E4E61C3624EAA0941CD0,
    0xFFCB9843D60F6159C9DB58835C926644,
    0xFF973B41FA98C081472E6896DFB254C0,
    0xFF2EA16466C96A3843EC78B326B52861,
    0xFE5DEE046A99A2A811C461F1969C3053,
    0xFCBE86C7900A88AEDCFFC83B479AA3A4,
    0xF987A7253AC413176F2B074CF7815E54,
    0xF3392B0822B70005940C7A398E4B70F3,
    0xE7159475A2C29B7443B29C7FA6E889D9,
    0xD097F3BDFD2022B8845AD8F792AA5825,
    0xA9F746462D870FDF8A65DC1F90E061E5,
    0x70D869A156D2A1B890BB3DF62BAF32F7,
    0x31BE135F97D08FD981231505542FCFA6,
    0x9AA508B5B7A84E1C677DE54F3E99BC9,
    0x5D6AF8DEDB81196699C329225EE604,
    0x2216E584F5FA1EA926041BEDFE98,
]


class MoveAbort(Exception):
    """Stand-in for a Move abort; message names the Move error."""


def _require(cond, name):
    if not cond:
        raise MoveAbort(name)


# === tick_math ===

def get_sqrt_price_at_tick(tick: int) -> int:
    abs_tick = abs(tick)
    _require(abs_tick <= MAX_TICK, "EInvalidTick")
    price = _TICK_CONSTANTS[0] if (abs_tick & 1) else (1 << 128)
    for i in range(1, 19):
        if abs_tick & (1 << i):
            price = (price * _TICK_CONSTANTS[i]) >> 128
    if tick > 0:
        price = MAX_U256 // price
    return (price + (1 << 64) - 1) >> 64


def _msb(x: int) -> int:
    assert x > 0
    return x.bit_length() - 1


def get_tick_at_sqrt_price(sqrt_price_x64: int) -> int:
    _require(
        MIN_SQRT_PRICE <= sqrt_price_x64 < MAX_SQRT_PRICE, "EInvalidSqrtPrice"
    )
    price = sqrt_price_x64 << 64
    m = _msb(price)
    if m >= 128:
        r = price >> (m - 127)
    else:
        r = price << (127 - m)

    neg = m < 128
    log2_mag = ((128 - m) << 64) if neg else ((m - 128) << 64)

    for shift in range(63, 49, -1):
        r = (r * r) >> 127
        if (r >> 128) == 1:
            if neg:
                log2_mag -= 1 << shift
            else:
                log2_mag += 1 << shift
            r >>= 1

    scaled = log2_mag * LOG_SCALE
    tick_low = _shr128_floor_signed(neg, scaled, True, ERR_LOW)
    tick_high = _shr128_floor_signed(neg, scaled, False, ERR_HIGH)

    if tick_low == tick_high:
        return tick_low
    if get_sqrt_price_at_tick(tick_high) <= sqrt_price_x64:
        return tick_high
    return tick_low


def _shr128_floor_signed(a_neg, a_mag, b_neg, b_mag):
    if a_neg == b_neg:
        neg, mag = a_neg, a_mag + b_mag
    elif a_mag >= b_mag:
        neg, mag = a_neg, a_mag - b_mag
    else:
        neg, mag = b_neg, b_mag - a_mag
    if neg:
        return -((mag + (1 << 128) - 1) >> 128)
    return mag >> 128


# === math helpers (math_u256 / math_u128 mirrors) ===

def div_round(n: int, d: int, round_up: bool) -> int:
    q = n // d
    if round_up and n % d:
        q += 1
    return q


def checked_shlw(n: int) -> int:
    _require(n < (1 << 192), "checked_shlw overflow")
    return n << 64


# === sqrt_price_math ===

def next_sqrt_price_from_amount_a_rounding_up(sqrt_price, liquidity, amount, add):
    if amount == 0:
        return sqrt_price
    liquidity_shl = liquidity << 64
    product = amount * sqrt_price
    lp = liquidity * sqrt_price
    if lp < (1 << 192):
        numerator = lp << 64
        if add:
            denominator = liquidity_shl + product
        else:
            _require(liquidity_shl > product, "ENotEnoughLiquidity")
            denominator = liquidity_shl - product
        r = div_round(numerator, denominator, True)
    else:
        # Divide-first form with 63 extra fractional bits on the
        # reserve; mirrors the Move fallback exactly.
        scaled = liquidity << 127
        reserve_a = scaled // sqrt_price
        amount_scaled = amount << 63
        if add:
            denominator = reserve_a + amount_scaled
        else:
            _require(reserve_a > amount_scaled, "ENotEnoughLiquidity")
            denominator = reserve_a - amount_scaled
        r = div_round(scaled, denominator, True)
    _require(r <= MAX_U128, "EPriceOverflow")
    return r


def next_sqrt_price_from_amount_b_rounding_down(sqrt_price, liquidity, amount, add):
    numerator = amount << 64
    if add:
        r = sqrt_price + numerator // liquidity
        _require(r <= MAX_U128, "EPriceOverflow")
        return r
    quotient = div_round(numerator, liquidity, True)
    _require(sqrt_price > quotient, "ENotEnoughLiquidity")
    return sqrt_price - quotient


def next_sqrt_price_from_input(sqrt_price, liquidity, amount_in, a_to_b):
    _require(sqrt_price > 0 and liquidity > 0, "EInvalidInput")
    if a_to_b:
        return next_sqrt_price_from_amount_a_rounding_up(
            sqrt_price, liquidity, amount_in, True
        )
    return next_sqrt_price_from_amount_b_rounding_down(
        sqrt_price, liquidity, amount_in, True
    )


def next_sqrt_price_from_output(sqrt_price, liquidity, amount_out, a_to_b):
    _require(sqrt_price > 0 and liquidity > 0, "EInvalidInput")
    if a_to_b:
        return next_sqrt_price_from_amount_b_rounding_down(
            sqrt_price, liquidity, amount_out, False
        )
    return next_sqrt_price_from_amount_a_rounding_up(
        sqrt_price, liquidity, amount_out, False
    )


DOES_NOT_FIT_U64 = 1 << 64


def get_amount_a_delta_wide(sqrt_price_0, sqrt_price_1, liquidity, round_up):
    lo, hi = sorted((sqrt_price_0, sqrt_price_1))
    _require(lo > 0, "EInvalidInput")
    if liquidity == 0 or lo == hi:
        return 0
    scaled = liquidity * (hi - lo)
    if scaled >= (1 << 192):
        # Mirrors the Move sentinel: the true amount is >= 2^64.
        return DOES_NOT_FIT_U64
    return div_round(scaled << 64, hi * lo, round_up)


def get_amount_b_delta_wide(sqrt_price_0, sqrt_price_1, liquidity, round_up):
    lo, hi = sorted((sqrt_price_0, sqrt_price_1))
    if liquidity == 0 or lo == hi:
        return 0
    return div_round(liquidity * (hi - lo), 1 << 64, round_up)


def get_amount_a_delta(sqrt_price_0, sqrt_price_1, liquidity, round_up):
    r = get_amount_a_delta_wide(sqrt_price_0, sqrt_price_1, liquidity, round_up)
    _require(r <= MAX_U64, "EAmountOverflow")
    return r


def get_amount_b_delta(sqrt_price_0, sqrt_price_1, liquidity, round_up):
    r = get_amount_b_delta_wide(sqrt_price_0, sqrt_price_1, liquidity, round_up)
    _require(r <= MAX_U64, "EAmountOverflow")
    return r


# === swap_math ===

def get_target_sqrt_price(a_to_b, next_tick_sqrt_price, sqrt_price_limit):
    if a_to_b:
        return max(next_tick_sqrt_price, sqrt_price_limit)
    return min(next_tick_sqrt_price, sqrt_price_limit)


def _mul_div_ceil_u64(a, b, d):
    r = div_round(a * b, d, True)
    _require(r <= MAX_U64, "mul_div_ceil_u64 overflow")
    return r


def compute_swap_step(
    sqrt_price_current, sqrt_price_target, liquidity, amount_remaining,
    exact_in, fee_pips,
):
    a_to_b = sqrt_price_current >= sqrt_price_target

    if exact_in:
        amount_remaining_less_fee = (
            amount_remaining * (FEE_SCALE - fee_pips) // FEE_SCALE
        )
        if a_to_b:
            amount_in_to_target = get_amount_a_delta_wide(
                sqrt_price_target, sqrt_price_current, liquidity, True
            )
        else:
            amount_in_to_target = get_amount_b_delta_wide(
                sqrt_price_current, sqrt_price_target, liquidity, True
            )

        if amount_remaining_less_fee >= amount_in_to_target:
            amount_in = amount_in_to_target
            next_sqrt_price = sqrt_price_target
            if fee_pips == FEE_SCALE:
                fee_amount = amount_in
            else:
                fee_amount = _mul_div_ceil_u64(
                    amount_in, fee_pips, FEE_SCALE - fee_pips
                )
        else:
            amount_in = amount_remaining_less_fee
            next_sqrt_price = next_sqrt_price_from_input(
                sqrt_price_current, liquidity, amount_in, a_to_b
            )
            fee_amount = amount_remaining - amount_in

        if a_to_b:
            amount_out = get_amount_b_delta(
                next_sqrt_price, sqrt_price_current, liquidity, False
            )
        else:
            amount_out = get_amount_a_delta(
                sqrt_price_current, next_sqrt_price, liquidity, False
            )
    else:
        _require(fee_pips < FEE_SCALE, "EFeeConsumesEverything")
        if a_to_b:
            amount_out_to_target = get_amount_b_delta_wide(
                sqrt_price_target, sqrt_price_current, liquidity, False
            )
        else:
            amount_out_to_target = get_amount_a_delta_wide(
                sqrt_price_current, sqrt_price_target, liquidity, False
            )

        if amount_remaining >= amount_out_to_target:
            capped_out = amount_out_to_target
            next_sqrt_price = sqrt_price_target
        else:
            capped_out = amount_remaining
            next_sqrt_price = next_sqrt_price_from_output(
                sqrt_price_current, liquidity, capped_out, a_to_b
            )
        amount_out = capped_out

        if a_to_b:
            amount_in = get_amount_a_delta(
                next_sqrt_price, sqrt_price_current, liquidity, True
            )
        else:
            amount_in = get_amount_b_delta(
                sqrt_price_current, next_sqrt_price, liquidity, True
            )
        fee_amount = _mul_div_ceil_u64(amount_in, fee_pips, FEE_SCALE - fee_pips)

    return next_sqrt_price, amount_in, amount_out, fee_amount


# === pool simulator ===

class Pool:
    """State-mirroring simulator of pool.move for spot pools.

    Tracks exactly the state the swap engine touches: price, tick,
    in-range liquidity, tick table (net/gross), fee growth globals,
    protocol fee rates and reserves.
    """

    def __init__(self, lp_fee_pips, tick_spacing, sqrt_price_x64):
        self.lp_fee_pips = lp_fee_pips
        self.spacing = tick_spacing
        self.sqrt_price = sqrt_price_x64
        self.tick_current = get_tick_at_sqrt_price(sqrt_price_x64)
        self.liquidity = 0
        self.net = {}    # tick -> signed liquidity_net
        self.gross = {}  # tick -> gross liquidity
        self.fee_growth_a = 0
        self.fee_growth_b = 0
        self.protocol_fee_a_to_b = 0
        self.protocol_fee_b_to_a = 0
        self.protocol_fees_a = 0
        self.protocol_fees_b = 0
        self.reserve_a = 0
        self.reserve_b = 0

    # --- liquidity ---

    def add_position(self, lower, upper, liquidity):
        """modify_liquidity with a positive delta. Returns (need_a, need_b)."""
        assert lower % self.spacing == 0 and upper % self.spacing == 0
        assert lower < upper
        for t, sign in ((lower, 1), (upper, -1)):
            self.net[t] = self.net.get(t, 0) + sign * liquidity
            self.gross[t] = self.gross.get(t, 0) + liquidity

        price_lower = get_sqrt_price_at_tick(lower)
        price_upper = get_sqrt_price_at_tick(upper)
        if self.tick_current < lower:
            amounts = (
                get_amount_a_delta(price_lower, price_upper, liquidity, True),
                0,
            )
        elif self.tick_current < upper:
            amounts = (
                get_amount_a_delta(self.sqrt_price, price_upper, liquidity, True),
                get_amount_b_delta(price_lower, self.sqrt_price, liquidity, True),
            )
            self.liquidity += liquidity
        else:
            amounts = (
                0,
                get_amount_b_delta(price_lower, price_upper, liquidity, True),
            )
        self.reserve_a += amounts[0]
        self.reserve_b += amounts[1]
        return amounts

    # --- tick bitmap walk (next_initialized_tick_within_one_word) ---

    def _next_initialized_tick(self, tick, lte):
        spacing = self.spacing
        initialized = {
            t // spacing for t, g in self.gross.items() if g > 0
        }
        compressed = tick // spacing  # Python floor division == i32 semantics
        if lte:
            word_pos, bit_pos = divmod(compressed, 256)
            best = None
            for c in initialized:
                if c // 256 == word_pos and c <= compressed:
                    if best is None or c > best:
                        best = c
            if best is not None:
                return best * spacing, True
            return (compressed - bit_pos) * spacing, False
        start = compressed + 1
        word_pos, bit_pos = divmod(start, 256)
        best = None
        for c in initialized:
            if c // 256 == word_pos and c >= start:
                if best is None or c < best:
                    best = c
        if best is not None:
            return best * spacing, True
        return (start + (255 - bit_pos)) * spacing, False

    # --- swap engine ---

    def swap(self, a_to_b, exact_in, amount, sqrt_price_limit):
        """Mirror of pool.swap_engine. Returns (amount_in, amount_out,
        protocol_fee) where amount_in includes all fees."""
        _require(amount > 0, "ESwapAmountZero")
        if a_to_b:
            _require(sqrt_price_limit < self.sqrt_price, "EPriceLimitAlreadyExceeded")
            _require(sqrt_price_limit > MIN_SQRT_PRICE, "EPriceLimitOutOfBounds")
        else:
            _require(sqrt_price_limit > self.sqrt_price, "EPriceLimitAlreadyExceeded")
            _require(sqrt_price_limit < MAX_SQRT_PRICE, "EPriceLimitOutOfBounds")

        protocol_fee_pips = (
            self.protocol_fee_a_to_b if a_to_b else self.protocol_fee_b_to_a
        )
        lp_fee = self.lp_fee_pips
        if protocol_fee_pips == 0:
            swap_fee = lp_fee
        else:
            swap_fee = (
                protocol_fee_pips + lp_fee
                - protocol_fee_pips * lp_fee // FEE_SCALE
            )
        if swap_fee >= FEE_SCALE:
            _require(exact_in, "EInvalidFeeForExactOut")

        amount_remaining = amount
        amount_calculated = 0
        sqrt_price = self.sqrt_price
        tick_cur = self.tick_current
        liq = self.liquidity
        fee_growth_input = self.fee_growth_a if a_to_b else self.fee_growth_b
        protocol_fee_total = 0

        while amount_remaining > 0 and sqrt_price != sqrt_price_limit:
            sqrt_price_start = sqrt_price
            tick_next, initialized = self._next_initialized_tick(tick_cur, a_to_b)
            tick_next = max(-MAX_TICK, min(MAX_TICK, tick_next))
            sqrt_price_next = get_sqrt_price_at_tick(tick_next)
            target = get_target_sqrt_price(a_to_b, sqrt_price_next, sqrt_price_limit)

            sqrt_price, step_in, step_out, step_fee = compute_swap_step(
                sqrt_price, target, liq, amount_remaining, exact_in, swap_fee
            )

            if exact_in:
                amount_remaining -= step_in + step_fee
                amount_calculated += step_out
            else:
                amount_remaining -= step_out
                amount_calculated += step_in + step_fee

            if protocol_fee_pips > 0:
                if swap_fee == protocol_fee_pips:
                    delta = step_fee
                else:
                    delta = (
                        (step_in + step_fee) * protocol_fee_pips // FEE_SCALE
                    )
                step_fee -= delta
                protocol_fee_total += delta

            if liq > 0 and step_fee > 0:
                fee_growth_input = (
                    fee_growth_input + ((step_fee << 64) // liq)
                ) & MAX_U128

            if sqrt_price == sqrt_price_next:
                if initialized:
                    liquidity_net = self.net.get(tick_next, 0)
                    if a_to_b:
                        liquidity_net = -liquidity_net
                    liq += liquidity_net
                    assert liq >= 0
                tick_cur = tick_next - 1 if a_to_b else tick_next
            elif sqrt_price != sqrt_price_start:
                tick_cur = get_tick_at_sqrt_price(sqrt_price)

        self.sqrt_price = sqrt_price
        self.tick_current = tick_cur
        self.liquidity = liq
        if a_to_b:
            self.fee_growth_a = fee_growth_input
        else:
            self.fee_growth_b = fee_growth_input

        _require(protocol_fee_total <= MAX_U64, "EAmountOverflow")
        _require(amount_calculated <= MAX_U64, "EAmountOverflow")
        consumed = amount - amount_remaining
        if exact_in:
            amount_in, amount_out = consumed, amount_calculated
        else:
            amount_in, amount_out = amount_calculated, consumed

        if a_to_b:
            self.reserve_a += amount_in - protocol_fee_total
            self.protocol_fees_a += protocol_fee_total
            self.reserve_b -= amount_out
        else:
            self.reserve_b += amount_in - protocol_fee_total
            self.protocol_fees_b += protocol_fee_total
            self.reserve_a -= amount_out
        assert self.reserve_a >= 0 and self.reserve_b >= 0

        return amount_in, amount_out, protocol_fee_total


def i32_bits(v: int) -> int:
    """Two's-complement u32 bit pattern of a signed tick, as Move's
    i32::bits() returns it."""
    return v & 0xFFFFFFFF
