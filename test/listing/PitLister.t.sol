// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";

import {IntegrationFixture} from "../integration/IntegrationFixture.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {MockLaunchpad} from "./AnchorRegistry.t.sol";
import {PitVault} from "../../src/PitVault.sol";
import {AnchorRegistry} from "../../src/listing/AnchorRegistry.sol";
import {LaunchRecordSource} from "../../src/listing/LaunchRecordSource.sol";
import {PitLister} from "../../src/listing/PitLister.sol";
import {IPitLister} from "../../src/interfaces/IPitLister.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";

/// @notice PitLister on the full stack: one-transaction listing, the keeper-signed price, the seed lock.
contract PitListerTest is IntegrationFixture {
    bytes4 internal constant GET_LAUNCHED_TOKEN = 0x3cf28b5a;
    /// @dev The coin trades at $0.01: 100 coins (18 decimals) are worth 1 USD.
    uint256 internal constant COINS_PER_USD = 100e18;
    /// @dev $250 at that price.
    uint256 internal constant MIN_SEED = 25_000e18;

    address internal nvdaToken = makeAddr("nvdaToken");
    address internal tslaToken = makeAddr("tslaToken");
    address internal aaplToken = makeAddr("aaplToken");
    address internal team = makeAddr("team");

    MockLaunchpad internal pad;
    AnchorRegistry internal registry;
    MockChip internal coin;
    uint256 internal signerKey;

    function setUp() public override {
        super.setUp();
        registry = lister.registry();
        pad = new MockLaunchpad();
        vm.startPrank(owner);
        registry.addSource(
            new LaunchRecordSource(address(pad), GET_LAUNCHED_TOKEN, 0, LaunchRecordSource.KnownBy.Self, 4)
        );
        registry.nameTicker(nvdaToken, NVDA);
        registry.nameTicker(tslaToken, TSLA);
        registry.nameTicker(aaplToken, "AAPL"); // named, but no feed and no registration in the book
        vm.stopPrank();

        coin = _launch(nvdaToken);
        signerKey = keys[0];
        coin.mint(team, 1_000_000e18);
        vm.prank(team);
        coin.approve(address(lister), type(uint256).max);
    }

    function _launch(address anchor) internal returns (MockChip c) {
        c = new MockChip(18);
        uint256[] memory w = new uint256[](15);
        w[0] = uint160(address(c));
        w[4] = uint160(anchor);
        pad.setRecord(address(c), w);
        vm.prank(owner);
        guard.approve(address(c), true);
    }

    function _quote(address chip_, uint256 coinsPerUsd, uint64 expiry, uint256 key)
        internal
        view
        returns (IPitLister.ListingQuote memory q, bytes memory sig)
    {
        q = IPitLister.ListingQuote(chip_, coinsPerUsd, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, lister.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    function _list(address chip_, uint256 seed) internal returns (bytes32 h) {
        (IPitLister.ListingQuote memory q, bytes memory sig) =
            _quote(chip_, COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        vm.prank(team);
        h = lister.listCoin(chip_, seed, q, sig);
    }

    // ----------------------------------------------------------------------------------------- listing

    function test_listCoin_createsTheHouseOnTheLaunchAnchor_andLocksTheSeed() public {
        bytes32 expected = vault.houseId(NVDA, address(coin));
        (IPitLister.ListingQuote memory q, bytes memory sig) =
            _quote(address(coin), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        vm.expectEmit(true, true, true, false, address(lister));
        emit PitLister.CoinListed(expected, address(coin), NVDA, nvdaToken, address(0), team, 0, 0, 0);
        vm.prank(team);
        bytes32 h = lister.listCoin(address(coin), 30_000e18, q, sig);

        assertEq(h, expected);
        assertEq(vault.chipOf(h), address(coin));
        uint256 shares = vault.balanceOf(team, uint256(h));
        assertGt(shares, 0);
        assertApproxEqAbs(
            vault.convertToAssets(h, shares), 30_000e18, 2, "the seed is the team's vault stake"
        );
        (uint256 locked, uint64 until) = vault.lockOf(h, team);
        assertEq(locked, shares);
        assertEq(until, uint64(clock) + 7 days);
        assertEq(coin.balanceOf(address(lister)), 0, "the lister keeps nothing");
        assertEq(coin.balanceOf(team), 1_000_000e18 - 30_000e18);
    }

    function test_listCoin_seedUnderTheUsdFloor_reverts() public {
        (IPitLister.ListingQuote memory q, bytes memory sig) =
            _quote(address(coin), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        assertEq(lister.minSeed(address(coin), COINS_PER_USD), MIN_SEED);
        vm.prank(team);
        vm.expectRevert(abi.encodeWithSelector(PitLister.SeedTooSmall.selector, MIN_SEED - 1, MIN_SEED));
        lister.listCoin(address(coin), MIN_SEED - 1, q, sig);
        vm.prank(team);
        lister.listCoin(address(coin), MIN_SEED, q, sig);
    }

    /// @dev A dear coin: $250 is fewer coins than the smallest round capital, so that capital is the floor.
    function test_minSeed_neverUnderTheSmallestRoundCapital() public view {
        uint256 floor = uint256(book.defaultParams().minCapital) * 1e18;
        assertEq(lister.minSeed(address(coin), 1e15), floor); // $1,000 a coin: $250 is 0.25 coins
    }

    function test_listCoin_quoteChecks() public {
        uint64 exp = uint64(clock) + 5 minutes;
        MockChip other = _launch(tslaToken);
        // a quote of another coin
        (IPitLister.ListingQuote memory q, bytes memory sig) =
            _quote(address(other), COINS_PER_USD, exp, signerKey);
        vm.prank(team);
        vm.expectRevert(PitLister.QuoteForAnotherCoin.selector);
        lister.listCoin(address(coin), MIN_SEED, q, sig);
        // expired
        (q, sig) = _quote(address(coin), COINS_PER_USD, uint64(clock) - 1, signerKey);
        vm.prank(team);
        vm.expectRevert(PitLister.QuoteExpired.selector);
        lister.listCoin(address(coin), MIN_SEED, q, sig);
        // lives too long
        (q, sig) = _quote(address(coin), COINS_PER_USD, uint64(clock) + 11 minutes, signerKey);
        vm.prank(team);
        vm.expectRevert(PitLister.QuoteTooLong.selector);
        lister.listCoin(address(coin), MIN_SEED, q, sig);
        // signed by someone who is not a keeper signer
        (address eve, uint256 eveKey) = makeAddrAndKey("eve");
        (q, sig) = _quote(address(coin), COINS_PER_USD, exp, eveKey);
        vm.prank(team);
        vm.expectRevert(abi.encodeWithSelector(PitLister.NotASigner.selector, eve));
        lister.listCoin(address(coin), MIN_SEED, q, sig);
        // a price changed after signing (a cheaper seed) does not recover to a signer
        (q, sig) = _quote(address(coin), COINS_PER_USD, exp, signerKey);
        q.coinsPerUsd = 1e18;
        vm.prank(team);
        vm.expectRevert();
        lister.listCoin(address(coin), MIN_SEED, q, sig);
    }

    function test_listCoin_anchorChecks() public {
        MockChip stray = new MockChip(18); // no launch record
        stray.mint(team, MIN_SEED);
        (IPitLister.ListingQuote memory q, bytes memory sig) =
            _quote(address(stray), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        vm.prank(team);
        vm.expectRevert(abi.encodeWithSelector(AnchorRegistry.UnknownLaunch.selector, address(stray)));
        lister.listCoin(address(stray), MIN_SEED, q, sig);

        address unnamed = makeAddr("unnamedStock");
        MockChip c2 = _launch(unnamed);
        (q, sig) = _quote(address(c2), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        vm.prank(team);
        vm.expectRevert(abi.encodeWithSelector(AnchorRegistry.AnchorNotListed.selector, address(c2), unnamed));
        lister.listCoin(address(c2), MIN_SEED, q, sig);

        // named, but the book has no AAPL: the vault's gate refuses it
        MockChip c3 = _launch(aaplToken);
        (q, sig) = _quote(address(c3), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        vm.prank(team);
        vm.expectRevert(PitVault.TickerNotSupported.selector);
        lister.listCoin(address(c3), MIN_SEED, q, sig);
    }

    function test_listCoin_twice_reverts() public {
        _list(address(coin), MIN_SEED);
        (IPitLister.ListingQuote memory q, bytes memory sig) =
            _quote(address(coin), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        vm.prank(team);
        vm.expectRevert(PitVault.HouseExists.selector);
        lister.listCoin(address(coin), MIN_SEED, q, sig);
    }

    function test_listCoin_coinTheGuardRefuses_reverts() public {
        vm.prank(owner);
        guard.refuse(address(coin), true);
        (IPitLister.ListingQuote memory q, bytes memory sig) =
            _quote(address(coin), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        vm.prank(team);
        vm.expectRevert(PitVault.ChipNotAllowed.selector);
        lister.listCoin(address(coin), MIN_SEED, q, sig);
    }

    // -------------------------------------------------------------------------------------------- lock

    function test_lock_blocksWithdrawAndTransfer_untilItEnds() public {
        bytes32 h = _list(address(coin), MIN_SEED);
        uint256 shares = vault.balanceOf(team, uint256(h));
        (, uint64 until) = vault.lockOf(h, team);

        vm.startPrank(team);
        vm.expectRevert(abi.encodeWithSelector(PitVault.Locked.selector, shares, until));
        vault.requestWithdraw(h, 1);
        vm.expectRevert(abi.encodeWithSelector(PitVault.Locked.selector, shares, until));
        vault.transfer(alice, uint256(h), 1);
        vault.setOperator(alice, true);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PitVault.Locked.selector, shares, until));
        vault.transferFrom(team, alice, uint256(h), shares);

        // a later deposit above the seed is free to leave
        coin.mint(team, 1_000e18);
        vm.startPrank(team);
        coin.approve(address(vault), 1_000e18);
        uint256 extra = vault.deposit(h, 1_000e18);
        vault.requestWithdraw(h, extra);
        vm.stopPrank();
        assertEq(vault.balanceOf(team, uint256(h)), shares);

        // one second before the end it still holds; at the end it is gone
        _warp(until - 1);
        vm.prank(team);
        vm.expectRevert(abi.encodeWithSelector(PitVault.Locked.selector, shares, until));
        vault.requestWithdraw(h, shares);
        _warp(until);
        (uint256 left,) = vault.lockOf(h, team);
        assertEq(left, 0);
        vm.prank(team);
        uint256 out = vault.requestWithdraw(h, shares);
        assertApproxEqAbs(out, MIN_SEED, 1);
    }

    /// @dev Other depositors are not touched by a lister's lock.
    function test_lock_isOnlyTheListers() public {
        bytes32 h = _list(address(coin), MIN_SEED);
        coin.mint(bob, 5_000e18);
        vm.startPrank(bob);
        coin.approve(address(vault), 5_000e18);
        uint256 s = vault.deposit(h, 5_000e18);
        vault.transfer(carol, uint256(h), s / 2);
        vault.requestWithdraw(h, s / 2);
        vm.stopPrank();
        (uint256 locked,) = vault.lockOf(h, bob);
        assertEq(locked, 0);
    }

    /// @dev The listed house opens a round like any other: the seed is its capital.
    function test_listedHouse_opensARound() public {
        bytes32 h = _list(address(coin), MIN_SEED);
        roundChip = address(coin);
        bytes32 r = _open();
        assertTrue(r != bytes32(0));
        assertEq(hook.houseRound(h), r);
        // while the round runs, the locked seed cannot even queue a withdrawal
        vm.prank(team);
        vm.expectRevert();
        vault.requestWithdraw(h, 1);
    }

    // ------------------------------------------------------------------------------------- permissions

    function test_vault_onlyTheListerCreatesHouses_andLocksSeeds() public {
        MockChip c = _launch(nvdaToken);
        vm.expectRevert(PitVault.OnlyLister.selector);
        vault.createHouse(NVDA, address(c));
        vm.prank(owner);
        vm.expectRevert(PitVault.OnlyLister.selector);
        vault.createHouse(NVDA, address(c));
        vm.expectRevert(PitVault.OnlyLister.selector);
        vault.depositLocked(house, 1e18, alice, uint64(clock) + 1 days);
        // set once, by the deployer only
        vm.expectRevert(PitVault.ListerAlreadySet.selector);
        vault.setLister(alice);
        vm.prank(alice);
        vm.expectRevert(PitVault.OnlyDeployer.selector);
        vault.setLister(alice);
        assertEq(vault.lister(), address(lister));
    }

    function test_ownerRoute_createsAHouseWithoutAnchorCheck() public {
        MockChip stray = new MockChip(18);
        vm.prank(owner);
        guard.approve(address(stray), true);
        vm.prank(team);
        vm.expectRevert(Ownable.Unauthorized.selector);
        lister.createHouse(TSLA, address(stray));
        vm.prank(owner);
        bytes32 h = lister.createHouse(TSLA, address(stray));
        assertEq(vault.chipOf(h), address(stray));
    }

    function test_ownerSetters_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(PitLister.OutOfBounds.selector);
        lister.setMinSeedUsd(49);
        vm.expectRevert(PitLister.OutOfBounds.selector);
        lister.setMinSeedUsd(5001);
        lister.setMinSeedUsd(500);
        vm.expectRevert(PitLister.OutOfBounds.selector);
        lister.setLockTime(1 days - 1);
        vm.expectRevert(PitLister.OutOfBounds.selector);
        lister.setLockTime(30 days + 1);
        lister.setLockTime(14 days);
        vm.stopPrank();
        assertEq(lister.minSeed(address(coin), COINS_PER_USD), 2 * MIN_SEED);
        bytes32 h = _list(address(coin), 2 * MIN_SEED);
        (, uint64 until) = vault.lockOf(h, team);
        assertEq(until, uint64(clock) + 14 days);
        vm.prank(team);
        vm.expectRevert(Ownable.Unauthorized.selector);
        lister.setMinSeedUsd(250);
    }

    /// @dev Whatever the lister tries before the lock ends (withdraw or transfer any amount, after any extra
    ///      deposit), its balance never drops under the locked shares; after the end, all of it can leave.
    function testFuzz_lock_neverLetsTheSeedOutEarly(uint96 extra, uint256 out, uint32 dt, bool viaTransfer)
        public
    {
        bytes32 h = _list(address(coin), MIN_SEED);
        (uint256 locked, uint64 until) = vault.lockOf(h, team);
        extra = uint96(bound(extra, 0, 100_000e18));
        if (extra > 0) {
            coin.mint(team, extra);
            vm.startPrank(team);
            coin.approve(address(vault), extra);
            vault.deposit(h, extra);
            vm.stopPrank();
        }
        uint256 bal = vault.balanceOf(team, uint256(h));
        out = bound(out, 1, bal);
        _warp(uint64(clock + bound(dt, 0, 7 days - 1)));
        vm.prank(team);
        if (out > bal - locked) {
            vm.expectRevert(abi.encodeWithSelector(PitVault.Locked.selector, locked, until));
        }
        if (viaTransfer) vault.transfer(alice, uint256(h), out);
        else vault.requestWithdraw(h, out);
        assertGe(vault.balanceOf(team, uint256(h)), locked);

        _warp(until);
        uint256 rest = vault.balanceOf(team, uint256(h));
        vm.prank(team);
        vault.requestWithdraw(h, rest);
        assertEq(vault.balanceOf(team, uint256(h)), 0);
    }

    // ---------------------------------------------------------------------------------- session listing

    function _sessionSetup(uint256 maxPerOrder, uint8 scope)
        internal
        returns (address sam, uint256 sessionPk, address key)
    {
        uint256 samKey;
        (sam, samKey) = makeAddrAndKey("sam");
        (key, sessionPk) = makeAddrAndKey("samSession");
        coin.mint(sam, 100_000e18);
        vm.prank(sam);
        coin.approve(address(router), type(uint256).max);
        IFallpitRouter.SessionGrant memory g = IFallpitRouter.SessionGrant({
            user: sam,
            key: key,
            expiry: uint64(clock) + 1 days,
            maxPerOrder: maxPerOrder,
            maxTotal: 0,
            scope: scope,
            nonce: router.sessionNonce(sam)
        });
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(samKey, router.grantDigest(g));
        router.grantSession(g, abi.encodePacked(r, s_, v));
    }

    function _listOp(address sam, uint256 seed, uint256 nonce, uint256 pk)
        internal
        view
        returns (IFallpitRouter.ListOp memory op, bytes memory sig)
    {
        op = IFallpitRouter.ListOp({
            user: sam, chip: address(coin), seed: seed, deadline: uint64(clock) + 60, nonce: nonce
        });
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, router.listOpDigest(op));
        sig = abi.encodePacked(r, s_, v);
    }

    /// @dev One session signature, relayed by anyone: the house exists, the seed is locked for the user, and
    ///      nothing stays with the router, the relayer or the key.
    function test_listWithSig_listsForTheUser() public {
        (address sam, uint256 pk, address key) = _sessionSetup(1_000_000e18, 2);
        (IFallpitRouter.ListOp memory op, bytes memory sig) = _listOp(sam, MIN_SEED, 1, pk);
        (IPitLister.ListingQuote memory q, bytes memory qsig) =
            _quote(address(coin), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        bytes32 h = router.listWithSig(op, q, qsig, key, sig);

        assertEq(h, vault.houseId(NVDA, address(coin)));
        uint256 shares = vault.balanceOf(sam, uint256(h));
        (uint256 locked, uint64 until) = vault.lockOf(h, sam);
        assertGt(shares, 0);
        assertEq(locked, shares);
        assertEq(until, uint64(clock) + 7 days);
        assertEq(coin.balanceOf(sam), 100_000e18 - MIN_SEED);
        assertEq(coin.balanceOf(address(router)), 0);
        assertEq(coin.balanceOf(address(lister)), 0);
        assertEq(vault.balanceOf(relayer, uint256(h)), 0);
        assertEq(vault.balanceOf(key, uint256(h)), 0);

        // the same signed op cannot run twice
        vm.expectRevert(IFallpitRouter.OrderUsed.selector);
        router.listWithSig(op, q, qsig, key, sig);
    }

    function test_listWithSig_sessionChecks() public {
        (address sam, uint256 pk, address key) = _sessionSetup(MIN_SEED - 1, 2);
        (IPitLister.ListingQuote memory q, bytes memory qsig) =
            _quote(address(coin), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        (IFallpitRouter.ListOp memory op, bytes memory sig) = _listOp(sam, MIN_SEED, 1, pk);
        vm.expectRevert(IFallpitRouter.OverSessionCap.selector);
        router.listWithSig(op, q, qsig, key, sig);

        // a trade-only session cannot list
        (sam, pk, key) = _sessionSetup(1_000_000e18, 1);
        (op, sig) = _listOp(sam, MIN_SEED, 2, pk);
        vm.expectRevert(IFallpitRouter.OutOfScope.selector);
        router.listWithSig(op, q, qsig, key, sig);

        // a signature by another key
        (sam, pk, key) = _sessionSetup(1_000_000e18, 2);
        (op, sig) = _listOp(sam, MIN_SEED, 3, signerKey);
        vm.expectRevert(IFallpitRouter.BadSignature.selector);
        router.listWithSig(op, q, qsig, key, sig);
    }

    function test_listCoinFor_onlyTheRouter() public {
        (IPitLister.ListingQuote memory q, bytes memory sig) =
            _quote(address(coin), COINS_PER_USD, uint64(clock) + 5 minutes, signerKey);
        vm.prank(team);
        vm.expectRevert(PitLister.OnlyRouter.selector);
        lister.listCoinFor(team, address(coin), MIN_SEED, q, sig);
    }
}
