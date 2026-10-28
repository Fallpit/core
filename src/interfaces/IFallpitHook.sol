// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPitBook} from "../hook/IPitBook.sol";

/// @notice Why a commit was refunded instead of filled. Values 1 to 7 are also the argument of the hook's
///         `FillRejected` error, which the router turns into a refund.
enum RefundReason {
    None,
    Limit, // the cost was above the buy limit, or the proceeds were below the sell limit
    Cap, // more shares than the per-fill cap of the round
    Solvency, // the fill would leave the round unable to cover its worst-case payout
    Window, // the print for the fill time is outside the trading windows of the round's clock
    NotOpen, // the round is no longer open
    LossLimit, // the buy would put more of the round's capital at risk than its loss limit allows
    ProductCap, // the buy would take the product's outstanding supply above its cap (floors only)
    Expired // nobody filled the commit before its fill window ended
}

/// @title IFallpitHook
/// @notice The Fallpit market: rounds, pricing, settlement and redemption, and the ERC-6909 tickets of
///         every round's products. See contracts/SPEC.md section 7.
interface IFallpitHook {
    /// @notice Lifecycle of a round.
    enum Status {
        None,
        Open,
        Settled,
        Final,
        Void
    }

    /// @notice Frozen configuration of a round.
    /// @param openTs when the round was opened (block time); it trades from then on, in the windows of
    ///        its clock
    /// @param closeTs the round's close: 16:00:00 New York on `day`
    /// @param cutoff last instant a fill may be priced at: 630 s before the close
    /// @param clock the round's clock (`IPitBook.clockAt`): which hours trade and how the variance is
    ///        spread over the time from the previous close to this one
    /// @param s0 previous close, WAD
    /// @param sigma standard deviation of the log return from the previous close to this one, WAD
    /// @param capital chips the house brought to the round (L), in chip units
    /// @param maxFill largest number of shares in one fill, in chip units
    /// @param fillSource the one oracle source that prices the round's fills
    /// @param params the book's default parameters at the time the round opened, the menu of products
    ///        included (`params.menu`, read with `PitMath.run` or the lens)
    struct RoundConfig {
        bytes32 ticker;
        bytes32 house;
        address chip;
        uint32 day;
        uint8 decimals;
        IPitBook.FillSource fillSource;
        uint64 openTs;
        uint64 closeTs;
        uint64 cutoff;
        IPitBook.RoundClock clock;
        uint256 s0;
        uint256 sigma;
        uint256 capital;
        uint256 maxFill;
        IPitBook.Params params;
    }

    /// @notice Mutable state of a round.
    /// @param winners bit i is set when product i won (valid once Settled)
    /// @param g depth scale the pricing state is expressed at, WAD
    /// @param held chips this contract holds for the round (after Final or Void: chips still owed)
    /// @param protocolFees part of `held` set aside for the protocol
    /// @param payoutOwed chips owed to holders of winning tokens (or to all holders after a void)
    /// @param settledPrice close the round was settled on, WAD
    struct RoundState {
        Status status;
        bool settledTrustless;
        uint8 closeBand;
        uint16 winners;
        uint64 settledAt;
        uint256 g;
        uint256 held;
        uint256 protocolFees;
        uint256 payoutOwed;
        uint256 settledPrice;
    }

    event RoundOpened(
        bytes32 indexed roundId,
        bytes32 indexed ticker,
        address indexed chip,
        uint32 day,
        uint256 s0,
        uint256 sigma,
        uint256 capital,
        uint256 menu
    );
    /// @param chips chips the trader paid (buy) or received (sell), fee included
    event Filled(
        bytes32 indexed roundId,
        address indexed user,
        uint8 product,
        bool isBuy,
        uint256 shares,
        uint256 chips,
        uint256 fee,
        uint256 price,
        uint64 ts
    );
    event RoundSettled(
        bytes32 indexed roundId,
        uint256 closePrice,
        uint8 band,
        uint16 winners,
        uint256 payoutOwed,
        bool trustless
    );
    event RoundFinalized(bytes32 indexed roundId, uint256 payoutOwed, uint256 protocolFees, uint256 returned);
    event RoundVoided(bytes32 indexed roundId, uint256 refunds, uint256 returned);
    event Redeemed(
        bytes32 indexed roundId, uint256 indexed id, address indexed holder, uint256 amount, uint256 payout
    );
    event ProtocolFeesCollected(address indexed chip, address indexed to, uint256 amount);
    /// @notice The vol keeper set the sigma a round prices its remaining sd and vega with (`setSigmaEff`).
    /// @param sigmaEff the sigma in force from now on, WAD, after the clamps
    event SigmaEffSet(bytes32 indexed roundId, uint256 sigmaEff);

    error OnlyRouter();
    error Reentrancy();
    error UnknownToken();
    error FillExpired();
    /// @dev A buy's chips arrived short (a chip that started to tax its transfers). Not a final rejection:
    ///      the commit stays pending and refunds when its fill window ends.
    error ChipShort();
    error WrongFillSource();
    /// @dev A fill that can never succeed; the router refunds the commit. `reason` is a `RefundReason`.
    error FillRejected(uint8 reason);
    error TooLate();
    error BadPrice();
    error CloseNotRecorded();
    error CloseChanged();
    error ChipNotAllowed();
    error PreviousRoundActive();
    error RoundExists();
    error CapitalTooLow();
    error WrongStatus();
    error AlreadySettled();
    error ChallengeWindowOpen();
    error VoidNotAllowed();
    error NotHolder();
    error NotWinner();
    error ZeroAmount();
    error ZeroAddress();
    error OnlyVolKeeper();
    /// @dev `setSigmaEff` again within `SIGMA_EFF_GAP` (5 minutes) of the round's last update. Raised by the
    ///      book (`IPitBook.stepSigmaEff`), as is `OnlyVolKeeper`.
    error SigmaEffTooSoon();

    /// @notice The only contract that may fill and escrow (`fill`, `pull`).
    function router() external view returns (address);

    /// @notice The book of closes, volatility, calendar, defaults and roles the hook reads.
    function book() external view returns (IPitBook);

    /// @notice Opens the round of house (ticker, chip) for `day`: pulls the house capital and sets the
    ///         round's depths. The products are ERC-6909 ids of this contract (`tokenId`): nothing is
    ///         deployed. Anyone may call.
    function openRound(bytes32 ticker, address chip, uint32 day) external returns (bytes32 roundId);

    /// @notice Settles a round on its recorded close (`IPitBook.closeState`: a close recorded more than 12
    ///         hours after its instant is late and settles nothing). Anyone may call.
    function settleRound(bytes32 house, uint32 day) external;

    /// @notice Finalizes a settled round and returns the house's share to the vault. Anyone may call.
    function finalizeRound(bytes32 house, uint32 day) external;

    /// @notice Voids an open round that has no recorded close (a late one counts as none) 24 hours after
    ///         its close. Anyone may call.
    ///         The house gets its capital back first, holders share what the round holds above it pro rata
    ///         to their cost basis (never more than that basis). (`openRound` of the house's next round
    ///         voids such a round the same way from 12 hours after its close.)
    function voidRound(bytes32 house, uint32 day) external;

    /// @notice Prices and executes one fill of product `product` of a round for `user`, at the oracle print
    ///         `report` for instant `t`. Only the router, which attests the user and the instant from its
    ///         commit record. A buy mints `shares` tickets to `user`: the router has sent `limit` chips
    ///         (the commit's escrow) to this contract in the same transaction, the cost stays and the rest
    ///         goes to `user`. A sell burns `shares` tickets the router holds in escrow and pays `user`.
    /// @dev Reverts with `FillRejected(reason)` for a final rejection (the router refunds the commit);
    ///      any other revert leaves the commit pending. Any ETH sent pays the oracle's update fee.
    /// @return chips the cost (buy) or the proceeds (sell), fee included
    function fill(
        bytes32 roundId,
        uint8 product,
        bool isBuy,
        uint256 shares,
        uint256 limit,
        address user,
        uint64 t,
        bytes calldata report
    ) external payable returns (uint256 chips);

    /// @notice Moves `amount` of ticket `id` from `from` to the router, with no allowance: the escrow of a
    ///         sell commit. Only the router, for its own caller or a session-signed user.
    function pull(address from, uint256 id, uint256 amount) external;

    /// @notice Burns `amount` of ticket `id` held by `holder` and pays `holder` what it redeems for.
    function redeem(uint256 id, address holder, uint256 amount) external returns (uint256 payout);

    /// @notice Sends the protocol's accrued fees in `chip` to the fee recipient. Anyone may call.
    function collectProtocolFees(address chip) external returns (uint256 amount);

    /// @notice What the router needs to accept a commit on product `product` of a round.
    /// @dev `id` is zero for an index the round's menu does not have.
    ///      `tradable` is true when a commit made in this block would be priced inside a trading window
    ///      of the round's clock (the instant `block.timestamp + fillDelay`).
    ///      `minShares` is the smallest number of tokens one commit may trade, in the token's units.
    ///      `fillFee` is the native coin, in wei, the commit must carry for whoever fills it.
    function commitContext(bytes32 roundId, uint8 product)
        external
        view
        returns (
            uint256 id,
            address chip,
            bool tradable,
            uint32 fillDelay,
            uint32 refundDelay,
            uint256 minShares,
            uint64 fillFee,
            bool isOpen
        );

    /// @notice House id: keccak256(abi.encode(ticker, chip)).
    function houseOf(bytes32 ticker, address chip) external pure returns (bytes32);

    /// @notice Round id: keccak256(abi.encode(house, day)) with its lowest byte cleared, so a ticket id is
    ///         the round id plus the product index (`tokenId`).
    function roundIdOf(bytes32 house, uint32 day) external pure returns (bytes32);

    /// @notice Ticket id of product `product` of a round: uint256(roundId) | product.
    function tokenId(bytes32 roundId, uint8 product) external pure returns (uint256);

    /// @notice Frozen configuration of a round (all zero for an unknown id).
    function getConfig(bytes32 roundId) external view returns (RoundConfig memory);

    /// @notice Mutable state of a round.
    function getState(bytes32 roundId) external view returns (RoundState memory);

    /// @notice Outstanding supply and premium paid per product: `supply[i]` is every ticket of id
    ///         `tokenId(roundId, i)` there is.
    function getSupplies(bytes32 roundId)
        external
        view
        returns (uint256[12] memory supply, uint256[12] memory premium);

    /// @notice Pricing state `v` (at depth scale `g`) and opening depths `b0`. `b0` is set only for the latest
    ///         round of its house (the only one that can trade); zero for an older one.
    function getCurve(bytes32 roundId) external view returns (int256[40] memory v, uint256[40] memory b0);

    /// @notice Round and product index of a ticket id (the inverse of `tokenId`).
    function tokenRef(uint256 id) external pure returns (bytes32 roundId, uint8 index);

    /// @notice House vol learning (SPEC section 10): the book's vol keeper sets the sigma that the
    ///         round's remaining sd (`sigmaEff * sqrt(rho)`) and its vega fee use from the next fill on. The
    ///         bands, the opening depths and settlement stay on the round's frozen `sigma`.
    /// @dev Only `book.volKeeper()`, only while the round is open. The book bounds the value
    ///      (`IPitBook.stepSigmaEff`): within 10% of the sigma in force, within [0.8, 1.5] x the round's
    ///      sigma, the product of the round's rises at most 1.5, and one update per `SIGMA_EFF_GAP` (5
    ///      minutes, `PitBook.SIGMA_EFF_GAP`). A commit is priced when it is filled, at the sigma in force then;
    ///      its limit protects the trader from an update between commit and fill.
    function setSigmaEff(bytes32 roundId, uint256 sigmaEff) external;

    /// @notice The sigma a round prices its remaining sd and vega with now: its frozen `sigma` until the vol
    ///         keeper sets one.
    function sigmaEffOf(bytes32 roundId) external view returns (uint256);
}
