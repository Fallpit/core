// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {IAnchorSource} from "../../src/interfaces/IAnchorSource.sol";
import {AnchorRegistry} from "../../src/listing/AnchorRegistry.sol";
import {LaunchRecordSource} from "../../src/listing/LaunchRecordSource.sol";

/// @notice A launchpad whose record of each coin is set by the test, and which can misbehave.
contract MockLaunchpad {
    enum Mode {
        Normal,
        Revert,
        BurnGas,
        ReturnBomb
    }

    mapping(address coin => uint256[]) internal _rec;
    Mode public mode;

    function setRecord(address coin, uint256[] memory rec) external {
        _rec[coin] = rec;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    /// @dev Any selector lands here: the record of the coin in the first argument, as raw words.
    fallback(bytes calldata data) external returns (bytes memory) {
        Mode m = mode;
        if (m == Mode.Revert) revert("nope");
        if (m == Mode.BurnGas) {
            while (true) {}
        }
        if (m == Mode.ReturnBomb) {
            assembly {
                return(0, 0x100000)
            }
        }
        address coin = abi.decode(data[4:], (address));
        uint256[] memory rec = _rec[coin];
        bytes memory out = new bytes(rec.length * 32);
        for (uint256 i; i < rec.length; ++i) {
            uint256 w = rec[i];
            assembly {
                mstore(add(add(out, 0x20), mul(i, 0x20)), w)
            }
        }
        return out;
    }
}

contract AnchorRegistryTest is Test {
    bytes4 internal constant GET_ASSET_DATA = bytes4(keccak256("getAssetData(address)"));
    bytes4 internal constant GET_LAUNCHED_TOKEN = 0x3cf28b5a;
    bytes32 internal constant ETH = "ETH";
    bytes32 internal constant NVDA = "NVDA";

    address internal owner = makeAddr("owner");
    address internal weth = makeAddr("weth");
    address internal nvdaToken = makeAddr("nvdaToken");
    address internal tslaToken = makeAddr("tslaToken");
    address internal coinA = makeAddr("coinA");
    address internal coinB = makeAddr("coinB");
    address internal coinC = makeAddr("coinC");

    MockLaunchpad internal airlock; // Doppler shape: word 0 anchor, word 4 not zero
    MockLaunchpad internal ponsV2; // word 0 self, word 4 anchor
    MockLaunchpad internal ponsV1; // word 0 self, word 2 anchor
    LaunchRecordSource internal doppler;
    LaunchRecordSource internal v2;
    LaunchRecordSource internal v1;
    AnchorRegistry internal reg;

    function setUp() public {
        airlock = new MockLaunchpad();
        ponsV2 = new MockLaunchpad();
        ponsV1 = new MockLaunchpad();
        doppler = new LaunchRecordSource(
            address(airlock), GET_ASSET_DATA, 4, LaunchRecordSource.KnownBy.NonZero, 0
        );
        v2 = new LaunchRecordSource(
            address(ponsV2), GET_LAUNCHED_TOKEN, 0, LaunchRecordSource.KnownBy.Self, 4
        );
        v1 = new LaunchRecordSource(
            address(ponsV1), GET_LAUNCHED_TOKEN, 0, LaunchRecordSource.KnownBy.Self, 2
        );

        reg = new AnchorRegistry(owner);
        vm.startPrank(owner);
        reg.addSource(doppler);
        reg.addSource(v2);
        reg.addSource(v1);
        reg.nameTicker(address(0), ETH);
        reg.nameTicker(weth, ETH);
        reg.nameTicker(nvdaToken, NVDA);
        vm.stopPrank();
    }

    function _words(uint256 n) internal pure returns (uint256[] memory w) {
        w = new uint256[](n);
    }

    function _doppler(address coin, address anchor) internal {
        uint256[] memory w = _words(10);
        w[0] = uint160(anchor);
        w[1] = 0xdead;
        w[4] = uint160(address(0x1717));
        airlock.setRecord(coin, w);
    }

    function _ponsV2(address coin, address anchor) internal {
        uint256[] memory w = _words(15);
        w[0] = uint160(coin);
        w[1] = 0xC0;
        w[4] = uint160(anchor);
        ponsV2.setRecord(coin, w);
    }

    function _ponsV1(address coin, address anchor) internal {
        uint256[] memory w = _words(15);
        w[0] = uint160(coin);
        w[2] = uint160(anchor);
        ponsV1.setRecord(coin, w);
    }

    // ------------------------------------------------------------------------------------------ source

    function test_source_eachShape_readsTheAnchor() public {
        _doppler(coinA, nvdaToken);
        _ponsV2(coinB, address(0));
        _ponsV1(coinC, weth);
        (bool k, address a) = doppler.anchorOf(coinA);
        assertTrue(k);
        assertEq(a, nvdaToken);
        (k, a) = v2.anchorOf(coinB);
        assertTrue(k);
        assertEq(a, address(0), "native ETH");
        (k, a) = v1.anchorOf(coinC);
        assertTrue(k);
        assertEq(a, weth);
    }

    function test_source_unknownCoin_isNotKnown() public view {
        (bool k, address a) = doppler.anchorOf(coinA);
        assertFalse(k);
        assertEq(a, address(0));
        (k,) = v2.anchorOf(coinA);
        assertFalse(k);
    }

    /// @dev A record that names another coin in its "self" word does not prove this coin's launch.
    function test_source_selfWordOfAnotherCoin_isNotKnown() public {
        uint256[] memory w = _words(15);
        w[0] = uint160(coinB);
        w[4] = uint160(nvdaToken);
        ponsV2.setRecord(coinA, w);
        (bool k,) = v2.anchorOf(coinA);
        assertFalse(k);
    }

    function test_source_shortRecord_isNotKnown() public {
        uint256[] memory w = _words(4); // the anchor is word 4: one word short
        w[0] = uint160(coinA);
        ponsV2.setRecord(coinA, w);
        (bool k,) = v2.anchorOf(coinA);
        assertFalse(k);
    }

    function test_source_anchorWordNotAnAddress_isNotKnown() public {
        uint256[] memory w = _words(15);
        w[0] = uint160(coinA);
        w[4] = uint256(1) << 160;
        ponsV2.setRecord(coinA, w);
        (bool k, address a) = v2.anchorOf(coinA);
        assertFalse(k);
        assertEq(a, address(0));
    }

    function test_source_misbehavingLaunchpad_isNotKnown() public {
        _ponsV2(coinA, nvdaToken);
        ponsV2.setMode(MockLaunchpad.Mode.Revert);
        (bool k,) = v2.anchorOf(coinA);
        assertFalse(k);
        ponsV2.setMode(MockLaunchpad.Mode.BurnGas);
        (k,) = v2.anchorOf(coinA);
        assertFalse(k);
        // A huge return is not copied: only the words the source needs.
        ponsV2.setMode(MockLaunchpad.Mode.ReturnBomb);
        uint256 g = gasleft();
        (k,) = v2.anchorOf(coinA);
        assertFalse(k, "a zero record does not name the coin");
        assertLt(g - gasleft(), 1_000_000);
    }

    function test_source_tooLittleGas_reverts() public {
        _ponsV2(coinA, nvdaToken);
        vm.expectRevert(LaunchRecordSource.InsufficientGas.selector);
        v2.anchorOf{gas: 150_000}(coinA);
    }

    function test_source_zeroTarget_reverts() public {
        vm.expectRevert(LaunchRecordSource.ZeroAddress.selector);
        new LaunchRecordSource(address(0), GET_LAUNCHED_TOKEN, 0, LaunchRecordSource.KnownBy.Self, 4);
    }

    // ---------------------------------------------------------------------------------------- registry

    function test_resolve_namesTheTicker() public {
        _doppler(coinA, nvdaToken);
        _ponsV1(coinB, weth);
        _ponsV2(coinC, address(0));
        (bytes32 t, address a, address s) = reg.resolve(coinA);
        assertEq(t, NVDA);
        assertEq(a, nvdaToken);
        assertEq(s, address(doppler));
        (t,, s) = reg.resolve(coinB);
        assertEq(t, ETH);
        assertEq(s, address(v1));
        (t, a, s) = reg.resolve(coinC);
        assertEq(t, ETH);
        assertEq(a, address(0));
        assertEq(s, address(v2));
    }

    function test_resolve_unknownLaunch_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AnchorRegistry.UnknownLaunch.selector, coinA));
        reg.resolve(coinA);
        (AnchorRegistry.Status st, bytes32 t, address a, address s) = reg.inspect(coinA);
        assertEq(uint8(st), uint8(AnchorRegistry.Status.UnknownLaunch));
        assertEq(t, bytes32(0));
        assertEq(a, address(0));
        assertEq(s, address(0));
    }

    function test_resolve_anchorWithoutTicker_reverts() public {
        _ponsV2(coinA, tslaToken);
        vm.expectRevert(abi.encodeWithSelector(AnchorRegistry.AnchorNotListed.selector, coinA, tslaToken));
        reg.resolve(coinA);
        (AnchorRegistry.Status st,, address a, address s) = reg.inspect(coinA);
        assertEq(uint8(st), uint8(AnchorRegistry.Status.AnchorNotListed));
        assertEq(a, tslaToken);
        assertEq(s, address(v2));
    }

    /// @dev The first source that knows the coin decides, even when its anchor has no ticker and a later
    ///      source would name one: a coin has one launch record, and a second "record" is not trusted more.
    function test_inspect_firstKnownSourceDecides() public {
        _doppler(coinA, tslaToken);
        _ponsV2(coinA, nvdaToken);
        (AnchorRegistry.Status st,, address a, address s) = reg.inspect(coinA);
        assertEq(uint8(st), uint8(AnchorRegistry.Status.AnchorNotListed));
        assertEq(a, tslaToken);
        assertEq(s, address(doppler));
    }

    function test_manual_beatsSources_andClears() public {
        _ponsV2(coinA, nvdaToken);
        vm.prank(owner);
        reg.setManual(coinA, true, weth);
        (bytes32 t, address a, address s) = reg.resolve(coinA);
        assertEq(t, ETH);
        assertEq(a, weth);
        assertEq(s, address(reg));
        vm.prank(owner);
        reg.setManual(coinA, false, weth);
        (t,, s) = reg.resolve(coinA);
        assertEq(t, NVDA);
        assertEq(s, address(v2));
        (bool set, address anchor) = reg.manualOf(coinA);
        assertFalse(set);
        assertEq(anchor, address(0));
    }

    function test_manual_forUnknownCoin_withNativeEth() public {
        vm.prank(owner);
        reg.setManual(coinA, true, address(0));
        (bytes32 t, address a, address s) = reg.resolve(coinA);
        assertEq(t, ETH);
        assertEq(a, address(0));
        assertEq(s, address(reg));
    }

    function test_nameTicker_zeroRemoves() public {
        _doppler(coinA, nvdaToken);
        vm.prank(owner);
        reg.nameTicker(nvdaToken, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(AnchorRegistry.AnchorNotListed.selector, coinA, nvdaToken));
        reg.resolve(coinA);
    }

    function test_sources_addRemoveKeepsOrder() public {
        IAnchorSource[] memory s = reg.sources();
        assertEq(s.length, 3);
        vm.prank(owner);
        reg.removeSource(doppler);
        s = reg.sources();
        assertEq(s.length, 2);
        assertEq(address(s[0]), address(v2));
        assertEq(address(s[1]), address(v1));
        vm.startPrank(owner);
        vm.expectRevert(AnchorRegistry.NoSuchSource.selector);
        reg.removeSource(doppler);
        vm.expectRevert(AnchorRegistry.SourceExists.selector);
        reg.addSource(v1);
        vm.expectRevert(AnchorRegistry.ZeroAddress.selector);
        reg.addSource(IAnchorSource(address(0)));
        reg.addSource(doppler);
        vm.stopPrank();
        s = reg.sources();
        assertEq(address(s[2]), address(doppler), "added again at the end");
        _doppler(coinA, nvdaToken);
        (,, address src) = reg.resolve(coinA);
        assertEq(src, address(doppler));
    }

    function test_sources_atMostEight() public {
        vm.startPrank(owner);
        for (uint256 i; i < 5; ++i) {
            reg.addSource(
                new LaunchRecordSource(
                    address(airlock), GET_ASSET_DATA, 4, LaunchRecordSource.KnownBy.NonZero, 0
                )
            );
        }
        IAnchorSource extra = new LaunchRecordSource(
            address(airlock), GET_ASSET_DATA, 4, LaunchRecordSource.KnownBy.NonZero, 0
        );
        vm.expectRevert(AnchorRegistry.TooManySources.selector);
        reg.addSource(extra);
        vm.stopPrank();
    }

    function test_onlyOwner() public {
        address eve = makeAddr("eve");
        vm.startPrank(eve);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.nameTicker(tslaToken, "TSLA");
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.setManual(coinA, true, nvdaToken);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.addSource(doppler);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.removeSource(doppler);
        vm.stopPrank();
    }

    function test_constructorAndManual_zeroAddress_revert() public {
        vm.expectRevert(AnchorRegistry.ZeroAddress.selector);
        new AnchorRegistry(address(0));
        vm.prank(owner);
        vm.expectRevert(AnchorRegistry.ZeroAddress.selector);
        reg.setManual(address(0), true, weth);
    }

    /// @dev A misbehaving launchpad never blocks the sources after it.
    function test_inspect_misbehavingSource_doesNotBlockTheNext() public {
        _ponsV1(coinA, weth);
        airlock.setMode(MockLaunchpad.Mode.BurnGas);
        (bytes32 t,, address s) = reg.resolve(coinA);
        assertEq(t, ETH);
        assertEq(s, address(v1));
    }

    /// @dev A coin no source knows is never named, whatever its address.
    function testFuzz_unknownCoin_neverNamed(address coin) public view {
        (AnchorRegistry.Status st, bytes32 t,,) = reg.inspect(coin);
        assertEq(uint8(st), uint8(AnchorRegistry.Status.UnknownLaunch));
        assertEq(t, bytes32(0));
    }
}
