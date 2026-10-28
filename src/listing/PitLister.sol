// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IPitBook} from "../hook/IPitBook.sol";
import {IPitVault} from "../interfaces/IPitVault.sol";
import {IPitLister} from "../interfaces/IPitLister.sol";
import {AnchorRegistry} from "./AnchorRegistry.sol";

interface ISignerSet {
    function isSigner(address account) external view returns (bool);
}

interface IBookParams {
    function defaultParams() external view returns (IPitBook.Params memory);
}

interface IRouterOf {
    function router() external view returns (address);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title PitLister
/// @notice Lists a coin in one transaction: finds the ticker it plays from its launch record, creates its
///         house and locks the lister's seed in it. Anyone may list.
/// @dev The vault lets only this contract create houses, so every house plays its coin's launch anchor,
///      except those the owner creates by hand (`createHouse`). The seed must be worth at least
///      `minSeedUsd`: the coin's price comes from a `ListingQuote` signed by a keeper signer of the oracle
///      (its 1-hour average), since a price read from a pool in this transaction could be moved by a swap
///      in the same transaction. The owner sets the policy (the USD floor and the lock length), never a
///      coin's price.
contract PitLister is IPitLister, Ownable, EIP712 {
    bytes32 internal constant QUOTE_TYPEHASH =
        keccak256("ListingQuote(address chip,uint256 coinsPerUsd,uint64 expiry)");

    /// @notice Longest a quote may live.
    uint64 public constant MAX_QUOTE_LIFE = 10 minutes;
    /// @notice Bounds of `minSeedUsd`, in whole USD.
    uint32 public constant MIN_SEED_USD_FLOOR = 50;
    uint32 public constant MIN_SEED_USD_CEIL = 5000;
    /// @notice Bounds of `lockTime`.
    uint64 public constant LOCK_FLOOR = 1 days;
    uint64 public constant LOCK_CEIL = 30 days;

    IPitVault public immutable vault;
    AnchorRegistry public immutable registry;
    /// @notice Whose keeper signers may sign quotes (the PitOracle).
    ISignerSet public immutable signers;
    /// @notice Where the smallest round capital is read (the PitBook).
    IBookParams public immutable book;

    /// @notice The least a seed is worth, in whole USD.
    uint32 public minSeedUsd = 250;
    /// @notice How long a seed stays locked.
    uint64 public lockTime = 7 days;

    event CoinListed(
        bytes32 indexed house,
        address indexed chip,
        bytes32 indexed ticker,
        address anchor,
        address source,
        address lister,
        uint256 seed,
        uint256 shares,
        uint64 lockUntil
    );
    event HouseCreatedByOwner(bytes32 indexed house, bytes32 indexed ticker, address indexed chip);
    event MinSeedUsdSet(uint32 usd);
    event LockTimeSet(uint64 seconds_);

    error ZeroAddress();
    error OutOfBounds();
    error QuoteForAnotherCoin();
    error QuoteExpired();
    error QuoteTooLong();
    error NotASigner(address signer);
    error SeedTooSmall(uint256 seed, uint256 minSeed);
    error OnlyRouter();

    constructor(
        IPitVault vault_,
        AnchorRegistry registry_,
        ISignerSet signers_,
        IBookParams book_,
        address owner_
    ) {
        if (
            address(vault_) == address(0) || address(registry_) == address(0)
                || address(signers_) == address(0) || address(book_) == address(0) || owner_ == address(0)
        ) revert ZeroAddress();
        vault = vault_;
        registry = registry_;
        signers = signers_;
        book = book_;
        _initializeOwner(owner_);
    }

    // ---------------------------------------------------------------------------------------------
    // Listing
    // ---------------------------------------------------------------------------------------------

    /// @notice Lists `chip`: the house for its launch anchor's ticker, with `seed` of the caller's coins
    ///         deposited for the caller and locked for `lockTime`. The caller approves `seed` to this
    ///         contract first.
    /// @param quote the keeper's price of `chip`, at most `MAX_QUOTE_LIFE` from expiry
    /// @param signature a keeper signer's EIP-712 signature of `quote`
    /// @return house the new house
    function listCoin(address chip, uint256 seed, ListingQuote calldata quote, bytes calldata signature)
        external
        returns (bytes32 house)
    {
        return _list(msg.sender, chip, seed, quote, signature);
    }

    /// @inheritdoc IPitLister
    /// @dev The router checks the owner's session (`FallpitRouter.listWithSig`) and pulls the seed from the
    ///      owner first; the seed is then pulled from the router here.
    function listCoinFor(
        address owner,
        address chip,
        uint256 seed,
        ListingQuote calldata quote,
        bytes calldata signature
    ) external returns (bytes32 house) {
        if (msg.sender != IRouterOf(address(vault)).router()) {
            revert OnlyRouter();
        }
        return _list(owner, chip, seed, quote, signature);
    }

    /// @dev The seed is pulled from the caller and locked for `owner`.
    function _list(
        address owner,
        address chip,
        uint256 seed,
        ListingQuote calldata quote,
        bytes calldata signature
    ) internal returns (bytes32 house) {
        _checkQuote(chip, quote, signature);
        uint256 least = minSeed(chip, quote.coinsPerUsd);
        if (seed < least) revert SeedTooSmall(seed, least);
        (bytes32 ticker, address anchor, address source) = registry.resolve(chip);
        house = vault.createHouse(ticker, chip);

        SafeTransferLib.safeTransferFrom(chip, msg.sender, address(this), seed);
        SafeTransferLib.safeApprove(chip, address(vault), seed);
        uint64 until = uint64(block.timestamp) + lockTime;
        uint256 shares = vault.depositLocked(house, seed, owner, until);
        emit CoinListed(house, chip, ticker, anchor, source, owner, seed, shares, until);
    }

    /// @notice The least seed of `chip` at a price of `coinsPerUsd`, in base units: `minSeedUsd` worth, and
    ///         never under the smallest capital a round opens with.
    function minSeed(address chip, uint256 coinsPerUsd) public view returns (uint256) {
        uint256 usd = uint256(minSeedUsd) * coinsPerUsd;
        uint256 floor = uint256(book.defaultParams().minCapital) * 10 ** IDecimals(chip).decimals();
        return usd > floor ? usd : floor;
    }

    /// @notice The EIP-712 digest a keeper signs for `quote`.
    function quoteDigest(ListingQuote calldata quote) public view returns (bytes32) {
        return
            _hashTypedData(keccak256(abi.encode(QUOTE_TYPEHASH, quote.chip, quote.coinsPerUsd, quote.expiry)));
    }

    function _checkQuote(address chip, ListingQuote calldata quote, bytes calldata signature) internal view {
        if (quote.chip != chip) revert QuoteForAnotherCoin();
        if (quote.expiry < block.timestamp) revert QuoteExpired();
        if (quote.expiry > block.timestamp + MAX_QUOTE_LIFE) revert QuoteTooLong();
        address signer = ECDSA.recoverCalldata(quoteDigest(quote), signature);
        if (!signers.isSigner(signer)) revert NotASigner(signer);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------

    /// @notice Creates a house by hand, with no anchor check and no seed (the operator's houses, special cases).
    function createHouse(bytes32 ticker, address chip) external onlyOwner returns (bytes32 house) {
        house = vault.createHouse(ticker, chip);
        emit HouseCreatedByOwner(house, ticker, chip);
    }

    function setMinSeedUsd(uint32 usd) external onlyOwner {
        if (usd < MIN_SEED_USD_FLOOR || usd > MIN_SEED_USD_CEIL) revert OutOfBounds();
        minSeedUsd = usd;
        emit MinSeedUsdSet(usd);
    }

    function setLockTime(uint64 seconds_) external onlyOwner {
        if (seconds_ < LOCK_FLOOR || seconds_ > LOCK_CEIL) revert OutOfBounds();
        lockTime = seconds_;
        emit LockTimeSet(seconds_);
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Fallpit Lister", "1");
    }
}
