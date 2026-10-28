// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title PackedBands
/// @notice The 40 band states of a round (`ILadderMath` state `v`) in 20 storage words: band 2k in the low
///         128 bits of word k, band 2k+1 in the high 128 bits, each a signed 128-bit number.
/// @dev Exact for every |v_j| below 2^127. `ILadderMath` rejects any |v_j| above 1e36 on the way in and on
///      the way out, and 1e36 < 2^127, so every state the hook stores fits.
library PackedBands {
    /// @notice The band states, unpacked: each half of a word sign-extended to 256 bits.
    function load(uint256[20] storage packed) internal view returns (int256[40] memory v) {
        assembly ("memory-safe") {
            let slot := packed.slot
            for { let k := 0 } lt(k, 20) { k := add(k, 1) } {
                let w := sload(add(slot, k))
                let p := add(v, shl(6, k))
                mstore(p, signextend(15, w))
                mstore(add(p, 32), sar(128, w))
            }
        }
    }

    /// @notice Writes the 20 words of `v`. Each v_j must fit in a signed 128-bit number: the caller passes
    ///         a state that `ILadderMath` returned (|v_j| at most 1e36).
    function store(uint256[20] storage packed, int256[40] memory v) internal {
        assembly ("memory-safe") {
            let slot := packed.slot
            let mask := sub(shl(128, 1), 1)
            for { let k := 0 } lt(k, 20) { k := add(k, 1) } {
                let p := add(v, shl(6, k))
                sstore(add(slot, k), or(and(mload(p), mask), shl(128, mload(add(p, 32)))))
            }
        }
    }
}
