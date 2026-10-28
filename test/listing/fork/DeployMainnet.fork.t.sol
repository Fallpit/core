// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployMainnet} from "../../../script/DeployMainnet.s.sol";
import {FallpitDeployer} from "../../../script/FallpitDeployer.sol";
import {AnchorRegistry} from "../../../src/listing/AnchorRegistry.sol";
import {LaunchRecordSource} from "../../../src/listing/LaunchRecordSource.sol";
import {IFallpitRouter} from "../../../src/interfaces/IFallpitRouter.sol";

/// @notice Fork test of the mainnet deploy script against Robinhood Chain 4663: every ticker takes its real
///         feed and stock token, real coins of each launchpad resolve to their stock and pass the chip guard,
///         and the deployer owns nothing at the end.
/// @dev Skipped unless FORK_RPC_4663 is set, for example
///      `FORK_RPC_4663=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/listing/fork/*"`.
contract DeployMainnetForkTest is Test {
    address internal constant AI = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18; // long / NVDA
    address internal constant EARN = 0xA3b6AEe90017b72c0812dC1e013De70eB2917ba3; // Bankr / SPY
    address internal constant JERRY = 0x693Ee058bbF53A21c8f94E971Aa16751d8DD1E18; // long / ETH
    address internal constant ORBIO = 0xAa07A0e9209e16aC99708C3EC70159c6eF3128A3; // Pons v2 / NVDA
    address internal constant CANAL = 0xb796a2cc2f85eCc4772a96B7A58A0d626cC6AEc8; // Pons v2 / SNDK
    address internal constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4; // letscash (Pons v1) / ETH
    address internal constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571; // Pons v1 / ETH
    address internal constant STANDARD = 0x88ad8DdF1E3898412146a534538d418c6F8A9062; // plain pool

    DeployMainnet internal script;
    FallpitDeployer.Core internal c;
    DeployMainnet.Roles internal roles;
    LaunchRecordSource[] internal sources;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_4663", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        script = new DeployMainnet();
        roles.owner = makeAddr("owner");
        roles.guardian = makeAddr("guardian");
        roles.feeRecipient = makeAddr("fees");
        roles.volKeeper = makeAddr("vol");
        address[] memory signers = new address[](3);
        signers[0] = makeAddr("s1");
        signers[1] = makeAddr("s2");
        signers[2] = makeAddr("s3");
        if (signers[0] > signers[1]) (signers[0], signers[1]) = (signers[1], signers[0]);
        if (signers[1] > signers[2]) (signers[1], signers[2]) = (signers[2], signers[1]);
        if (signers[0] > signers[1]) (signers[0], signers[1]) = (signers[1], signers[0]);
        roles.signers = signers;
        roles.threshold = 2;
        script.checkRoles(roles, address(this));

        DeployMainnet.TickerRow[] memory rows = script.tickerTable();
        (FallpitDeployer.Core memory core, LaunchRecordSource[] memory s) =
            script.deployAll(roles, rows, address(script));
        c = core;
        for (uint256 i; i < s.length; ++i) {
            sources.push(s[i]);
        }
        script.handOverForTest(c, roles.owner);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function testFork_everyTickerIsSupported_andInForceADayLater() public onlyFork {
        DeployMainnet.TickerRow[] memory rows = script.tickerTable();
        assertEq(rows.length, 35);
        for (uint256 i; i < rows.length; ++i) {
            bytes32 id = bytes32(bytes(rows[i].symbol));
            assertTrue(c.oracle.supported(id), rows[i].symbol);
        }
        assertFalse(c.book.supported("NVDA"), "not before the owner delay");
        vm.warp(block.timestamp + 24 hours);
        for (uint256 i; i < rows.length; ++i) {
            assertTrue(c.book.supported(bytes32(bytes(rows[i].symbol))), rows[i].symbol);
        }
    }

    function _expect(address coin, bytes32 ticker, uint256 sourceIndex) internal view {
        (bytes32 t,, address s) = c.registry.resolve(coin);
        assertEq(t, ticker, "ticker");
        assertEq(s, address(sources[sourceIndex]), "source");
        (bool ok, bool fot) = c.guard.check(coin);
        assertTrue(ok, "chip guard");
        assertFalse(fot);
    }

    function testFork_realCoinsResolve_andPassTheGuard() public onlyFork {
        _expect(AI, "NVDA", 0);
        _expect(EARN, "SPY", 0);
        _expect(JERRY, "ETH", 0);
        _expect(ORBIO, "NVDA", 1);
        _expect(CANAL, "SNDK", 1);
        _expect(CASHCAT, "ETH", 3);
        _expect(PONS, "ETH", 4);
        address[7] memory known = [AI, EARN, JERRY, ORBIO, CANAL, CASHCAT, PONS];
        for (uint256 i; i < known.length; ++i) {
            (bool k,) = sources[5].anchorOf(known[i]);
            assertFalse(k, "the earlier Pons v2 factory knows only its own coins");
        }
        (AnchorRegistry.Status st,,,) = c.registry.inspect(STANDARD);
        assertEq(uint8(st), uint8(AnchorRegistry.Status.UnknownLaunch));
    }

    function testFork_theDeployerOwnsNothing() public onlyFork {
        assertEq(c.oracle.owner(), roles.owner);
        assertEq(c.guard.owner(), roles.owner);
        assertEq(c.treasury.owner(), roles.owner);
        assertEq(c.registry.owner(), roles.owner);
        assertEq(c.lister.owner(), roles.owner);
        assertEq(c.book.pendingOwner(), roles.owner);
        vm.prank(roles.owner);
        c.book.acceptOwnership();
        assertEq(c.book.owner(), roles.owner);
        assertEq(c.book.OWNER_DELAY(), 24 hours);
        // the router's deployer rights are renounced; the ETH pools follow the book's owner
        assertEq(c.router.deployer(), address(0));
        vm.expectRevert(IFallpitRouter.OnlyDeployerOrOwner.selector);
        c.router.setEthPool(AI, 3_000, 60, address(0));
        vm.prank(roles.owner);
        c.router.setEthPool(AI, 3_000, 60, address(0));
        assertEq(c.router.ethPoolKey(AI).fee, 3_000);
    }

    function testFork_rolesAreChecked() public onlyFork {
        DeployMainnet.Roles memory r = roles;
        r.feeRecipient = 0xEfdB15EE6e7C7C7906cb230AfF1EDb75CcBaA74F;
        vm.expectRevert();
        script.checkRoles(r, address(this));
        r = roles;
        r.signers[0] = address(this);
        vm.expectRevert();
        script.checkRoles(r, address(this));
        r = roles;
        r.owner = address(this);
        script.checkRoles(r, address(this)); // the team's wallet may deploy and own
    }
}
