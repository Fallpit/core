// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";

/// @notice Router sessions and signed orders: `redeemFor` never pays the router, a relayed commit's fill fee
///         goes back to its payer, a session's total cap bounds a stolen key, scopes hold, and a cancelled
///         order can never be relayed.
contract SessionSafetyTest is IntegrationFixture {
    uint256 internal constant STAKE = 100_000e18;

    address internal sam;
    uint256 internal samKey;
    address internal sessionKey;
    uint256 internal sessionPk;
    address internal relayer = makeAddr("relayer");
    address internal eve = makeAddr("eve");

    function setUp() public override {
        super.setUp();
        (sam, samKey) = makeAddrAndKey("sam");
        (sessionKey, sessionPk) = makeAddrAndKey("sessionKey");
        _fund(sam, STAKE);
        _fund(eve, STAKE);
        vm.deal(relayer, 1 ether);
        _open();
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _grantSam(uint256 maxPerOrder, uint256 maxTotal, uint8 scope) internal {
        IFallpitRouter.SessionGrant memory g = IFallpitRouter.SessionGrant({
            user: sam,
            key: sessionKey,
            expiry: clock + 1 days,
            maxPerOrder: maxPerOrder,
            maxTotal: maxTotal,
            scope: scope,
            nonce: router.sessionNonce(sam)
        });
        router.grantSession(g, _sig(samKey, router.grantDigest(g)));
    }

    /// @dev A grant with no real limits: maxPerOrder 1e30, no total cap, trade and vault.
    function _grantSam() internal {
        _grantSam(1e30, 0, 3);
    }

    function _order(uint8 product, bool isBuy, uint256 shares, uint256 limit, uint256 nonce)
        internal
        view
        returns (IFallpitRouter.Order memory)
    {
        return IFallpitRouter.Order({
            user: sam,
            roundId: roundId,
            product: product,
            isBuy: isBuy,
            shares: shares,
            limit: limit,
            deadline: clock + 60,
            nonce: nonce
        });
    }

    function _relay(IFallpitRouter.Order memory o) internal returns (uint256 id) {
        bytes memory sig = _sig(sessionPk, router.orderDigest(o));
        uint256 fee = _fillFee();
        vm.prank(relayer);
        id = router.commitWithSig{value: fee}(o, sessionKey, sig);
    }

    function _relayReverts(IFallpitRouter.Order memory o, bytes memory err) internal {
        bytes memory sig = _sig(sessionPk, router.orderDigest(o));
        uint256 fee = _fillFee();
        vm.prank(relayer);
        vm.expectRevert(err);
        router.commitWithSig{value: fee}(o, sessionKey, sig);
    }

    /// @notice `redeemFor` refuses the router (its balance is the escrow of pending sells) and the hook.
    ///         The pending sell's escrow stays whole and the seller gets it back.
    function test_redeemForRouter_refused_escrowStaysWhole() public {
        _fund(alice, STAKE);
        _buy(alice, HIGHER, 1_000e18, S0);
        uint256 id = _commitSell(alice, HIGHER, 1_000e18, 0);
        Ticket memory t = _token(HIGHER);
        assertEq(t.balanceOf(address(router)), 1_000e18, "escrow in the router");

        _closeAndFinalize(S0 * 101 / 100); // HIGHER wins
        vm.startPrank(eve);
        vm.expectRevert(IFallpitRouter.BadHolder.selector);
        router.redeemFor(address(router), t.id);
        vm.expectRevert(IFallpitRouter.BadHolder.selector);
        router.redeemFor(address(hook), t.id);
        vm.stopPrank();
        assertEq(t.balanceOf(address(router)), 1_000e18, "escrow untouched");
        assertEq(router.escrowedTickets(t.id), 1_000e18);

        // the seller's refund works once the window is over, and she redeems her winning tokens
        router.refund(id);
        assertEq(t.balanceOf(alice), 1_000e18, "tokens back to the seller");
        uint256 before = MockChip(roundChip).balanceOf(alice);
        vm.prank(eve);
        assertEq(router.redeemFor(alice, t.id), 1_000e18, "anyone may still redeem for a real holder");
        assertEq(MockChip(roundChip).balanceOf(alice), before + 1_000e18);
    }

    /// @notice A user who fills its own relayed commit that the fill rejects does not take the
    ///         relayer's fee: the fee goes back to the relayer (`feePayerOf`).
    function test_rejectedRelayedCommit_feeBackToTheRelayer() public {
        _grantSam();
        _buy(sam, HIGHER, 1_000e18, S0);
        uint256 relayerEth = relayer.balance;
        uint256 samEth = sam.balance;

        uint256 id = _relay(_order(HIGHER, false, 1_000e18, 1e30, 1));
        assertEq(relayer.balance, relayerEth - FILL_FEE, "the relay paid the fee");

        bytes memory report = _printFor(id, S0);
        vm.prank(sam);
        bool filled = router.fill(id, report);
        assertFalse(filled, "refunded: limit out of reach");
        assertEq(_token(HIGHER).balanceOf(sam), 1_000e18, "tokens back");
        assertEq(sam.balance, samEth, "the user earns nothing");
        assertEq(relayer.balance, relayerEth, "the relay has its fee back");
        assertEq(address(router).balance, 0);
    }

    /// @notice The filler's oracle ETH of a rejected fill still goes back to the filler, not the fee payer.
    function test_rejectedFill_oracleEthBackToTheFiller() public {
        _grantSam();
        _buy(sam, HIGHER, 1_000e18, S0);
        uint256 id = _relay(_order(HIGHER, false, 1_000e18, 1e30, 1));
        bytes memory report = _printFor(id, S0);
        vm.deal(eve, 1 ether);
        uint256 relayerEth = relayer.balance;
        vm.prank(eve);
        assertFalse(router.fill{value: 0.01 ether}(id, report));
        assertEq(eve.balance, 1 ether, "eve gets her oracle ETH back and no fee");
        assertEq(relayer.balance, relayerEth + FILL_FEE, "the fee goes to its payer");
    }

    /// @notice Honest keeper: it relays and fills. A trade pays it the fee; a rejection pays its fee back.
    function test_honestKeeper_stillPaid() public {
        _grantSam();
        _buy(sam, HIGHER, 1_000e18, S0);
        uint256 start = relayer.balance;

        uint256 ok = _relay(_order(HIGHER, false, 400e18, 0, 1));
        bytes memory report = _printFor(ok, S0);
        vm.prank(relayer);
        assertTrue(router.fill(ok, report));
        assertEq(relayer.balance, start, "fee paid and earned back by the fill");

        uint256 bad = _relay(_order(HIGHER, false, 400e18, 1e30, 2));
        report = _printFor(bad, S0);
        vm.prank(relayer);
        assertFalse(router.fill(bad, report));
        assertEq(relayer.balance, start, "fee back on the rejection");
    }

    /// @notice The user fills its own relayed commit and the fill trades: the fee goes back to the relayer.
    function test_relayedCommit_filledByTheUser_feeBackToTheRelayer() public {
        _grantSam();
        uint256 relayerEth = relayer.balance;
        uint256 samEth = sam.balance;
        uint256 id = _relay(_order(HIGHER, true, 1_000e18, 10_000e18, 1));
        assertEq(router.feePayerOf(id), relayer);
        bytes memory report = _printFor(id, S0);
        vm.prank(sam);
        assertTrue(router.fill(id, report), "a trade");
        assertEq(_token(HIGHER).balanceOf(sam), 1_000e18);
        assertEq(sam.balance, samEth, "the user earns nothing");
        assertEq(relayer.balance, relayerEth, "the relay has its fee back");
        assertEq(address(router).balance, 0);
    }

    /// @notice A third party fills a relayed commit that trades: the fee goes back to the
    ///         relayer, not to the filler.
    function test_relayedCommit_filledByAThirdParty_feeBackToTheRelayer() public {
        _grantSam();
        uint256 relayerEth = relayer.balance;
        uint256 id = _relay(_order(HIGHER, true, 1_000e18, 10_000e18, 1));
        bytes memory report = _printFor(id, S0);
        vm.deal(eve, 1 ether);
        vm.prank(eve);
        assertTrue(router.fill(id, report), "a trade");
        assertEq(eve.balance, 1 ether, "the filler earns no fee");
        assertEq(relayer.balance, relayerEth, "the relay has its fee back");
        assertEq(address(router).balance, 0);
    }

    /// @notice A thief with a session key and a total cap on the session:
    ///         the thief cannot make Sam buy more than `maxTotal` chips in all, whatever `maxPerOrder` is.
    function test_stolenKey_spendLimitedByMaxTotal() public {
        uint256 maxTotal = 1_000e18;
        _grantSam(1e30, maxTotal, router.SCOPE_TRADE());
        uint256 samStart = MockChip(roundChip).balanceOf(sam);

        uint256 a = _commitBuy(eve, HIGHER, 8_000e18, MockChip(roundChip).balanceOf(eve));
        // Sam buys 20,000 HIGHER at any price: refused
        _relayReverts(
            _order(HIGHER, true, 20_000e18, samStart, 7),
            abi.encodeWithSelector(IFallpitRouter.OverSessionTotal.selector, samStart, maxTotal)
        );
        // the most the thief can make Sam spend
        uint256 v = _relay(_order(HIGHER, true, 1_000e18, 600e18, 8));
        _relayReverts(
            _order(HIGHER, true, 1_000e18, 400e18 + 1, 9),
            abi.encodeWithSelector(IFallpitRouter.OverSessionTotal.selector, 1_000e18 + 1, maxTotal)
        );
        uint256 w = _relay(_order(HIGHER, true, 500e18, 400e18, 10));
        assertEq(router.sessionSpent(sam, sessionKey, roundChip), maxTotal, "spent up to the cap");

        assertTrue(_fill(a, S0));
        _fill(v, S0);
        _fill(w, S0);
        uint256 samSpent = samStart - MockChip(roundChip).balanceOf(sam);
        console.log("sam spent (chips), cap 1000", samSpent / 1e18);
        assertLe(samSpent, maxTotal, "never more than maxTotal");

        // refunds give nothing back to the cap (conservative)
        _relayReverts(
            _order(HIGHER, true, 100e18, 1, 11),
            abi.encodeWithSelector(IFallpitRouter.OverSessionTotal.selector, maxTotal + 1, maxTotal)
        );
        // sells are not counted in maxTotal (they spend tokens, bounded by maxPerOrder)
        uint256 held = _token(HIGHER).balanceOf(sam);
        if (held != 0) _relay(_order(HIGHER, false, held, 0, 12));
        // a new grant (signed by Sam) starts the count at zero
        _grantSam(1e30 - 1, maxTotal, router.SCOPE_TRADE());
        assertEq(router.sessionSpent(sam, sessionKey, roundChip), 0);
        _relay(_order(HIGHER, true, 100e18, 100e18, 13));
        assertEq(router.sessionSpent(sam, sessionKey, roundChip), 100e18);
    }

    /// @notice maxTotal 0 means no total cap.
    function test_maxTotalZero_noTotalCap() public {
        _grantSam(5_000e18, 0, router.SCOPE_TRADE());
        for (uint256 i; i < 4; ++i) {
            _relay(_order(HIGHER, true, 1_000e18, 5_000e18, 20 + i));
        }
        assertEq(router.sessionSpent(sam, sessionKey, roundChip), 20_000e18);
    }

    function test_scope_vaultOnly_cannotTrade() public {
        _grantSam(1e30, 0, router.SCOPE_VAULT());
        _relayReverts(
            _order(HIGHER, true, 100e18, 100e18, 1),
            abi.encodeWithSelector(IFallpitRouter.OutOfScope.selector)
        );
    }

    function test_scope_tradeOnly_cannotUseTheVault() public {
        _grantSam(1e30, 0, router.SCOPE_TRADE());
        IFallpitRouter.VaultOp memory o = IFallpitRouter.VaultOp({
            user: sam, op: 2, house: house, amount: 1, minOut: 0, deadline: clock + 60, nonce: 1
        });
        bytes memory sig = _sig(sessionPk, router.vaultOpDigest(o));
        vm.prank(relayer);
        vm.expectRevert(IFallpitRouter.OutOfScope.selector);
        router.vaultWithSig(o, sessionKey, sig);
        _relay(_order(HIGHER, true, 100e18, 100e18, 1));
    }

    function test_cancel_digest_matchesTheTypeString() public view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Fallpit Router"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
        bytes32 h =
            keccak256(abi.encode(keccak256("CancelOrder(address user,uint256 nonce)"), sam, uint256(42)));
        assertEq(router.cancelDigest(sam, 42), keccak256(abi.encodePacked(hex"1901", domain, h)));
    }

    /// @notice A signed order cancelled on chain can never be relayed, also after the session
    ///         was revoked and the same key granted again.
    function test_cancelWithSig_beatsARelayAfterRegrant() public {
        _grantSam();
        IFallpitRouter.Order memory o = _order(HIGHER, true, 100e18, 100e18, 5);

        bytes memory csig = _sig(sessionPk, router.cancelDigest(sam, 5));
        vm.expectEmit(true, true, false, true, address(router));
        emit IFallpitRouter.OrderCancelled(sam, sessionKey, 5, relayer);
        vm.prank(relayer);
        router.cancelWithSig(sam, 5, sessionKey, csig);
        assertTrue(router.orderNonceUsed(sam, 5));
        _relayReverts(o, abi.encodeWithSelector(IFallpitRouter.OrderUsed.selector));

        // a second cancel of the same nonce reverts
        vm.expectRevert(IFallpitRouter.OrderUsed.selector);
        router.cancelWithSig(sam, 5, sessionKey, csig);

        // after a revoke the key may still cancel
        vm.prank(sam);
        router.revokeSession(sessionKey);
        assertEq(router.sessionOf(sam, sessionKey).expiry, 0, "revoked");
        router.cancelWithSig(sam, 6, sessionKey, _sig(sessionPk, router.cancelDigest(sam, 6)));

        // the same key granted again: the cancelled orders stay dead
        _grantSam(1e30 - 1, 0, 3);
        _relayReverts(o, abi.encodeWithSelector(IFallpitRouter.OrderUsed.selector));
        _relayReverts(
            _order(HIGHER, true, 100e18, 100e18, 6), abi.encodeWithSelector(IFallpitRouter.OrderUsed.selector)
        );
        _relay(_order(HIGHER, true, 100e18, 100e18, 7));
    }

    function test_cancelWithSig_refusals() public {
        _grantSam();
        // signed by another key for the session key
        (address other, uint256 otherPk) = makeAddrAndKey("other");
        bytes memory bad = _sig(otherPk, router.cancelDigest(sam, 5));
        vm.expectRevert(IFallpitRouter.BadSignature.selector);
        router.cancelWithSig(sam, 5, sessionKey, bad);
        // a key that never had a session for the user
        vm.expectRevert(IFallpitRouter.NotSessionKey.selector);
        router.cancelWithSig(sam, 5, other, bad);
        // a session ended by a nonce bump
        vm.prank(sam);
        router.bumpSessionNonce();
        bytes memory csig = _sig(sessionPk, router.cancelDigest(sam, 5));
        vm.expectRevert(IFallpitRouter.NotSessionKey.selector);
        router.cancelWithSig(sam, 5, sessionKey, csig);
        assertFalse(router.orderNonceUsed(sam, 5));
    }

    function test_useNonces_burnsTheCallersOwnNonces() public {
        _grantSam();
        vm.expectEmit(true, false, false, true, address(router));
        emit IFallpitRouter.NoncesUsed(sam, 1, (1 << 3) | (1 << 200));
        vm.prank(sam);
        router.useNonces(1, (1 << 3) | (1 << 200));
        assertTrue(router.orderNonceUsed(sam, 256 + 3));
        assertTrue(router.orderNonceUsed(sam, 256 + 200));
        assertFalse(router.orderNonceUsed(sam, 256 + 4));
        assertFalse(router.orderNonceUsed(eve, 256 + 3), "only the caller's");
        _relayReverts(
            _order(HIGHER, true, 100e18, 100e18, 256 + 3),
            abi.encodeWithSelector(IFallpitRouter.OrderUsed.selector)
        );
        _relay(_order(HIGHER, true, 100e18, 100e18, 256 + 4));
        // used nonces stay used
        vm.prank(sam);
        router.useNonces(1, 0);
        assertTrue(router.orderNonceUsed(sam, 256 + 4));
    }
}
