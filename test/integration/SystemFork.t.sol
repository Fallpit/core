// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {DeployTestnet} from "../../script/DeployTestnet.s.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {PitVault} from "../../src/PitVault.sol";
import {FallpitHook} from "../../src/FallpitHook.sol";
import {FallpitRouter} from "../../src/FallpitRouter.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {PitBook} from "../../src/hook/PitBook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPyth} from "../../src/oracle/IPyth.sol";
import {IChainlinkFeed} from "../../src/oracle/IChainlinkFeed.sol";
import {IStockToken} from "../../src/oracle/IStockToken.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {FaucetCoin} from "../../src/testnet/FaucetCoin.sol";
import {MirrorFeed} from "../../src/testnet/MirrorFeed.sol";

import {OracleTestBase} from "../oracle/OracleTestBase.sol";
import {StandardMenu} from "../Menus.sol";
import {TslaClose20261002} from "../oracle/fixtures/TslaClose20261002.sol";
import {TslaDay20261002} from "../oracle/fixtures/TslaDay20261002.sol";

/// @notice The whole system on a fork of Robinhood Chain, deployed by the testnet deploy script's own code
///         against the live v4 PoolManager and the live Pyth core contract. Skipped unless the RPC is
///         given in the environment:
///
///         FORK_RPC_46630=https://rpc.testnet.chain.robinhood.com \
///         FORK_RPC_4663=https://rpc.mainnet.chain.robinhood.com \
///         forge test --match-path "test/integration/SystemFork.t.sol" -vv
///
///         Nothing is sent to a live chain: everything runs inside the fork. The clock is set back to
///         Thursday 2026-10-01, and Friday 2026-10-02 is played as one real trading day of TSLA: the
///         previous close, three fills and the close are real Pyth updates (committed blobs), verified by
///         the chain's own Pyth contract. A second round, NVDA, runs on keeper-signed prints bounded by a
///         MirrorFeed, in the same chip.
contract SystemForkTest is OracleTestBase, StandardMenu {
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    IPyth internal constant PYTH = IPyth(0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a);
    bytes32 internal constant NVDA = bytes32("NVDA");
    /// @dev The book's default fill fee: what every commit carries.
    uint256 internal constant FILL_FEE = 0.0001 ether;
    // Robinhood Chain mainnet (4663): the NVDA push feed and stock token
    address internal constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address internal constant NVDA_TOKEN = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    DeployTestnet internal script;
    DeployTestnet.System internal sys;
    PitOracle internal oracle;
    PitBook internal book;
    PitVault internal vault;
    FallpitHook internal hook;
    FallpitRouter internal router;
    FaucetCoin internal chip;

    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint32 internal thursday;
    uint32 internal friday;

    receive() external payable {}

    /// @dev Selects a fork of `chainId`, sets the clock to Thursday's close and deploys the system with
    ///      the deploy script, or skips the test.
    function _fork(string memory envName, uint256 chainId) internal returns (bool) {
        string memory rpc = vm.envOr(envName, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, chainId, "wrong chain behind the RPC");
        assertGt(POOL_MANAGER.code.length, 0, "no PoolManager at the known address");
        assertGt(address(PYTH).code.length, 0, "no Pyth at the known address");
        thursday = uint32(NYTime.daysFromCivil(2026, 10, 1));
        friday = thursday + 1;
        assertEq(NYTime.closeTs(thursday), TslaDay20261002.THU_CLOSE_T);
        assertEq(NYTime.closeTs(friday), TslaClose20261002.T);
        // deployed a day before Thursday's close: the tickers are in force 24 hours after their
        // registration, and `deployAll` waits that day before it creates the houses
        vm.warp(TslaDay20261002.THU_CLOSE_T + 60 - 24 hours);

        _makeSigners(3);
        script = new DeployTestnet();
        DeployTestnet.Config memory cfg;
        cfg.poolManager = POOL_MANAGER;
        cfg.pyth = address(PYTH);
        cfg.owner = address(this);
        cfg.guardian = guardian;
        cfg.feeRecipient = feeRecipient;
        cfg.signers = signerAddrs;
        cfg.threshold = 2;
        // a mainnet chain id refuses delays under 24 hours (PitBook and PitOracle constructors)
        cfg.ownerDelay = 24 hours;
        cfg.signerDelay = 24 hours;
        cfg.mirrorPusher = keeper;
        cfg.tickers = new DeployTestnet.TickerSetup[](2);
        cfg.tickers[0] = script.tickerSetup("TSLA");
        cfg.tickers[1] = script.tickerSetup("NVDA");
        cfg.chipNames = new string[](1);
        cfg.chipNames[0] = "Pit Rat";
        cfg.chipSymbols = new string[](1);
        cfg.chipSymbols[0] = "RAT";
        cfg.chipSupply = 10_000_000e18;
        cfg.seedPerHouse = 100_000e18;
        sys = script.deployAll(cfg);

        oracle = sys.core.oracle;
        book = sys.core.book;
        vault = sys.core.vault;
        hook = sys.core.hook;
        router = sys.core.router;
        chip = sys.chips[0];
        book.acceptOwnership();
        return true;
    }

    function _pythFee(bytes memory blob) internal view returns (uint256) {
        bytes[] memory data = new bytes[](1);
        data[0] = blob;
        return PYTH.getUpdateFee(data);
    }

    function _pyth(bytes memory blob) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x01), blob);
    }

    /// @dev A 2-of-3 keeper print for (NVDA, ts), after the keeper mirrored a "mainnet" round at that price.
    function _keeperPrint(uint256 price, uint64 ts) internal returns (bytes memory) {
        vm.prank(keeper);
        sys.feeds[1].push(int256(price / 1e10), ts);
        return _report2(oracle, PitOracle.Print({ticker: NVDA, price: price, ts: ts, prevTs: ts - 1}), 0, 1);
    }

    /// @dev Play money from the faucet, and ETH for the fill fees of the commits.
    function _faucet(address who) internal {
        vm.deal(who, 1 ether);
        vm.startPrank(who);
        chip.faucet();
        chip.approve(address(router), type(uint256).max);
        chip.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _commit(address who, bytes32 roundId, uint8 index, bool isBuy, uint256 shares, uint256 limit)
        internal
        returns (uint256 id)
    {
        vm.startPrank(who);
        if (!isBuy) ticketsOf(hook, roundId)[index].approve(address(router), shares);
        id = router.commit{value: FILL_FEE}(roundId, index, isBuy, shares, limit);
        vm.stopPrank();
    }

    function test_fork_testnet_wholeSystem_realPythDay_andKeeperRound() public {
        if (!_fork("FORK_RPC_46630", 46630)) return;
        _playFriday();
    }

    function test_fork_mainnet_wholeSystem_realPythDay_andKeeperRound() public {
        if (!_fork("FORK_RPC_4663", 4663)) return;
        _playFriday();
    }

    function _fillPyth(uint256 id, bytes memory blob) internal {
        uint256 fee = _pythFee(blob);
        vm.deal(keeper, 1 ether);
        bytes memory report = _pyth(blob);
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        bool filled = router.fill{value: fee}(id, report);
        emit log_named_uint("gas of a fill verified by the live Pyth contract", gasBefore - gasleft());
        assertTrue(filled, "refunded");
        // the keeper paid the oracle's update fee and earned the commit's fill fee
        assertEq(keeper.balance, 1 ether - fee + FILL_FEE, "the filler was paid the fill fee");
    }

    function _fillKeeper(uint256 id, uint256 price) internal {
        bytes memory print = _keeperPrint(price, router.getCommit(id).fillTs);
        vm.prank(keeper);
        assertTrue(router.fill(id, print), "refunded");
    }

    function _playFriday() internal {
        // ---- what the script left behind
        assertEq(address(vault.hook()), address(hook), "the vault and the hook pin each other");
        assertEq(address(router.poolManager()), POOL_MANAGER);
        assertEq(address(hook.vault()), address(vault));
        assertEq(vault.hook(), address(hook));
        assertEq(address(router.hook()), address(hook));
        assertEq(address(oracle.pyth()), address(PYTH));
        assertEq(oracle.owner(), address(this));
        assertEq(book.owner(), address(this));
        assertEq(oracle.threshold(), 2);
        assertEq(oracle.config(TSLA).pythFeedId, TslaClose20261002.FEED_ID);
        assertEq(uint8(book.getTicker(TSLA).fillSource), uint8(IPitBook.FillSource.TrustlessOnly));
        assertEq(uint8(book.getTicker(NVDA).fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        bytes32 tslaHouse = sys.houses[0];
        bytes32 nvdaHouse = sys.houses[1];
        assertEq(vault.chipOf(tslaHouse), address(chip));
        assertEq(vault.roundCapital(tslaHouse), 100_000e18);

        // ---- play money from the faucet; carol joins the TSLA house as an LP
        _faucet(alice);
        _faucet(bob);
        _faucet(carol);
        vm.prank(carol);
        vault.deposit(tslaHouse, 1_000e18);
        uint256 supplyAtStart = chip.totalSupply();
        assertEq(supplyAtStart, 10_000_000e18 + 3_000e18);

        // ---- Thursday's closes: TSLA from the real Pyth update, NVDA from the keeper set
        uint256 fee = _pythFee(TslaDay20261002.THU_CLOSE_BLOB);
        emit log_named_uint("Pyth update fee (wei)", fee);
        book.recordClose{value: fee}(TSLA, thursday, _pyth(TslaDay20261002.THU_CLOSE_BLOB));
        (uint256 s0, bool trustless) = book.closeOf(TSLA, thursday);
        assertEq(s0, TslaDay20261002.THU_CLOSE_PRICE_WAD);
        assertEq(s0, 354.15698e18);
        assertTrue(trustless);
        book.recordClose(NVDA, thursday, _keeperPrint(185e18, TslaDay20261002.THU_CLOSE_T));

        // ---- Friday's rounds open (the capital sits in the hook, not in the live PoolManager)
        bytes32 tslaRound = hook.openRound(TSLA, address(chip), friday);
        bytes32 nvdaRound = hook.openRound(NVDA, address(chip), friday);
        {
            IFallpitHook.RoundConfig memory c = hook.getConfig(tslaRound);
            assertEq(c.s0, 354.15698e18);
            assertEq(c.sigma, 0.035e18);
            assertEq(c.capital, 101_000e18);
            assertEq(hook.getConfig(nvdaRound).s0, 185e18);
        }
        assertEq(chip.balanceOf(address(hook)), 201_000e18, "both houses' capital sits in the hook");
        Ticket[12] memory tsla = ticketsOf(hook, tslaRound);
        Ticket[12] memory nvda = ticketsOf(hook, nvdaRound);
        emit log_named_uint("the pair, from", tsla[HIGHER].low());
        emit log_named_uint("a floor, from", tsla[F6].low());
        emit log_named_uint("the far floor, from", tsla[F7].low());

        // ---- 11:00:07 New York. TSLA opened 5% up. alice buys TSLA HIGHER at the previous close, bob buys
        //      NVDA HIGHER at the previous close.
        vm.warp(TslaDay20261002.FRI_1100_T - 2);
        uint256 a = _commit(alice, tslaRound, HIGHER, true, 300e18, 400e18);
        uint256 b = _commit(bob, nvdaRound, HIGHER, true, 300e18, 400e18);
        vm.warp(TslaDay20261002.FRI_1100_T);
        _wrongPrintsDoNotFill(a);
        _fillPyth(a, TslaDay20261002.FRI_1100_BLOB);
        _fillKeeper(b, 186.2e18);
        uint256 alicePaid = 1_000e18 - chip.balanceOf(alice);
        emit log_named_decimal_uint("alice paid for 300 TSLA HIGHER at the previous close", alicePaid, 18);
        emit log_named_decimal_uint(
            "bob paid for 300 NVDA HIGHER at the previous close", 1_000e18 - chip.balanceOf(bob), 18
        );
        assertGt(alicePaid, 270e18);
        assertLt(alicePaid, 320e18);
        assertEq(tsla[HIGHER].balanceOf(alice), 300e18);

        // ---- 14:30:02. bob buys two TSLA floors, the one above +2 sigma and the one from +1 to +2
        //      sigma; alice buys NVDA LOWER.
        vm.warp(TslaDay20261002.FRI_1430_T - 2);
        a = _commit(bob, tslaRound, F7, true, 400e18, 400e18);
        uint256 a2 = _commit(bob, tslaRound, F6, true, 100e18, 300e18);
        b = _commit(alice, nvdaRound, LOWER, true, 200e18, 300e18);
        vm.warp(TslaDay20261002.FRI_1430_T);
        _fillPyth(a, TslaDay20261002.FRI_1430_BLOB);
        _fillPyth(a2, TslaDay20261002.FRI_1430_BLOB);
        _fillKeeper(b, 185.9e18);
        assertEq(tsla[F7].balanceOf(bob), 400e18);
        assertEq(tsla[F6].balanceOf(bob), 100e18);

        // ---- 15:20:11. alice sells a third of her TSLA tokens, bob half of his NVDA tokens.
        vm.warp(TslaDay20261002.FRI_1520_T - 2);
        a = _commit(alice, tslaRound, HIGHER, false, 100e18, 0);
        b = _commit(bob, nvdaRound, HIGHER, false, 150e18, 0);
        vm.warp(TslaDay20261002.FRI_1520_T);
        uint256 before = chip.balanceOf(alice);
        _fillPyth(a, TslaDay20261002.FRI_1520_BLOB);
        _fillKeeper(b, 186.6e18);
        emit log_named_decimal_uint("alice received for 100 TSLA HIGHER", chip.balanceOf(alice) - before, 18);
        IFallpitHook.RoundState memory tslaOpen = hook.getState(tslaRound);
        IFallpitHook.RoundState memory nvdaOpen = hook.getState(nvdaRound);
        assertLt(tslaOpen.g, 1e18, "depth has decayed by the afternoon");

        // ---- 16:00:00. TSLA's close is the committed real update: recorded by anyone, final at once.
        //      NVDA's close comes from the keeper set and waits out the challenge window.
        vm.warp(TslaClose20261002.T + 5);
        fee = _pythFee(TslaClose20261002.BLOB);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        book.recordClose{value: fee}(TSLA, friday, _pyth(TslaClose20261002.BLOB));
        (uint256 close, bool closeTrustless) = book.closeOf(TSLA, friday);
        assertEq(close, TslaClose20261002.PRICE_WAD);
        assertEq(close, 370.65425e18);
        assertTrue(closeTrustless);
        book.recordClose(NVDA, friday, _keeperPrint(186.5e18, TslaClose20261002.T));

        hook.settleRound(tslaHouse, friday);
        hook.settleRound(nvdaHouse, friday);
        IFallpitHook.RoundState memory settled = hook.getState(tslaRound);
        assertTrue(settled.settledTrustless);
        // +4.55% on a 3.5% sigma: band 25, so the floor from +1 to +2 sigma wins, and HIGHER. alice's 200
        // HIGHER and bob's 100 of the floor.
        assertEq(settled.closeBand, 25);
        assertEq(settled.winners, uint16(1 << F6 | 1 << HIGHER));
        assertEq(settled.payoutOwed, 300e18);
        hook.finalizeRound(tslaHouse, friday);
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(nvdaHouse, friday);
        vm.warp(TslaClose20261002.T + 5 + 3600);
        hook.finalizeRound(nvdaHouse, friday);
        // NVDA +0.8% on a 3% sigma: band 21, the floor from 0 to +0.5 sigma and HIGHER win, LOWER loses
        assertEq(hook.getState(nvdaRound).winners, uint16(1 << F4 | 1 << HIGHER));

        // ---- redemption, fees, the houses
        vm.prank(alice);
        assertEq(router.redeem(tsla[HIGHER].id, 200e18), 200e18);
        vm.prank(bob);
        assertEq(router.redeem(nvda[HIGHER].id, 150e18), 150e18);
        vm.prank(bob);
        assertEq(router.redeem(tsla[F6].id, 100e18), 100e18);
        vm.prank(bob);
        vm.expectRevert(IFallpitHook.NotWinner.selector);
        router.redeem(tsla[F7].id, 400e18);
        assertEq(hook.collectProtocolFees(address(chip)), tslaOpen.protocolFees + nvdaOpen.protocolFees);

        PitVault.House memory h = vault.getHouse(tslaHouse);
        assertFalse(h.locked);
        assertEq(h.lpAssets + h.endowment, tslaOpen.held - 300e18 - tslaOpen.protocolFees);
        emit log_named_decimal_int(
            "TSLA house result on 101,000 (chips)", int256(h.lpAssets + h.endowment) - 101_000e18, 18
        );
        PitVault.House memory n = vault.getHouse(nvdaHouse);
        assertEq(n.lpAssets, nvdaOpen.held - 150e18 - nvdaOpen.protocolFees);
        emit log_named_decimal_int(
            "NVDA house result on 100,000 (chips)", int256(n.lpAssets) - 100_000e18, 18
        );
        uint256 carolShares = vault.balanceOf(carol, uint256(tslaHouse));
        vm.prank(carol);
        uint256 out = vault.requestWithdraw(tslaHouse, carolShares);
        assertApproxEqAbs(out, h.lpAssets * 1_000 / 101_000, 2, "carol's 1,000 of 101,000");
        // Friday's real return stepped TSLA's variance
        assertEq(book.getTicker(TSLA).lastCloseDay, friday);
        assertTrue(book.getTicker(TSLA).lastCloseStepped);

        // ---- every coin is accounted for: nothing was created, nothing is stranded
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, owed);
        assertEq(owed, 0, "only losing tokens are left outstanding");
        assertEq(chip.balanceOf(POOL_MANAGER), 0, "nothing ever went to the PoolManager");
        assertEq(chip.balanceOf(address(router)), 0);
        assertEq(chip.totalSupply(), supplyAtStart, "the day minted and burned nothing");
        assertEq(
            chip.balanceOf(alice) + chip.balanceOf(bob) + chip.balanceOf(carol) + chip.balanceOf(feeRecipient)
                + chip.balanceOf(address(vault)) + chip.balanceOf(address(script)),
            supplyAtStart,
            "cash conservation"
        );
        assertEq(vault.accounted(address(chip)), chip.balanceOf(address(vault)));
    }

    /// @dev The TSLA commit priced at 11:00:07 does not fill with another instant's update, nor with a
    ///      keeper print, however genuine: the round takes Pyth updates only.
    function _wrongPrintsDoNotFill(uint256 id) internal {
        vm.prank(keeper);
        vm.expectRevert();
        router.fill(id, _pyth(TslaDay20261002.FRI_1430_BLOB));
        uint64 t = TslaDay20261002.FRI_1100_T;
        vm.prank(keeper);
        sys.feeds[0].push(int256(uint256(371.99504e8)), t);
        bytes memory keeperPrint = _report2(
            oracle, PitOracle.Print({ticker: TSLA, price: 371.99504e18, ts: t, prevTs: t - 1}), 0, 1
        );
        (uint256 viaKeeper,,) = oracle.verifyAt(TSLA, t, keeperPrint);
        assertEq(viaKeeper, 371.99504e18, "the keeper print itself is genuine and bounded");
        vm.prank(keeper);
        vm.expectRevert();
        router.fill(id, keeperPrint);
        assertEq(uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Pending));
    }

    /// @dev Mainnet only: a keeper close print for NVDA bounded by the real Chainlink push feed and the
    ///      real stock token's multiplier, through the book. The round in force at Friday's close is found
    ///      by walking back from the latest round; the oracle's own walk is limited to 64 rounds, so once
    ///      the feed has moved on further this test skips.
    function test_fork_mainnet_keeperClose_boundedByTheRealChainlinkFeed() public {
        string memory rpc = vm.envOr("FORK_RPC_4663", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        friday = uint32(NYTime.daysFromCivil(2026, 10, 2));
        uint64 closeAt = NYTime.closeTs(friday);
        // the round in force at Friday 16:00:00 New York
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(NVDA_FEED).latestRoundData();
        uint256 walked;
        while (updatedAt > closeAt && walked < 64) {
            (, answer,, updatedAt,) = IChainlinkFeed(NVDA_FEED).getRoundData(--roundId);
            ++walked;
        }
        if (updatedAt > closeAt || updatedAt == 0) {
            emit log_string("the feed is more than 64 rounds past 2026-10-02 16:00: skipped");
            vm.skip(true);
            return;
        }
        uint256 multiplier = IStockToken(NVDA_TOKEN).uiMultiplier();
        uint256 underlying = uint256(answer) * 1e10 * 1e18 / multiplier;
        emit log_named_decimal_uint("NVDA push feed round in force at the close", uint256(answer), 8);
        emit log_named_uint("  rounds since", walked);
        emit log_named_decimal_uint("  underlying", underlying, 18);

        _makeSigners(3);
        oracle = new PitOracle(PYTH, address(this), signerAddrs, 2, 24 hours);
        PitOracle.TickerConfig memory cfg;
        cfg.aggregator = NVDA_FEED;
        cfg.stockToken = NVDA_TOKEN;
        oracle.setTicker(NVDA, cfg);
        book = new PitBook(oracle, address(this), 24 hours);
        // registered a day before the close (a new ticker is in force 24 hours later)
        vm.warp(closeAt - 1 days);
        book.registerTicker(
            NVDA,
            0.0009e18,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );

        vm.warp(closeAt + 30);
        PitOracle.Print memory p = PitOracle.Print({
            ticker: NVDA, price: underlying * 1004 / 1000, ts: closeAt, prevTs: closeAt - 1
        });
        // 1% away from the real feed: refused
        PitOracle.Print memory far =
            PitOracle.Print({ticker: NVDA, price: underlying * 101 / 100, ts: closeAt, prevTs: closeAt - 1});
        bytes memory farReport = _report2(oracle, far, 0, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, far.price, underlying));
        book.recordClose(NVDA, friday, farReport);
        // 0.4% away: recorded, not trustless
        vm.prank(alice);
        book.recordClose(NVDA, friday, _report2(oracle, p, 0, 1));
        (uint256 close, bool trustless) = book.closeOf(NVDA, friday);
        assertEq(close, p.price);
        assertFalse(trustless);
    }
}
