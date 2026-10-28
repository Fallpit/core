// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AttackBase} from "./AttackBase.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {IPyth} from "../../src/oracle/IPyth.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {MockPyth} from "../oracle/mocks/MockPyth.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice Attacks on the price a fill uses, against the real PitOracle behind the real hook: which print
///         fills a commit, prints for another ticker or instant, replays, and keeper prints outside the
///         Chainlink bound. Both oracle paths.
contract AttacksOracleTest is AttackBase {
    // --------------------------------------------------------------------------------------------
    // commit and fill timing: only the unique print at commit time + fill delay fills
    // --------------------------------------------------------------------------------------------

    function test_attack_timing_keeperPath_onlyTheUniquePrintFills() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        assertEq(t, clock + 2, "priced at the commit time plus the fill delay");

        // before t nothing fills, whatever the report
        bytes memory early = _keeperPrint(NVDA, S0, clock);
        vm.expectRevert(IFallpitRouter.TooEarly.selector);
        eve.fill(id, early);

        // The keeper's tape, one genuine 2-of-3 print per second: a cheaper print just before t, the print
        // for t, then the price drops 4% and later runs up 2%. Eve waits and looks at all of it.
        _warp(t + 10);
        bytes[] memory reports = new bytes[](5);
        reports[0] = _keeperPrint(NVDA, S0 * 97 / 100, t - 1);
        reports[2] = _keeperPrint(NVDA, S0, t);
        reports[1] = _keeperPrint(NVDA, S0 * 96 / 100, t + 3);
        reports[3] = _keeperPrint(NVDA, S0 * 102 / 100, t + 9);
        // and one she forges herself: the cheap price stamped as the print for t, signed by one real
        // signer and one stranger
        reports[4] = _forgedPrint(S0 * 96 / 100, t);

        (uint256 fair,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, S0, t);
        (uint256 cheap,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, S0 * 96 / 100, t + 3);
        assertLt(cheap, fair * 80 / 100, "the later print would have been far cheaper for her");

        // each wrong print is refused by the oracle itself, and the commit stays pending
        assertEq(_fillReverts(id, reports[0]), PitOracle.NotThePrintForT.selector);
        assertEq(_fillReverts(id, reports[1]), PitOracle.NotThePrintForT.selector);
        assertEq(_fillReverts(id, reports[3]), PitOracle.NotThePrintForT.selector);
        assertEq(_fillReverts(id, reports[4]), PitOracle.NotASigner.selector);

        // trying them all in her preferred order (cheapest first), only the print for t goes through
        uint256 used = eve.fillWithAny(id, reports);
        assertEq(used, 2, "only the unique print at commit time plus fill delay fills");
        assertEq(EVE_CHIPS - chip.balanceOf(address(eve)), fair, "she pays the price at t");
    }

    function _forgedPrint(uint256 price, uint64 ts) internal returns (bytes memory) {
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        PitOracle.Print memory p = PitOracle.Print({ticker: NVDA, price: price, ts: ts, prevTs: ts - 1});
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(oracle, keys[0], p);
        sigs[1] = _sign(oracle, strangerKey, p);
        // put the two in ascending signer order so the forgery fails for the stranger, not the order
        if (vm.addr(strangerKey) < signerAddrs[0]) (sigs[0], sigs[1]) = (sigs[1], sigs[0]);
        return _report(p, sigs);
    }

    function test_attack_timing_pythPath_onlyTheUniqueUpdateFills() public {
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t + 10);

        bytes[] memory reports = new bytes[](6);
        // the update before t, a later and cheaper one, a much later one
        reports[0] = _pythUpdate(TSLA_ID, TSLA_S0 * 97 / 100, t - 1, t - 2);
        reports[1] = _pythUpdate(TSLA_ID, TSLA_S0 * 96 / 100, t + 3, t + 2);
        reports[2] = _pythUpdate(TSLA_ID, TSLA_S0 * 96 / 100, t + 40, t - 1); // beyond maxLag
        // a second update inside second t (its predecessor was also published at t): not the first
        reports[3] = _pythUpdate(TSLA_ID, TSLA_S0 * 96 / 100, t, t);
        // the right instant, the wrong feed
        reports[4] = _pythUpdate(NVDA_ID, TSLA_S0 * 96 / 100, t, t - 1);
        // the one update for t
        reports[5] = _pythPrint(TSLA, TSLA_S0, t);

        for (uint256 i; i < 5; ++i) {
            assertEq(_fillReverts(id, reports[i]), IPyth.PriceFeedNotFoundWithinRange.selector);
        }
        (uint256 fair,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, TSLA_S0, t);
        assertEq(eve.fillWithAny(id, reports), 5);
        assertEq(EVE_CHIPS - chip.balanceOf(address(eve)), fair);
    }

    function test_attack_timing_cannotCancelAfterSeeingThePrice() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t + 6);
        bytes memory theOne = _keeperPrint(NVDA, S0, t);
        _keeperPrint(NVDA, S0 * 98 / 100, t + 5); // the price drops right after: eve regrets

        // she cannot take the commit back, and cannot refund inside the fill window
        vm.expectRevert(IFallpitRouter.RefundNotDue.selector);
        eve.refund(id);
        // the keeper fills her at the price of t regardless
        vm.prank(keeper);
        assertTrue(router.fill(id, theOne));
        assertEq(_token(HIGHER).balanceOf(address(eve)), 5_000e18);
        vm.expectRevert(IFallpitRouter.CommitNotPending.selector);
        eve.refund(id);
    }

    function test_attack_timing_staleFillIsNotAnOption() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        // nobody filled for the whole window; the price is now 3% higher and eve wants the old price
        _warp(t + 31);
        bytes memory theOne = _keeperPrint(NVDA, S0, t);
        _keeperPrint(NVDA, S0 * 103 / 100, t + 31);
        vm.expectRevert(IFallpitRouter.FillWindowClosed.selector);
        eve.fill(id, theOne);
        eve.refund(id);
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS);
        assertEq(_token(HIGHER).totalSupply(), 0);

        // at the last second of the window the old print still fills: the residual look-back is the
        // window itself, 30 s, and only when no keeper filled earlier
        id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        t = router.getCommit(id).fillTs;
        _warp(t + 30);
        assertTrue(eve.fill(id, _keeperPrint(NVDA, S0 * 103 / 100, t)));
    }

    // --------------------------------------------------------------------------------------------
    // a print for the wrong ticker or the wrong instant
    // --------------------------------------------------------------------------------------------

    function test_attack_printForAnotherTicker_orAnotherInstant() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t + 25);

        // TSLA's genuine keeper print for the same instant (TSLA trades at twice NVDA's price)
        assertEq(_fillReverts(id, _keeperPrint(TSLA, TSLA_S0, t)), PitOracle.WrongTicker.selector);
        // the genuine NVDA prints one second either side
        assertEq(_fillReverts(id, _keeperPrint(NVDA, S0, t - 1)), PitOracle.NotThePrintForT.selector);
        assertEq(_fillReverts(id, _keeperPrint(NVDA, S0, t + 1)), PitOracle.NotThePrintForT.selector);
        // a signed print that would be "first after t" only if the keeper had been silent for 31 s
        assertEq(_fillReverts(id, _signedPrint(NVDA, S0, t + 31, t - 1)), PitOracle.NotThePrintForT.selector);
        // a print dated ahead of the chain's clock
        assertEq(
            _fillReverts(id, _signedPrint(NVDA, S0, clock + 5, t - 1)), PitOracle.PrintFromTheFuture.selector
        );
        // a Pyth update of the right ticker and instant: NVDA rounds take keeper prints only
        assertEq(_fillReverts(id, _pythPrint(NVDA, S0, t)), IFallpitHook.WrongFillSource.selector);
        // TSLA's Pyth update under NVDA's commit
        assertEq(_fillReverts(id, _pythPrint(TSLA, TSLA_S0, t)), IPyth.PriceFeedNotFoundWithinRange.selector);
        // junk
        assertEq(_fillReverts(id, hex"02"), PitOracle.MalformedReport.selector);
        assertEq(_fillReverts(id, hex"0300"), PitOracle.UnknownSource.selector);

        assertTrue(eve.fill(id, _keeperPrint(NVDA, S0, t)));
    }

    function test_attack_printFromTheFuture() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        // At t + 1 a colluding signer pair hands eve a print dated t + 20 with prevTs t - 1: it would be
        // "the first print after t" and lets them pick a price 19 seconds early. Refused.
        _warp(t + 1);
        assertEq(
            _fillReverts(id, _signedPrint(NVDA, S0 * 999 / 1000, t + 20, t - 1)),
            PitOracle.PrintFromTheFuture.selector
        );
    }

    // --------------------------------------------------------------------------------------------
    // replay of a keeper print
    // --------------------------------------------------------------------------------------------

    function test_attack_replay_keeperPrint() public {
        _open();
        // alice and eve commit in the same second: one print prices both, as designed
        uint256 aliceId = _commitBuy(alice, HIGHER, 5_000e18, STAKE);
        uint256 eveId = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(aliceId).fillTs;
        assertEq(router.getCommit(eveId).fillTs, t);
        bytes memory print = _printFor(aliceId, S0);
        (uint256 first,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, S0, t);
        vm.prank(keeper);
        assertTrue(router.fill(aliceId, print));
        (uint256 second,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, S0, t);
        assertTrue(eve.fill(eveId, print));
        assertEq(STAKE - chip.balanceOf(alice), first);
        assertEq(EVE_CHIPS - chip.balanceOf(address(eve)), second, "same print, same oracle price");
        assertGt(second, first, "the second fill pays for the first one's price impact");

        // a filled commit cannot be filled again with the print it was filled with
        vm.expectRevert(IFallpitRouter.CommitNotPending.selector);
        eve.fill(eveId, print);

        // the price runs up 1.5%; eve commits again and replays the old, cheaper print
        _warp(clock + 30);
        uint256 lateId = eve.commit(roundId, HIGHER, true, 5_000e18, 50_000e18);
        uint64 t2 = router.getCommit(lateId).fillTs;
        _warp(t2);
        assertEq(_fillReverts(lateId, print), PitOracle.NotThePrintForT.selector);
        // re-stamping it for t2 breaks the signatures: the recovered signers are strangers
        PitOracle.Print memory restamped = PitOracle.Print({ticker: NVDA, price: S0, ts: t2, prevTs: t2 - 1});
        (PitOracle.Print memory original, bytes[] memory sigs) = _decodePrint(print);
        assertEq(original.price, S0);
        assertEq(_fillReverts(lateId, _report(restamped, sigs)), PitOracle.NotASigner.selector);
        assertTrue(eve.fill(lateId, _keeperPrint(NVDA, S0 * 1015 / 1000, t2)));

        // Monday's close print cannot be replayed as Tuesday's close, nor fill anything today
        uint64 mondayClose = NYTime.closeTs(day0);
        bytes memory closePrint = _keeperPrint(NVDA, S0, mondayClose);
        uint256 id3 = eve.commit(roundId, LOWER, true, 1_000e18, 10_000e18);
        _warp(router.getCommit(id3).fillTs);
        assertEq(_fillReverts(id3, closePrint), PitOracle.NotThePrintForT.selector);
        _warp(NYTime.closeTs(day) + 5);
        vm.expectRevert(
            abi.encodeWithSelector(
                PitOracle.NotThePrintForT.selector, NYTime.closeTs(day), mondayClose - 1, mondayClose
            )
        );
        book.recordClose(NVDA, day, closePrint);
        vm.expectRevert(IPitBook.ReplacementRefused.selector);
        book.recordClose(NVDA, day0, closePrint);
    }

    function _decodePrint(bytes memory report)
        internal
        pure
        returns (PitOracle.Print memory p, bytes[] memory sigs)
    {
        bytes memory body = new bytes(report.length - 1);
        for (uint256 i; i < body.length; ++i) {
            body[i] = report[i + 1];
        }
        (p, sigs) = abi.decode(body, (PitOracle.Print, bytes[]));
    }

    /// @dev A print signed for another deployment of the oracle (or another chain) recovers to strangers.
    function test_attack_replay_printSignedForAnotherOracleOrChain() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        PitOracle other = new PitOracle(pyth, owner, signerAddrs, 2, 24 hours);
        PitOracle.Print memory p = PitOracle.Print({ticker: NVDA, price: S0 * 96 / 100, ts: t, prevTs: t - 1});
        assertEq(_fillReverts(id, _report2(other, p, 0, 1)), PitOracle.NotASigner.selector);

        // the genuine print stops verifying when the chain id changes (a fork of the chain)
        bytes memory genuine = _keeperPrint(NVDA, S0, t);
        // (literal chain ids: `block.chainid` read before a cheatcode is unreliable under via-IR)
        assertEq(block.chainid, 31337);
        vm.chainId(46630);
        assertEq(_fillReverts(id, genuine), PitOracle.NotASigner.selector);
        vm.chainId(31337);
        assertTrue(eve.fill(id, genuine));
    }

    // --------------------------------------------------------------------------------------------
    // a keeper print outside the Chainlink bound
    // --------------------------------------------------------------------------------------------

    function test_attack_keeperPrintOutsideTheChainlinkBound() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        // the mirror's round in force is Monday's close, 180.00. Two colluding signers sign 1% below it,
        // which would make HIGHER cheap for eve.
        (, int256 answer,,,) = feedOf[NVDA].latestRoundData();
        assertEq(uint256(answer), S0 / 1e10);
        bytes memory low = _signedPrint(NVDA, S0 * 99 / 100, t, t - 1);
        assertEq(_fillReverts(id, low), PitOracle.OutOfBound.selector);
        // 61 bps is out, on either side
        assertEq(
            _fillReverts(id, _signedPrint(NVDA, S0 * 9939 / 10_000, t, t - 1)), PitOracle.OutOfBound.selector
        );
        assertEq(
            _fillReverts(id, _signedPrint(NVDA, S0 * 10_061 / 10_000, t, t - 1)),
            PitOracle.OutOfBound.selector
        );
        // what two colluding signers can do is bounded: 60 bps from the feed, here 1.2 bands of the ladder
        (uint256 honest,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, S0, t);
        (uint256 skewed,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, S0 * 9940 / 10_000, t);
        assertTrue(eve.fill(id, _signedPrint(NVDA, S0 * 9940 / 10_000, t, t - 1)));
        assertEq(EVE_CHIPS - chip.balanceOf(address(eve)), skewed);
        emit log_named_decimal_uint("cost at the honest print", honest, 18);
        emit log_named_decimal_uint("cost at the print 60 bps low", skewed, 18);

        // the same bound holds for the close: an out-of-bound close print cannot be recorded
        uint64 closeAt = NYTime.closeTs(day);
        _warp(closeAt + 5);
        bytes memory badClose = _signedPrint(NVDA, S0 * 102 / 100, closeAt, closeAt - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, S0 * 102 / 100, S0));
        book.recordClose(NVDA, day, badClose);
    }

    /// @dev The feed lags the market: a correct print can lead the round that confirms it. A round that
    ///      lands within 60 s after the print counts, so the fill goes through once the mirror catches up,
    ///      still inside the fill window. A round that lands later does not rescue the print.
    function test_attack_bound_aPrintThatLeadsTheFeed() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        // the stock really is up 1.2% at t; the push feed has not reported it yet
        bytes memory print = _signedPrint(NVDA, S0 * 1012 / 1000, t, t - 1);
        assertEq(_fillReverts(id, print), PitOracle.OutOfBound.selector);
        // 20 s later the mainnet round lands and the keeper mirrors it
        _warp(t + 25);
        vm.prank(keeper);
        feedOf[NVDA].push(int256(S0 * 1012 / 1000 / 1e10), t + 20);
        assertTrue(eve.fill(id, print), "confirmed by the round that landed inside the grace");

        // the other way round: a print 1.2% away, with the only confirming round 61 s later. (Asked of the
        // oracle directly: the fill window of a commit is over by then.)
        uint64 t2 = clock + 2;
        _warp(t2 + 100);
        bytes memory print2 = _signedPrint(NVDA, S0 * 1024 / 1000, t2, t2 - 1);
        vm.prank(keeper);
        feedOf[NVDA].push(int256(S0 * 1024 / 1000 / 1e10), t2 + 61);
        vm.expectRevert(
            abi.encodeWithSelector(PitOracle.OutOfBound.selector, S0 * 1024 / 1000, S0 * 1012 / 1000)
        );
        oracle.verifyAt(NVDA, t2, print2);
    }

    // --------------------------------------------------------------------------------------------
    // what the keeper quorum is trusted with (stated, not prevented)
    // --------------------------------------------------------------------------------------------

    /// @dev The contracts cannot tell which of two validly signed prints for one instant is the honest one.
    ///      Two colluding signers can sign a second print for the same second (inside the Chainlink bound)
    ///      and choose which to release. This is the trust placed in the 2-of-3 keeper set for `KeeperOnly`
    ///      tickers; the bound limits it to 60 bps around the push feed.
    function test_trust_twoColludingSignersCanSignTwoPrintsForOneInstant() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, 50_000e18);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        bytes memory honest = _keeperPrint(NVDA, S0, t);
        bytes memory second = _signedPrint(NVDA, S0 * 9945 / 10_000, t, t - 1);
        (uint256 a,,) = oracle.verifyAt(NVDA, t, honest);
        (uint256 b,,) = oracle.verifyAt(NVDA, t, second);
        assertEq(a, S0);
        assertEq(b, S0 * 9945 / 10_000);
        // a TrustlessOnly round is out of their reach: TSLA fills take Pyth updates only
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        roundId = hook.openRound(TSLA, address(chip), day);
        uint256 id2 = eve.commit(roundId, HIGHER, true, 5_000e18, 50_000e18);
        uint64 t2 = router.getCommit(id2).fillTs;
        _warp(t2);
        assertEq(
            _fillReverts(id2, _keeperPrint(TSLA, TSLA_S0 * 9945 / 10_000, t2)),
            IFallpitHook.WrongFillSource.selector
        );
    }
}
