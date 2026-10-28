// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFallpitHook} from "../interfaces/IFallpitHook.sol";
import {IPitBook} from "./IPitBook.sol";
import {PitBook} from "./PitBook.sol";
import {PitClock} from "./PitClock.sol";
import {PitVault} from "../PitVault.sol";
import {NYTime} from "../lib/NYTime.sol";

/// @dev The hook's public getters this lens reads besides `IFallpitHook` (FallpitHook has them).
interface IFallpitHookDirectory is IFallpitHook {
    function vault() external view returns (address);
    function houseRound(bytes32 house) external view returns (bytes32);
}

/// @title FallpitDirectory
/// @notice Read-only discovery for apps: which tickers and houses exist, what an LP holds in a house, and
///         which round of a ticker can open next. A second lens beside `FallpitLens` (which reads one
///         round), kept out of the hook, the book and the vault for their code size. Holds nothing and
///         changes nothing.
/// @dev Discovery reads two append-only lists: `PitBook.tickers()` (every ticker the owner registered,
///      pending ones included) and `PitVault.houseIds` (every house in creation order). An entry costs its
///      writer one new storage slot and the length update (about 25,000 gas; 45,000 for the very first),
///      on a first `registerTicker` and on `createHouse`; nothing else writes them. Anyone may create a
///      house for an allowed chip, so `houses()` without arguments is meant for testnet-sized lists: an
///      `eth_call` of it costs up to about 70,000 gas a house (a house with a round reads the round's
///      config), so a 30M gas call reads about 400 houses. Page with `houses(start, count)` beyond that.
contract FallpitDirectory {
    /// @notice A ticker as `tickers` returns it.
    /// @param ticker the ticker id (the symbol as a left-aligned bytes32, `bytes32("NVDA")`)
    /// @param live true when its registration is in force: closes, rounds and houses may be made
    /// @param pendingEta when a waiting registration or reseed takes effect (0: none waiting)
    /// @param clock the clock of its rounds (`NYWeekdays` for a stock, `EveryDay` around the clock)
    /// @param fillSource the oracle source that prices the fills of rounds opened now (for a ticker not
    ///        live yet: the one it will have)
    /// @param windows which windows of a `NYWeekdays` round trade (`IPitBook.RoundClock.windows`), as above
    /// @param lastCloseDay newest day with a recorded close (0: none)
    /// @param varWad daily variance its rounds open with now, WAD (as above)
    struct TickerView {
        bytes32 ticker;
        bool live;
        uint64 pendingEta;
        IPitBook.Clock clock;
        IPitBook.FillSource fillSource;
        uint8 windows;
        uint32 lastCloseDay;
        uint256 varWad;
    }

    /// @notice A house as `houses` returns it.
    /// @param house the house id, `keccak256(abi.encode(ticker, chip))`
    /// @param capital the house's booked capital, in chip units: the LPs' and the endowment's. While a
    ///        round runs it is what the round took (the round's `capital`); between rounds what the next
    ///        round would take before the queues are processed
    /// @param locked true while the capital is out in a round
    /// @param roundId the house's latest round (zero: none yet)
    /// @param roundStatus that round's status (`None` when there is none)
    /// @param roundDay that round's day (0 when there is none)
    struct HouseView {
        bytes32 house;
        bytes32 ticker;
        address chip;
        uint256 capital;
        bool locked;
        bytes32 roundId;
        IFallpitHook.Status roundStatus;
        uint32 roundDay;
    }

    error ZeroAddress();

    /// @dev `PitBook.MAX_CLOSE_AGE`: a round starts from a close at most this many days back.
    uint32 internal constant MAX_CLOSE_AGE = 6;

    IFallpitHookDirectory public immutable hook;
    PitBook public immutable book;
    PitVault public immutable vault;

    constructor(IFallpitHookDirectory hook_) {
        if (address(hook_) == address(0)) revert ZeroAddress();
        hook = hook_;
        book = PitBook(payable(address(hook_.book())));
        vault = PitVault(hook_.vault());
    }

    // ------------------------------------------------------------------------------------------ tickers

    /// @notice Every registered ticker, live or waiting, in the order of registration.
    function tickers() external view returns (TickerView[] memory list) {
        bytes32[] memory ids = book.tickers();
        list = new TickerView[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            list[i] = tickerOf(ids[i]);
        }
    }

    /// @notice One ticker (all zero but `ticker` when it was never registered).
    function tickerOf(bytes32 ticker) public view returns (TickerView memory v) {
        IPitBook.Ticker memory tk = book.getTicker(ticker);
        IPitBook.Reseed memory r = book.pendingReseed(ticker);
        v.ticker = ticker;
        v.live = tk.varWad != 0;
        v.pendingEta = r.eta;
        v.clock = tk.clock;
        v.lastCloseDay = tk.lastCloseDay;
        if (v.live) {
            v.fillSource = tk.fillSource;
            v.windows = tk.windows;
            v.varWad = tk.varWad;
        } else {
            v.fillSource = r.fillSource;
            v.windows = r.windows;
            v.varWad = r.varWad;
        }
    }

    /// @notice The next round of `ticker` and whether `FallpitHook.openRound` can open it now, by the book's
    ///         own rules: the day is the first after the newest recorded close for which
    ///         `PitBook.openTerms` succeeds (the calendar, the skips, the missed closes and the pause, all
    ///         the book's code), and it is openable while its cutoff (15:49:30 New York) is ahead, which is
    ///         the hook's own check.
    /// @dev When that day's cutoff has passed (its round was not opened in time, or the day is running and
    ///      its close is not recorded yet), the answer is the next day with a round after it, not openable:
    ///      it opens once the close of the day before is recorded (or missed, 12 hours after it). A house
    ///      whose round of `day` exists already gets `RoundExists` from `openRound`, and one whose round
    ///      before is still settling `PreviousRoundActive`: this is per ticker, not per house. All zero
    ///      when the ticker is not live, has no recorded close, or opening is paused.
    /// @return day the round's day (days since 1970-01-01)
    /// @return openTs from when the round can be opened: the previous close (16:00:00 New York of the
    ///         day before for a stock), in the past when `openable`
    /// @return closeTs the round's close, 16:00:00 New York on `day`
    /// @return openable true when `openRound(ticker, chip, day)` passes the book's and the hook's checks
    ///         of the day now
    function nextOpenableDay(bytes32 ticker)
        external
        view
        returns (uint32 day, uint64 openTs, uint64 closeTs, bool openable)
    {
        IPitBook.Ticker memory tk = book.getTicker(ticker);
        uint32 last = tk.lastCloseDay;
        if (tk.varWad == 0 || last == 0) return (0, 0, 0, false);
        uint32 lost;
        for (uint32 d = last + 1; d <= last + MAX_CLOSE_AGE; ++d) {
            try book.openTerms(ticker, d) returns (
                uint256, uint256, IPitBook.RoundClock memory c, IPitBook.FillSource, IPitBook.Params memory
            ) {
                closeTs = NYTime.closeTs(d);
                if (block.timestamp < closeTs - PitClock.CUTOFF_LEAD) {
                    return (d, NYTime.closeTs(c.prevDay), closeTs, true);
                }
                lost = d;
            } catch {}
        }
        if (lost == 0) return (0, 0, 0, false);
        day = _nextRoundDay(ticker, tk.clock, lost);
        if (day == 0) return (0, 0, 0, false);
        return (day, NYTime.closeTs(lost), NYTime.closeTs(day), false);
    }

    // ------------------------------------------------------------------------------------------- houses

    /// @notice Every house in creation order. See the contract's note on size; `houses(start, count)`
    ///         pages.
    function houses() external view returns (HouseView[] memory) {
        return _housesOf(vault.houseIds(0, vault.houseCount()));
    }

    /// @notice Up to `count` houses from position `start` of the creation order.
    function houses(uint256 start, uint256 count) external view returns (HouseView[] memory) {
        return _housesOf(vault.houseIds(start, count));
    }

    /// @notice One house (all zero but `house` when it does not exist).
    function houseOf(bytes32 house) public view returns (HouseView memory v) {
        PitVault.House memory h = vault.getHouse(house);
        v.house = house;
        v.ticker = h.ticker;
        v.chip = h.chip;
        v.capital = h.lpAssets + h.endowment;
        v.locked = h.locked;
        bytes32 roundId = hook.houseRound(house);
        if (roundId != bytes32(0)) {
            v.roundId = roundId;
            v.roundStatus = hook.getState(roundId).status;
            v.roundDay = hook.getConfig(roundId).day;
        }
    }

    /// @notice What `owner` has in a house, for the LP screens.
    /// @return shares shares on the ledger plus shares minted for a processed queued deposit
    /// @return assets what `shares` are worth at the house's booked share price, in chip units. While a
    ///         round runs that price is the one at its opening: the round's result is not in it yet
    /// @return pendingDeposit chips waiting in the deposit queue (`PitVault.cancelDeposit` takes them back
    ///         while the house is locked)
    /// @return queuedShares shares waiting in the withdrawal queue; they still bear the running round
    /// @return claimable chips `PitVault.claim` pays now (processed withdrawals)
    function positionOf(address owner, bytes32 house)
        external
        view
        returns (
            uint256 shares,
            uint256 assets,
            uint256 pendingDeposit,
            uint256 queuedShares,
            uint256 claimable
        )
    {
        (shares, pendingDeposit, queuedShares, claimable) = vault.positionOf(house, owner);
        assets = vault.convertToAssets(house, shares);
    }

    // -------------------------------------------------------------------------------------- internals

    function _housesOf(bytes32[] memory ids) private view returns (HouseView[] memory list) {
        list = new HouseView[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            list[i] = houseOf(ids[i]);
        }
    }

    /// @dev The first day after `d` that has a round: a weekday (for `NYWeekdays`) the book does not skip.
    ///      The same two checks `PitBook.openTerms` makes of a day (its `NotTradingDay`); 0 when none within
    ///      `MAX_CLOSE_AGE` days.
    function _nextRoundDay(bytes32 ticker, IPitBook.Clock clock, uint32 d) private view returns (uint32) {
        for (uint32 e = d + 1; e <= d + MAX_CLOSE_AGE; ++e) {
            if ((clock == IPitBook.Clock.EveryDay || NYTime.isWeekday(e)) && !book.skip(ticker, e)) return e;
        }
        return 0;
    }
}
