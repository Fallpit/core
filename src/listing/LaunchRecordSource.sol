// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IAnchorSource} from "../interfaces/IAnchorSource.sol";

/// @title LaunchRecordSource
/// @notice An anchor source that reads one launchpad's record of a coin: a view function taking the coin
///         address and returning a record of words. One word proves that the launchpad launched the coin;
///         another word is the asset the coin was launched against.
/// @dev One contract serves every launchpad whose record has that shape. Verified on Robinhood Chain 4663:
///      - Doppler `Airlock.getAssetData(coin)` (long.xyz, Bankr, other integrators): word 4, the pool
///        initializer, is not zero for a coin the Airlock launched (`KnownBy.NonZero`); word 0, the
///        numeraire, is the anchor.
///      - Pons v2 `Factory.getLaunchedToken(coin)`: word 0 is the coin itself (`KnownBy.Self`); word 4,
///        the pair token, is the anchor.
///      - Pons v1 `Factory.getLaunchedToken(coin)` (three factories, one source each): word 0 is the coin
///        itself; word 2 is the anchor (always WETH).
///      The source asks the launchpad, never the coin: a coin can claim any launchpad. It has no owner and
///      no state; the registry's owner decides which sources are trusted.
contract LaunchRecordSource is IAnchorSource {
    /// @notice How a record proves that the launchpad launched the coin.
    enum KnownBy {
        /// @dev the word is the coin's own address
        Self,
        /// @dev the word is not zero
        NonZero
    }

    /// @dev Gas given to the launchpad's read. A failed read must come from the launchpad, not from a
    ///      caller that sent too little gas, so `anchorOf` reverts when it cannot forward this much.
    uint256 internal constant PROBE_GAS = 200_000;

    /// @notice The launchpad contract asked.
    address public immutable target;
    /// @notice The view function asked, taking the coin address.
    bytes4 public immutable selector;
    /// @notice The record word that proves the launch.
    uint8 public immutable knownWord;
    /// @notice How `knownWord` proves the launch.
    KnownBy public immutable knownBy;
    /// @notice The record word that holds the anchor.
    uint8 public immutable anchorWord;

    error ZeroAddress();
    error InsufficientGas();

    constructor(address target_, bytes4 selector_, uint8 knownWord_, KnownBy knownBy_, uint8 anchorWord_) {
        if (target_ == address(0)) revert ZeroAddress();
        target = target_;
        selector = selector_;
        knownWord = knownWord_;
        knownBy = knownBy_;
        anchorWord = anchorWord_;
    }

    /// @inheritdoc IAnchorSource
    /// @dev A record that is too short, a failed read, or an anchor word that is not an address all mean
    ///      "not known". Never reverts on a misbehaving launchpad; it reverts only with too little gas.
    function anchorOf(address coin) external view returns (bool known, address anchor) {
        uint256 words = (knownWord > anchorWord ? knownWord : anchorWord) + 1;
        (bool ok, uint256[] memory rec) = _probe(abi.encodeWithSelector(selector, coin), words);
        if (!ok) return (false, address(0));
        uint256 proof = rec[knownWord];
        known = knownBy == KnownBy.Self ? proof == uint256(uint160(coin)) : proof != 0;
        if (!known) return (false, address(0));
        uint256 a = rec[anchorWord];
        if (a >> 160 != 0) return (false, address(0));
        anchor = address(uint160(a));
    }

    /// @dev Static call with a gas cap that copies the first `words` return words, and only those.
    /// @return ok true when the call succeeded and returned at least `words` words
    function _probe(bytes memory data, uint256 words) internal view returns (bool ok, uint256[] memory rec) {
        // EIP-150 forwards at most 63/64 of the gas left; make sure the callee really gets PROBE_GAS.
        if (gasleft() < PROBE_GAS + PROBE_GAS / 32) revert InsufficientGas();
        rec = new uint256[](words);
        address t = target;
        assembly ("memory-safe") {
            ok := staticcall(PROBE_GAS, t, add(data, 0x20), mload(data), 0x00, 0x00)
            let need := mul(words, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), need)))
            if ok { returndatacopy(add(rec, 0x20), 0x00, need) }
        }
    }
}
