// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Marker coin types for tests. Their fully qualified names sort
/// COIN_A < COIN_B < COIN_C, which the registry's canonical-ordering
/// tests rely on.
#[test_only]
module haneul_amm::test_coins {
    public struct COIN_A has drop {}

    public struct COIN_B has drop {}

    public struct COIN_C has drop {}
}
