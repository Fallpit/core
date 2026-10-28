// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ITickerGate
/// @notice What `PitVault.createHouse` asks before it opens a house: the deployment passes the PitBook,
///         whose `supported` is true once a ticker's registration is in force and the oracle supports it.
interface ITickerGate {
    function supported(bytes32 ticker) external view returns (bool);
}

/// @title IPitVault
/// @notice The houses: one pool of chips per (ticker, chip), held as plain ERC-20 balances between rounds.
///         See contracts/SPEC.md section 5.
interface IPitVault {
    /// @notice House id: keccak256(abi.encode(ticker, chip)).
    function houseId(bytes32 ticker, address chip) external pure returns (bytes32);

    /// @notice Opens the house for (ticker, chip), once per pair. Only `lister` may call it (PitLister, which
    ///         checks that `ticker` is the coin's launch anchor); the chip must pass ChipGuard and the
    ///         ticker must be supported by the vault's gate (the PitBook: registered, in force, with an
    ///         oracle source).
    /// @return house the house id
    function createHouse(bytes32 ticker, address chip) external returns (bytes32 house);

    /// @notice The only address that may create houses and lock seeds; zero until `setLister`.
    function lister() external view returns (address);

    /// @notice Sets `lister`, once, by the account that deployed the vault.
    function setLister(address lister_) external;

    /// @notice A lister's seed: deposits `amount` (pulled from the lister) for `owner` into an unlocked house
    ///         and locks the shares minted until `until`. Locked shares bear every round's result like any
    ///         other; they cannot be withdrawn or transferred before `until`. A lock of a voided share
    ///         generation ends with it. Only `lister` may call it.
    /// @return shares the shares minted and locked
    function depositLocked(bytes32 house, uint256 amount, address owner, uint64 until)
        external
        returns (uint256 shares);

    /// @notice `owner`'s locked shares of `house` and when the lock ends; (0, 0) when none is in force.
    function lockOf(bytes32 house, address owner) external view returns (uint256 shares, uint64 until);

    /// @notice Adds chips to the house's endowment: capital that owns no shares and can never be withdrawn.
    ///         It shares every profit and loss pro rata with the shares. Pulled from the caller and
    ///         credited by balance difference.
    /// @return credited chips that arrived
    function donate(bytes32 house, uint256 amount) external returns (uint256 credited);

    /// @notice `deposit` for `owner`: chips are pulled from the caller, the shares (or the queued deposit)
    ///         are `owner`'s. Callable by `owner`, an ERC-6909 operator of `owner`, or the router the hook
    ///         pins (session-signed vault actions, `FallpitRouter.vaultWithSig`). An operator is
    ///         trusted with more than in plain ERC-6909 (moving shares): with these four functions it can
    ///         also deposit, cancel queued deposits, withdraw and claim for `owner` in every house. It never
    ///         receives anything, but it can change `owner`'s position. See src/vault/DESIGN.md 1.6.
    /// @return shares shares minted now (0 when the deposit was queued)
    function depositFor(bytes32 house, uint256 amount, address owner) external returns (uint256 shares);

    /// @notice `cancelDeposit` for `owner`; the chips go to `owner`. Same callers as `depositFor`.
    function cancelDepositFor(bytes32 house, address owner) external returns (uint256 assets);

    /// @notice `requestWithdraw` of `owner`'s shares; chips paid now go to `owner`. Same callers as
    ///         `depositFor`.
    function requestWithdrawFor(bytes32 house, uint256 shares, address owner)
        external
        returns (uint256 assets);

    /// @notice `claim` for `owner`; the chips go to `owner`. Same callers as `depositFor`.
    function claimFor(bytes32 house, address owner) external returns (uint256 assets);

    /// @notice Hook only. Processes the house's queued deposits and withdrawals at the current share
    ///         price, locks the house, and transfers its whole capital to `to`.
    /// @dev The receiver measures what arrived (fee-on-transfer chips deliver less than `sent`).
    /// @return sent chips transferred out
    function pullRoundCapital(bytes32 house, address to) external returns (uint256 sent);

    /// @notice Hook only. Books whatever chips arrived since the last sync as the house's capital after the
    ///         round (profit or loss is the difference to what `pullRoundCapital` sent) and unlocks it.
    /// @dev The hook must transfer the chips to the vault and call this in the same transaction: the
    ///      vault credits everything it holds above its books to this house.
    /// @return received chips booked
    function returnRoundCapital(bytes32 house) external returns (uint256 received);

    /// @notice The chip of a house (zero when the house does not exist).
    function chipOf(bytes32 house) external view returns (address);

    /// @notice Chips the house would send to a round now (capital after processing the queues).
    function roundCapital(bytes32 house) external view returns (uint256);

    /// @notice True while the house's capital is out in a round.
    function isLocked(bytes32 house) external view returns (bool);
}
