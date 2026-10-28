// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPitLister
/// @notice One-transaction listing of a coin. See src/listing/PitLister.sol.
interface IPitLister {
    /// @notice A keeper's price of a coin for listing: `coinsPerUsd` base units of `chip` are worth 1 USD.
    struct ListingQuote {
        address chip;
        uint256 coinsPerUsd;
        uint64 expiry;
    }

    /// @notice Lists `chip` with `seed` coins of the caller, locked for the caller.
    function listCoin(address chip, uint256 seed, ListingQuote calldata quote, bytes calldata signature)
        external
        returns (bytes32 house);

    /// @notice `listCoin` for `owner` by the router (a session listing): the seed is pulled from the router,
    ///         which pulled it from `owner`, and is locked for `owner`. Only the vault's router may call it.
    function listCoinFor(
        address owner,
        address chip,
        uint256 seed,
        ListingQuote calldata quote,
        bytes calldata signature
    ) external returns (bytes32 house);
}
