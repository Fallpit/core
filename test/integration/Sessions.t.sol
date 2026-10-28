// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";

/// @dev A smart account that accepts its owner's ECDSA signature through ERC-1271.
contract Wallet1271 {
    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        return ecrecover(hash, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function approve(address token, address spender) external {
        require(msg.sender == owner, "owner");
        MockChip(token).approve(spender, type(uint256).max);
    }
}

/// @notice Router sessions (SPEC 7.3.1): a user grants a key, the key signs orders, anyone relays them.
contract SessionsTest is IntegrationFixture {
    uint256 internal constant STAKE = 100_000e18;

    address internal sam;
    uint256 internal samKey;
    address internal sessionKey;
    uint256 internal sessionPk;
    address internal relayer = makeAddr("relayer");

    function setUp() public override {
        super.setUp();
        (sam, samKey) = makeAddrAndKey("sam");
        (sessionKey, sessionPk) = makeAddrAndKey("sessionKey");
        _fund(sam, STAKE);
        vm.deal(relayer, 1 ether);
        _open();
    }

    // ------------------------------------------------------------------------------------- helpers

    function _grant(address user, uint256 pk, uint64 expiry, uint256 maxPerOrder)
        internal
        returns (IFallpitRouter.SessionGrant memory g)
    {
        g = IFallpitRouter.SessionGrant({
            user: user,
            key: sessionKey,
            expiry: expiry,
            maxPerOrder: maxPerOrder,
            maxTotal: 0,
            scope: 3,
            nonce: router.sessionNonce(user)
        });
        router.grantSession(g, _sig(pk, router.grantDigest(g)));
    }

    function _grantSam() internal returns (IFallpitRouter.SessionGrant memory) {
        return _grant(sam, samKey, clock + 1 days, STAKE);
    }

    function _order(address user, uint8 product, bool isBuy, uint256 shares, uint256 limit, uint256 nonce)
        internal
        view
        returns (IFallpitRouter.Order memory)
    {
        return IFallpitRouter.Order({
            user: user,
            roundId: roundId,
            product: product,
            isBuy: isBuy,
            shares: shares,
            limit: limit,
            deadline: clock + 60,
            nonce: nonce
        });
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _relay(IFallpitRouter.Order memory o) internal returns (uint256 id) {
        bytes memory sig = _sig(sessionPk, router.orderDigest(o));
        uint256 fee = _fillFee();
        vm.prank(relayer);
        id = router.commitWithSig{value: fee}(o, sessionKey, sig);
    }

    function _relayReverts(IFallpitRouter.Order memory o, bytes memory sig, bytes4 err) internal {
        uint256 fee = _fillFee();
        vm.prank(relayer);
        vm.expectRevert(err);
        router.commitWithSig{value: fee}(o, sessionKey, sig);
    }

    // ------------------------------------------------------------------------------------- the type strings

    /// @dev Pins the EIP-712 encoding the app and the keeper sign.
    function test_session_digests_matchTheTypeStrings() public view {
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
        IFallpitRouter.SessionGrant memory g =
            IFallpitRouter.SessionGrant(sam, sessionKey, 123, 456, 789, 3, 7);
        bytes32 gh = keccak256(
            abi.encode(
                keccak256(
                    "SessionGrant(address user,address key,uint64 expiry,uint256 maxPerOrder,uint256 maxTotal,uint8 scope,uint256 nonce)"
                ),
                g.user,
                g.key,
                g.expiry,
                g.maxPerOrder,
                g.maxTotal,
                g.scope,
                g.nonce
            )
        );
        assertEq(router.grantDigest(g), keccak256(abi.encodePacked(hex"1901", domain, gh)));
        IFallpitRouter.Order memory o = IFallpitRouter.Order(sam, bytes32("r"), 3, true, 10, 20, 30, 40);
        bytes32 oh = keccak256(
            abi.encode(
                keccak256(
                    "Order(address user,bytes32 roundId,uint8 product,bool isBuy,uint256 shares,uint256 limit,uint64 deadline,uint256 nonce)"
                ),
                o.user,
                o.roundId,
                o.product,
                o.isBuy,
                o.shares,
                o.limit,
                o.deadline,
                o.nonce
            )
        );
        assertEq(router.orderDigest(o), keccak256(abi.encodePacked(hex"1901", domain, oh)));
    }

    // ------------------------------------------------------------------------------------- grant

    function test_session_eoaGrant_buyFromTheUsersOwnAddress() public {
        _grantSam();
        IFallpitRouter.Session memory s = router.sessionOf(sam, sessionKey);
        assertEq(s.expiry, clock + 1 days);
        assertEq(s.maxPerOrder, STAKE);
        assertEq(s.maxTotal, 0);
        assertEq(s.scope, 3);

        uint256 samChips = MockChip(roundChip).balanceOf(sam);
        uint256 samEth = sam.balance;
        uint256 relayerEth = relayer.balance;
        uint256 id = _relay(_order(sam, HIGHER, true, 1_000e18, 1_000e18, 1));
        IFallpitRouter.Commit memory c = router.getCommit(id);
        assertEq(c.user, sam, "the commit is the user's");
        assertEq(MockChip(roundChip).balanceOf(sam), samChips - 1_000e18, "escrow from the user's approval");
        assertEq(sam.balance, samEth, "the user pays no ETH");
        assertEq(relayer.balance, relayerEth - FILL_FEE, "the relayer pays the fill fee");
        assertEq(router.feePayerOf(id), relayer);
        assertTrue(router.orderNonceUsed(sam, 1));

        assertTrue(_fill(id, S0));
        assertEq(_token(HIGHER).balanceOf(sam), 1_000e18, "tokens land on the user's address");
        assertEq(_token(HIGHER).balanceOf(sessionKey), 0);
        assertEq(_token(HIGHER).balanceOf(relayer), 0);
    }

    function test_session_erc1271Grant_works() public {
        Wallet1271 w = new Wallet1271(sam);
        MockChip(roundChip).mint(address(w), STAKE);
        vm.prank(sam);
        w.approve(roundChip, address(router));
        _grant(address(w), samKey, clock + 1 days, STAKE);
        uint256 id = _relay(_order(address(w), HIGHER, true, 500e18, 500e18, 9));
        assertTrue(_fill(id, S0));
        assertEq(_token(HIGHER).balanceOf(address(w)), 500e18);
    }

    function test_session_grant_badExpiry_staleNonce_badSignature() public {
        IFallpitRouter.SessionGrant memory g =
            IFallpitRouter.SessionGrant(sam, sessionKey, clock + 7 days + 1, STAKE, 0, 3, 0);
        bytes memory sig = _sig(samKey, router.grantDigest(g));
        vm.expectRevert(IFallpitRouter.BadExpiry.selector);
        router.grantSession(g, sig);
        g.expiry = clock;
        sig = _sig(samKey, router.grantDigest(g));
        vm.expectRevert(IFallpitRouter.BadExpiry.selector);
        router.grantSession(g, sig);

        g.expiry = clock + 7 days;
        g.nonce = 1;
        sig = _sig(samKey, router.grantDigest(g));
        vm.expectRevert(IFallpitRouter.StaleNonce.selector);
        router.grantSession(g, sig);

        g.nonce = 0;
        sig = _sig(sessionPk, router.grantDigest(g)); // signed by the key itself, not the user
        vm.expectRevert(IFallpitRouter.BadSignature.selector);
        router.grantSession(g, sig);

        g.maxPerOrder = 0;
        sig = _sig(samKey, router.grantDigest(g));
        vm.expectRevert(IFallpitRouter.ZeroAmount.selector);
        router.grantSession(g, sig);

        g.maxPerOrder = STAKE;
        g.scope = 0;
        sig = _sig(samKey, router.grantDigest(g));
        vm.expectRevert(IFallpitRouter.BadScope.selector);
        router.grantSession(g, sig);
        g.scope = 4;
        sig = _sig(samKey, router.grantDigest(g));
        vm.expectRevert(IFallpitRouter.BadScope.selector);
        router.grantSession(g, sig);
    }

    function test_session_expires() public {
        _grant(sam, samKey, clock + 1 hours, STAKE);
        _warp(clock + 1 hours + 1);
        IFallpitRouter.Order memory o = _order(sam, HIGHER, true, 1_000e18, 1_000e18, 1);
        _relayReverts(o, _sig(sessionPk, router.orderDigest(o)), IFallpitRouter.NoSession.selector);
    }

    function test_session_revoke_andTheOldGrantCannotReviveIt() public {
        IFallpitRouter.SessionGrant memory g = _grantSam();
        vm.prank(sam);
        router.revokeSession(sessionKey);
        IFallpitRouter.Order memory o = _order(sam, HIGHER, true, 1_000e18, 1_000e18, 1);
        _relayReverts(o, _sig(sessionPk, router.orderDigest(o)), IFallpitRouter.NoSession.selector);
        bytes memory gsig = _sig(samKey, router.grantDigest(g));
        vm.expectRevert(IFallpitRouter.GrantUsed.selector);
        router.grantSession(g, gsig);
    }

    function test_session_nonceBump_endsEverySession() public {
        IFallpitRouter.SessionGrant memory g = _grantSam();
        vm.prank(sam);
        router.bumpSessionNonce();
        IFallpitRouter.Order memory o = _order(sam, HIGHER, true, 1_000e18, 1_000e18, 1);
        _relayReverts(o, _sig(sessionPk, router.orderDigest(o)), IFallpitRouter.NoSession.selector);
        bytes memory gsig = _sig(samKey, router.grantDigest(g));
        vm.expectRevert(IFallpitRouter.StaleNonce.selector);
        router.grantSession(g, gsig);
        // a new grant under the new nonce works
        _grantSam();
        _relay(o);
    }

    // ------------------------------------------------------------------------------------- orders

    function test_session_order_replay_deadline_wrongKey_cap() public {
        _grant(sam, samKey, clock + 1 days, 2_000e18);
        IFallpitRouter.Order memory o = _order(sam, HIGHER, true, 1_000e18, 1_000e18, 5);
        bytes memory sig = _sig(sessionPk, router.orderDigest(o));
        _relay(o);
        _relayReverts(o, sig, IFallpitRouter.OrderUsed.selector);

        o.nonce = 6;
        o.deadline = clock - 1;
        _relayReverts(o, _sig(sessionPk, router.orderDigest(o)), IFallpitRouter.OrderExpired.selector);

        o.deadline = clock + 60;
        (, uint256 otherPk) = makeAddrAndKey("other");
        _relayReverts(o, _sig(otherPk, router.orderDigest(o)), IFallpitRouter.BadSignature.selector);

        o.limit = 2_000e18 + 1;
        _relayReverts(o, _sig(sessionPk, router.orderDigest(o)), IFallpitRouter.OverSessionCap.selector);

        // a key with no session for this user
        (address stranger, uint256 strangerPk) = makeAddrAndKey("stranger");
        o.limit = 1_000e18;
        bytes memory ssig = _sig(strangerPk, router.orderDigest(o));
        uint256 fee = _fillFee();
        vm.prank(relayer);
        vm.expectRevert(IFallpitRouter.NoSession.selector);
        router.commitWithSig{value: fee}(o, stranger, ssig);
    }

    /// @dev A signature covers every field: change any one of them and it no longer verifies.
    function testFuzz_session_tamperedOrder_rejected(uint8 field, uint256 delta) public {
        _grantSam();
        delta = bound(delta, 1, 1e18);
        IFallpitRouter.Order memory o = _order(sam, HIGHER, true, 1_000e18, 1_000e18, 77);
        bytes memory sig = _sig(sessionPk, router.orderDigest(o));
        field = uint8(bound(field, 0, 6));
        if (field == 0) o.roundId = bytes32(uint256(o.roundId) ^ delta);
        else if (field == 1) o.product = HIGHER - 1;
        else if (field == 2) o.isBuy = false;
        else if (field == 3) o.shares -= delta % 500e18 + 1;
        else if (field == 4) o.limit -= delta % 500e18 + 1;
        else if (field == 5) o.deadline += uint64(delta % 30 + 1);
        else o.nonce += delta;
        uint256 fee = _fillFee();
        vm.prank(relayer);
        vm.expectRevert(IFallpitRouter.BadSignature.selector);
        router.commitWithSig{value: fee}(o, sessionKey, sig);
    }

    // ------------------------------------------------------------------------------------- sells

    function test_session_sell_pullsTheUsersTokens_withNoApproval() public {
        _grantSam();
        assertTrue(_fill(_relay(_order(sam, HIGHER, true, 1_000e18, 1_000e18, 1)), S0));
        Ticket memory t = _token(HIGHER);
        assertEq(hook.allowance(sam, address(router), t.id), 0, "no approval anywhere");

        uint256 chipsBefore = MockChip(roundChip).balanceOf(sam);
        uint256 id = _relay(_order(sam, HIGHER, false, 400e18, 0, 2));
        assertEq(t.balanceOf(sam), 600e18, "escrowed through hook.pull");
        assertTrue(_fill(id, S0));
        assertGt(MockChip(roundChip).balanceOf(sam), chipsBefore, "proceeds to the user");

        // the plain path needs no approval either (every sell escrows through hook.pull)
        uint256 fee = _fillFee();
        vm.prank(sam);
        router.commit{value: fee}(roundId, HIGHER, false, 100e18, 0);
        assertEq(t.balanceOf(sam), 500e18);
    }

    function test_session_pull_onlyTheRouter() public {
        _grantSam();
        assertTrue(_fill(_relay(_order(sam, HIGHER, true, 1_000e18, 1_000e18, 1)), S0));
        Ticket memory t = _token(HIGHER);
        address[3] memory callers = [relayer, sessionKey, address(hook)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IFallpitHook.OnlyRouter.selector);
            hook.pull(sam, t.id, 1);
        }
    }

    /// @dev The extra gas of a session commit over a plain one (signature checks, the nonce bit, the payer).
    function test_session_gas_comparedWithCommit() public {
        _grantSam();
        _fund(alice, STAKE);
        // warm the round's slots the same way for both
        _commitBuy(alice, HIGHER, 100e18, 100e18);
        _relay(_order(sam, HIGHER, true, 100e18, 100e18, 1));

        uint256 fee = _fillFee();
        vm.prank(alice);
        uint256 g0 = gasleft();
        router.commit{value: fee}(roundId, HIGHER, true, 1_000e18, 1_000e18);
        uint256 plain = g0 - gasleft();

        IFallpitRouter.Order memory o = _order(sam, HIGHER, true, 1_000e18, 1_000e18, 2);
        bytes memory sig = _sig(sessionPk, router.orderDigest(o));
        vm.prank(relayer);
        g0 = gasleft();
        router.commitWithSig{value: fee}(o, sessionKey, sig);
        uint256 bySig = g0 - gasleft();
        emit log_named_uint("commit gas", plain);
        emit log_named_uint("commitWithSig gas", bySig);
        assertLt(bySig, plain + 60_000, "a session commit costs at most 60k more");
    }

    // ------------------------------------------------------------------------------------- fees and redeem

    function test_session_unfilledCommit_feeBackToThePayer_escrowToTheUser() public {
        _grantSam();
        uint256 samChips = MockChip(roundChip).balanceOf(sam);
        uint256 id = _relay(_order(sam, HIGHER, true, 1_000e18, 1_000e18, 1));
        IFallpitRouter.Commit memory c = router.getCommit(id);
        _warp(c.fillTs + c.refundDelay + 1);
        uint256 relayerEth = relayer.balance;
        uint256 samEth = sam.balance;
        vm.prank(carol);
        router.refund(id);
        assertEq(relayer.balance, relayerEth + FILL_FEE, "the payer gets the fee back");
        assertEq(sam.balance, samEth, "not the user");
        assertEq(MockChip(roundChip).balanceOf(sam), samChips, "the escrow goes back to the user");
    }

    function test_plainCommit_unfilled_feeStillBackToTheUser() public {
        _fund(alice, STAKE);
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 1_000e18);
        IFallpitRouter.Commit memory c = router.getCommit(id);
        _warp(c.fillTs + c.refundDelay + 1);
        uint256 before = alice.balance;
        router.refund(id);
        assertEq(alice.balance, before + FILL_FEE);
        assertEq(router.feePayerOf(id), address(0));
    }

    function test_session_redeemFor_paysOnlyTheHolder() public {
        _grantSam();
        assertTrue(_fill(_relay(_order(sam, HIGHER, true, 1_000e18, 1_000e18, 1)), S0));
        _closeAndFinalize(S0 * 101 / 100);
        uint256 samChips = MockChip(roundChip).balanceOf(sam);
        uint256 carolChips = MockChip(roundChip).balanceOf(carol);
        vm.prank(carol);
        uint256 payout = router.redeemFor(sam, _token(HIGHER).id);
        assertEq(payout, 1_000e18);
        assertEq(MockChip(roundChip).balanceOf(sam), samChips + payout, "paid to the holder");
        assertEq(MockChip(roundChip).balanceOf(carol), carolChips, "the caller gets nothing");
        assertEq(_token(HIGHER).balanceOf(sam), 0);
    }
}
