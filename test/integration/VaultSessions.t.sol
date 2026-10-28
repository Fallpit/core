// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {PitVault} from "../../src/PitVault.sol";

/// @notice Vault actions by session: a key the user granted signs `VaultOp`s, anyone relays them through
///         `FallpitRouter.vaultWithSig`, and the router acts for the user through the vault's `...For`
///         functions. Shares and chips always end with the user. Also the vault's operator path.
contract VaultSessionsTest is IntegrationFixture {
    uint256 internal constant STAKE = 100_000e18;
    uint256 internal constant CAP = 50_000e18;

    address internal sam;
    uint256 internal samKey;
    address internal sessionKey;
    uint256 internal sessionPk;
    address internal relayer = makeAddr("relayer");

    function setUp() public override {
        super.setUp();
        (sam, samKey) = makeAddrAndKey("sam");
        (sessionKey, sessionPk) = makeAddrAndKey("sessionKey");
        _fund(sam, STAKE); // chips approved to the router
        _grant(clock + 1 days, CAP);
    }

    // ------------------------------------------------------------------------------------- helpers

    function _grant(uint64 expiry, uint256 maxPerOrder) internal {
        IFallpitRouter.SessionGrant memory g = IFallpitRouter.SessionGrant({
            user: sam,
            key: sessionKey,
            expiry: expiry,
            maxPerOrder: maxPerOrder,
            maxTotal: 0,
            scope: 3,
            nonce: router.sessionNonce(sam)
        });
        router.grantSession(g, _sig(samKey, router.grantDigest(g)));
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _op(uint8 kind, uint256 amount, uint256 nonce)
        internal
        view
        returns (IFallpitRouter.VaultOp memory)
    {
        return IFallpitRouter.VaultOp({
            user: sam, op: kind, house: house, amount: amount, minOut: 0, deadline: clock + 60, nonce: nonce
        });
    }

    function _relay(IFallpitRouter.VaultOp memory o) internal returns (uint256 result) {
        bytes memory sig = _sig(sessionPk, router.vaultOpDigest(o));
        vm.prank(relayer);
        result = router.vaultWithSig(o, sessionKey, sig);
    }

    function _relayReverts(IFallpitRouter.VaultOp memory o, bytes memory sig, bytes4 err) internal {
        vm.prank(relayer);
        vm.expectRevert(err);
        router.vaultWithSig(o, sessionKey, sig);
    }

    function _shares(address who) internal view returns (uint256) {
        return vault.balanceOf(who, uint256(house));
    }

    /// @dev Nothing ever stays with the router or reaches the relayer or the key.
    function _assertNothingElsewhere() internal view {
        assertEq(chip.balanceOf(address(router)), router.escrowed(address(chip)), "router holds only escrow");
        assertEq(chip.balanceOf(relayer), 0, "relayer gets no chips");
        assertEq(chip.balanceOf(sessionKey), 0, "key gets no chips");
        assertEq(_shares(relayer), 0, "relayer gets no shares");
        assertEq(_shares(sessionKey), 0, "key gets no shares");
        assertEq(_shares(address(router)), 0, "router gets no shares");
        assertEq(chip.allowance(address(router), address(vault)), 0, "no allowance left behind");
        _assertVaultBacked(address(chip));
    }

    // ------------------------------------------------------------------------------------- type string

    function test_vaultOp_digest_matchesTheTypeString() public view {
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
        IFallpitRouter.VaultOp memory o = IFallpitRouter.VaultOp(sam, 2, bytes32("h"), 10, 15, 20, 30);
        bytes32 h = keccak256(
            abi.encode(
                keccak256(
                    "VaultOp(address user,uint8 op,bytes32 house,uint256 amount,uint256 minOut,uint64 deadline,uint256 nonce)"
                ),
                o.user,
                o.op,
                o.house,
                o.amount,
                o.minOut,
                o.deadline,
                o.nonce
            )
        );
        assertEq(router.vaultOpDigest(o), keccak256(abi.encodePacked(hex"1901", domain, h)));
        assertEq(vault.router(), address(router), "the vault trusts the router the hook pins");
    }

    // ------------------------------------------------------------------------------------- each op

    function test_vaultSession_deposit_unlocked_sharesToTheUser() public {
        uint256 expected = vault.convertToShares(house, 10_000e18);
        uint256 shares = _relay(_op(router.VAULT_DEPOSIT(), 10_000e18, 1));
        assertEq(shares, expected);
        assertEq(_shares(sam), shares, "shares are the user's");
        assertEq(chip.balanceOf(sam), STAKE - 10_000e18, "chips from the user's approval to the router");
        assertTrue(router.orderNonceUsed(sam, 1));
        _assertNothingElsewhere();
    }

    function test_vaultSession_withdraw_unlocked_paysTheUser() public {
        uint256 shares = _relay(_op(router.VAULT_DEPOSIT(), 10_000e18, 1));
        uint256 assets = _relay(_op(router.VAULT_REQUEST_WITHDRAW(), shares, 2));
        assertApproxEqAbs(assets, 10_000e18, 1);
        assertEq(_shares(sam), 0);
        assertEq(chip.balanceOf(sam), STAKE - 10_000e18 + assets, "the chips go to the user");
        _assertNothingElsewhere();
    }

    function test_vaultSession_depositQueued_cancel_paysTheUser() public {
        _open(); // the house is locked: deposits queue
        assertTrue(vault.isLocked(house));
        uint256 shares = _relay(_op(router.VAULT_DEPOSIT(), 10_000e18, 1));
        assertEq(shares, 0, "queued");
        (, uint256 queued,,) = vault.positionOf(house, sam);
        assertEq(queued, 10_000e18);

        uint256 back = _relay(_op(router.VAULT_CANCEL_DEPOSIT(), 0, 2));
        assertEq(back, 10_000e18);
        assertEq(chip.balanceOf(sam), STAKE, "the queued chips come back to the user");
        (, queued,,) = vault.positionOf(house, sam);
        assertEq(queued, 0);
        _assertNothingElsewhere();
    }

    function test_vaultSession_withdrawQueued_claim_paysTheUser() public {
        uint256 shares = _relay(_op(router.VAULT_DEPOSIT(), 10_000e18, 1));
        _open();
        assertEq(_relay(_op(router.VAULT_REQUEST_WITHDRAW(), shares, 2)), 0, "queued");
        (,, uint256 queuedShares,) = vault.positionOf(house, sam);
        assertEq(queuedShares, shares);

        // nothing to claim before the round returns
        IFallpitRouter.VaultOp memory c = _op(router.VAULT_CLAIM(), 0, 3);
        _relayReverts(c, _sig(sessionPk, router.vaultOpDigest(c)), PitVault.NothingToClaim.selector);

        _closeAndFinalize(S0);
        assertFalse(vault.isLocked(house));
        c = _op(router.VAULT_CLAIM(), 0, 4);
        c.deadline = clock + 60;
        uint256 paid = _relay(c);
        assertGt(paid, 0);
        assertEq(chip.balanceOf(sam), STAKE - 10_000e18 + paid, "the claim goes to the user");
        _assertNothingElsewhere();
    }

    // ------------------------------------------------------------------------------------- refusals

    function test_vaultSession_wrongKey_noSession_badOp() public {
        IFallpitRouter.VaultOp memory o = _op(router.VAULT_DEPOSIT(), 1_000e18, 1);
        (address otherKey, uint256 otherPk) = makeAddrAndKey("other");
        // signed by another key for the granted key
        _relayReverts(o, _sig(otherPk, router.vaultOpDigest(o)), IFallpitRouter.BadSignature.selector);
        // signed and named by a key that has no session
        bytes memory sig = _sig(otherPk, router.vaultOpDigest(o));
        vm.prank(relayer);
        vm.expectRevert(IFallpitRouter.NoSession.selector);
        router.vaultWithSig(o, otherKey, sig);
        // signed for another user
        o.user = relayer;
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.NoSession.selector);
        // an op that does not exist
        o = _op(4, 0, 1);
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.BadVaultOp.selector);
        // a house that does not exist
        o = _op(router.VAULT_DEPOSIT(), 1_000e18, 1);
        o.house = bytes32("nohouse");
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.UnknownHouse.selector);
        assertEq(chip.balanceOf(sam), STAKE);
    }

    function test_vaultSession_expiredRevokedBumped() public {
        IFallpitRouter.VaultOp memory o = _op(router.VAULT_DEPOSIT(), 1_000e18, 1);
        _warp(clock + 1 days + 1);
        o.deadline = clock + 60;
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.NoSession.selector);

        _grant(clock + 2 days, CAP);
        vm.prank(sam);
        router.revokeSession(sessionKey);
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.NoSession.selector);

        _grant(clock + 1 days, CAP);
        vm.prank(sam);
        router.bumpSessionNonce();
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.NoSession.selector);
    }

    function test_vaultSession_replay_deadline_cap() public {
        IFallpitRouter.VaultOp memory o = _op(router.VAULT_DEPOSIT(), 1_000e18, 7);
        bytes memory sig = _sig(sessionPk, router.vaultOpDigest(o));
        uint256 first = _relay(o);
        _relayReverts(o, sig, IFallpitRouter.OrderUsed.selector);
        // a nonce used by a vault action cannot be used again by any other action
        o.op = router.VAULT_REQUEST_WITHDRAW();
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.OrderUsed.selector);

        o = _op(router.VAULT_DEPOSIT(), 1_000e18, 8);
        o.deadline = clock - 1;
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.OrderExpired.selector);

        o = _op(router.VAULT_DEPOSIT(), CAP + 1, 8);
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.OverSessionCap.selector);
        // the cap is on deposits: a withdrawal of more shares than the cap's chips is fine
        uint256 shares = _relay(_op(router.VAULT_DEPOSIT(), CAP, 8));
        assertGt(shares, CAP);
        _relay(_op(router.VAULT_REQUEST_WITHDRAW(), shares, 9));
        assertEq(_shares(sam), first);
        _assertNothingElsewhere();
    }

    /// @dev Orders and vault actions share one nonce bitmap.
    function test_vaultSession_nonceSharedWithOrders() public {
        _open();
        IFallpitRouter.Order memory order = IFallpitRouter.Order({
            user: sam,
            roundId: roundId,
            product: HIGHER,
            isBuy: true,
            shares: 1_000e18,
            limit: 1_000e18,
            deadline: clock + 60,
            nonce: 11
        });
        bytes memory osig = _sig(sessionPk, router.orderDigest(order));
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        router.commitWithSig{value: _fillFee()}(order, sessionKey, osig);
        IFallpitRouter.VaultOp memory o = _op(router.VAULT_DEPOSIT(), 1_000e18, 11);
        _relayReverts(o, _sig(sessionPk, router.vaultOpDigest(o)), IFallpitRouter.OrderUsed.selector);
    }

    function test_vaultSession_noApproval_reverts() public {
        vm.prank(sam);
        chip.approve(address(router), 0);
        IFallpitRouter.VaultOp memory o = _op(router.VAULT_DEPOSIT(), 1_000e18, 1);
        bytes memory sig = _sig(sessionPk, router.vaultOpDigest(o));
        vm.prank(relayer);
        vm.expectRevert();
        router.vaultWithSig(o, sessionKey, sig);
        assertFalse(router.orderNonceUsed(sam, 1), "the failed action used no nonce");
    }

    // ------------------------------------------------------------------------------------- limits

    function _relayRevertsWith(IFallpitRouter.VaultOp memory o, bytes memory err) internal {
        bytes memory sig = _sig(sessionPk, router.vaultOpDigest(o));
        vm.prank(relayer);
        vm.expectRevert(err);
        router.vaultWithSig(o, sessionKey, sig);
    }

    /// @notice A withdrawal with `minOut` runs only when it pays that much now.
    function test_vaultSession_withdraw_minOut_onlyIfUnlockedAndEnough() public {
        uint256 shares = _relay(_op(router.VAULT_DEPOSIT(), 10_000e18, 1));
        uint256 worth = vault.convertToAssets(house, shares);

        // asks more than the shares pay now: refused
        IFallpitRouter.VaultOp memory o = _op(router.VAULT_REQUEST_WITHDRAW(), shares, 2);
        o.minOut = worth + 1;
        _relayRevertsWith(o, abi.encodeWithSelector(IFallpitRouter.MinOutNotMet.selector, worth, worth + 1));

        // the house locks: a withdrawal with minOut would queue, so it is refused
        _open();
        o = _op(router.VAULT_REQUEST_WITHDRAW(), shares, 3);
        o.minOut = 1;
        _relayRevertsWith(o, abi.encodeWithSelector(IFallpitRouter.MinOutNotMet.selector, 0, 1));
        assertEq(_shares(sam), shares, "the shares stay with the user");
        // minOut 0 still queues
        assertEq(_relay(_op(router.VAULT_REQUEST_WITHDRAW(), shares / 2, 4)), 0, "queued");

        // claim with minOut
        _closeAndFinalize(S0);
        vault.processQueues(house); // books the queued withdrawal, so positionOf shows it
        (,,, uint256 claimable) = vault.positionOf(house, sam);
        assertGt(claimable, 0);
        IFallpitRouter.VaultOp memory c = _op(router.VAULT_CLAIM(), 0, 5);
        c.minOut = claimable + 1;
        _relayRevertsWith(
            c, abi.encodeWithSelector(IFallpitRouter.MinOutNotMet.selector, claimable, claimable + 1)
        );
        c = _op(router.VAULT_CLAIM(), 0, 6);
        c.minOut = claimable;
        assertEq(_relay(c), claimable);

        // an unlocked withdrawal with minOut that is met
        uint256 rest = _shares(sam);
        o = _op(router.VAULT_REQUEST_WITHDRAW(), rest, 7);
        o.minOut = vault.convertToAssets(house, rest);
        assertEq(_relay(o), o.minOut);
        _assertNothingElsewhere();
    }

    /// @notice Deposits count in the session's `maxTotal` (per chip); withdrawals do not.
    function test_vaultSession_deposits_countInMaxTotal() public {
        IFallpitRouter.SessionGrant memory g = IFallpitRouter.SessionGrant({
            user: sam,
            key: sessionKey,
            expiry: clock + 2 days,
            maxPerOrder: CAP,
            maxTotal: 15_000e18,
            scope: router.SCOPE_VAULT(),
            nonce: router.sessionNonce(sam)
        });
        router.grantSession(g, _sig(samKey, router.grantDigest(g)));
        assertEq(router.sessionSpent(sam, sessionKey, address(chip)), 0, "a new grant starts at zero");

        uint256 shares = _relay(_op(router.VAULT_DEPOSIT(), 10_000e18, 1));
        assertEq(router.sessionSpent(sam, sessionKey, address(chip)), 10_000e18);
        _relayRevertsWith(
            _op(router.VAULT_DEPOSIT(), 5_000e18 + 1, 2),
            abi.encodeWithSelector(IFallpitRouter.OverSessionTotal.selector, 15_000e18 + 1, 15_000e18)
        );
        _relay(_op(router.VAULT_REQUEST_WITHDRAW(), shares, 3));
        _relay(_op(router.VAULT_DEPOSIT(), 5_000e18, 4));
        assertEq(router.sessionSpent(sam, sessionKey, address(chip)), 15_000e18);
        _relayRevertsWith(
            _op(router.VAULT_DEPOSIT(), 1, 5),
            abi.encodeWithSelector(IFallpitRouter.OverSessionTotal.selector, 15_000e18 + 1, 15_000e18)
        );
        _assertNothingElsewhere();
    }

    // ------------------------------------------------------------------------------------- vault access

    function test_vaultFor_strangerRefused_routerAndOperatorAllowed() public {
        address mallory = makeAddr("mallory");
        vm.startPrank(mallory);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.claimFor(house, sam);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.requestWithdrawFor(house, 1, sam);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.cancelDepositFor(house, sam);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.depositFor(house, 1, sam);
        vm.stopPrank();

        vm.expectRevert(PitVault.InvalidReceiver.selector);
        vault.depositFor(house, 1, address(0));
        vm.prank(address(router));
        vm.expectRevert(PitVault.InvalidReceiver.selector);
        vault.depositFor(house, 1, address(vault));
    }

    function test_vaultFor_operator_paysTheOwnerNeverTheOperator() public {
        address op = makeAddr("operator");
        chip.mint(op, 20_000e18);
        vm.prank(op);
        chip.approve(address(vault), type(uint256).max);
        vm.prank(sam);
        vault.setOperator(op, true);

        // the operator's chips, the owner's shares
        vm.prank(op);
        uint256 shares = vault.depositFor(house, 20_000e18, sam);
        assertEq(_shares(sam), shares);
        assertEq(_shares(op), 0);
        assertEq(chip.balanceOf(op), 0);

        // an immediate withdrawal pays the owner
        vm.prank(op);
        uint256 assets = vault.requestWithdrawFor(house, shares / 2, sam);
        assertEq(chip.balanceOf(sam), STAKE + assets);
        assertEq(chip.balanceOf(op), 0);

        // a queued withdrawal and its claim pay the owner
        _open();
        uint256 rest = _shares(sam);
        vm.prank(op);
        vault.requestWithdrawFor(house, rest, sam);
        _closeAndFinalize(S0);
        vm.prank(op);
        uint256 paid = vault.claimFor(house, sam);
        assertEq(chip.balanceOf(sam), STAKE + assets + paid);
        assertEq(chip.balanceOf(op), 0);

        // operator approval revoked: refused again
        vm.prank(sam);
        vault.setOperator(op, false);
        vm.prank(op);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.claimFor(house, sam);
        _assertVaultBacked(address(chip));
    }

    function test_vaultFor_ownerItself() public {
        vm.startPrank(sam);
        chip.approve(address(vault), 1_000e18);
        uint256 shares = vault.depositFor(house, 1_000e18, sam);
        vault.requestWithdrawFor(house, shares, sam);
        vm.stopPrank();
        assertApproxEqAbs(chip.balanceOf(sam), STAKE, 1);
    }
}
