// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ChipGuard} from "../../../src/ChipGuard.sol";

/// @notice Read-only fork test against Robinhood Chain mainnet (4663): what identifies each coin template on
///         chain, and that ChipGuard configured from those findings sorts the real coins correctly.
/// @dev Skipped unless FORK_RPC_4663 is set, for example
///      `FORK_RPC_4663=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/vault/fork/*"`.
///      Findings are written up in src/vault/DESIGN.md.
contract ChipGuardForkTest is Test {
    // Doppler coins (DopplerERC20V1 clones): long.xyz and Bankr launches.
    address internal constant AI = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18; // long / NVDA
    address internal constant BONER = 0x98096d17e191B3dA1d5f99a6D7b3584351b11E18; // long / HIMS
    address internal constant MEME = 0x385F4f8ae47651ce5F58F5265395a669f8281e18; // long / AMC
    address internal constant MUSEBOOK = 0x91A2DAe9699f0B82540B5886b0d8759C22820bA3; // Bankr / META
    address internal constant EARN = 0xA3b6AEe90017b72c0812dC1e013De70eB2917ba3; // Bankr / SPY
    address internal constant GME_BANKR = 0xc2362AfF2A2a4CC1f48cF3Dab2C4e2605eb94BA3; // Bankr / GME
    address internal constant GAS = 0x28dA843C0223990Fb57701319B30804b89eFF111; // other Doppler / USO
    address internal constant DOPPLER_IMPL = 0x3Be8B97Fd0e713B5aBE0649Fa830223B6B4BC599;
    bytes32 internal constant DOPPLER_CLONE_HASH =
        0xf10f86b05965a827a332e6c73086f18026fbe3917f4bffbec3f938b3b5397b56;

    // Pons v2 coins.
    address internal constant PONS_V2_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    bytes4 internal constant GET_LAUNCHED_TOKEN = 0x3cf28b5a; // getLaunchedToken(address)
    address internal constant ORBIO = 0xAa07A0e9209e16aC99708C3EC70159c6eF3128A3; // NVDA
    address internal constant UBIK = 0x812486EAea648819853F8E372dc9f1516C7868Bd; // GLD
    address internal constant SHROOM = 0xab093dEF657F15dF31b33922A95e047aDd645B29; // MU
    address internal constant DARK = 0xDc45b71d7203c2e8baafC43A19BcA0Eb993bB54E; // NVDA
    address internal constant OPTIMUS = 0x0fF9072a1EAD154d92C2d2Fef16AFba6028Ce2B2; // TSLA
    address internal constant BOW = 0x451b42A15100C340CA12F7c66DE06fac5EA2D751; // SPY

    // Coins that are neither.
    address internal constant PONS_V1 = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA_STOCK = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant PAIR = 0x6b1d42927B1a84eC28Fa88d4fC6FA7AF404966be;

    address internal owner = makeAddr("owner");
    ChipGuard internal guard;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_4663", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        forked = true;

        guard = new ChipGuard(owner);
        vm.startPrank(owner);
        guard.setTrustedCodeHash(DOPPLER_CLONE_HASH, true);
        guard.setTrustedRegistry(PONS_V2_FACTORY, GET_LAUNCHED_TOKEN, ChipGuard.RegistryMatch.ReturnsChip);
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _dopplerCoins() internal pure returns (address[7] memory) {
        return [AI, BONER, MEME, MUSEBOOK, EARN, GME_BANKR, GAS];
    }

    function _ponsCoins() internal pure returns (address[6] memory) {
        return [ORBIO, UBIK, SHROOM, DARK, OPTIMUS, BOW];
    }

    function _others() internal pure returns (address[4] memory) {
        return [PONS_V1, USDG, NVDA_STOCK, PAIR];
    }

    function _allowed(address chip) internal view returns (bool allowed) {
        (allowed,) = guard.check(chip);
    }

    /// @dev Finding 1: every Doppler coin is the same 44-byte minimal clone of one implementation, so one
    ///      `extcodehash` identifies the template (long.xyz, Bankr and other Doppler launches alike).
    function testFork_dopplerCoins_shareOneCodeHash() public onlyFork {
        bytes memory expected =
            abi.encodePacked(hex"3d3d3d3d363d3d37363d73", DOPPLER_IMPL, hex"5af43d3d93803e602a57fd5bf3");
        assertEq(expected.length, 44);
        assertEq(keccak256(expected), DOPPLER_CLONE_HASH);
        address[7] memory coins = _dopplerCoins();
        for (uint256 i; i < coins.length; ++i) {
            assertEq(coins[i].code, expected, "runtime code is the clone of the implementation");
            assertEq(coins[i].codehash, DOPPLER_CLONE_HASH);
        }
        // The implementation is real code and is itself a different hash.
        assertGt(DOPPLER_IMPL.code.length, 10_000);
        assertTrue(DOPPLER_IMPL.codehash != DOPPLER_CLONE_HASH);
    }

    /// @dev Finding 2: Pons v2 coins are full contracts of one size whose bytecode differs per coin
    ///      (constructor immutables), so no code hash identifies the template. The factory does:
    ///      `getLaunchedToken(coin)` returns a record whose first word is the coin itself, zero otherwise.
    function testFork_ponsV2Coins_needTheFactoryLookup() public onlyFork {
        address[6] memory coins = _ponsCoins();
        for (uint256 i; i < coins.length; ++i) {
            assertEq(coins[i].code.length, 3248, "same template size");
            for (uint256 j; j < i; ++j) {
                assertTrue(coins[i].codehash != coins[j].codehash, "code hashes differ per coin");
            }
            assertEq(_launchedToken(coins[i]), coins[i], "the factory knows the coin");
            // The coin names the same factory, but that alone proves nothing (any coin could claim it).
            (bool ok, bytes memory ret) = coins[i].staticcall(abi.encodeWithSignature("launchFactory()"));
            assertTrue(ok);
            assertEq(abi.decode(ret, (address)), PONS_V2_FACTORY);
        }
        address[7] memory doppler = _dopplerCoins();
        for (uint256 i; i < doppler.length; ++i) {
            assertEq(_launchedToken(doppler[i]), address(0));
        }
        address[4] memory others = _others();
        for (uint256 i; i < others.length; ++i) {
            assertEq(
                _launchedToken(others[i]), address(0), "v1 and unrelated coins are unknown to the v2 factory"
            );
        }
    }

    /// @dev ChipGuard configured with the one hash and the one registry sorts the real coins.
    function testFork_check_sortsRealCoins() public onlyFork {
        address[7] memory doppler = _dopplerCoins();
        for (uint256 i; i < doppler.length; ++i) {
            (bool allowed, bool fot) = guard.check(doppler[i]);
            assertTrue(allowed, "Doppler coin allowed by code hash");
            assertFalse(fot);
            assertFalse(guard.launchedByTrustedRegistry(doppler[i]));
            // The balance limit of these coins has expired; the guard reads it on every check.
            (bool ok, bytes memory ret) =
                doppler[i].staticcall(abi.encodeWithSignature("isBalanceLimitActive()"));
            assertTrue(ok);
            assertFalse(abi.decode(ret, (bool)));
        }
        address[6] memory pons = _ponsCoins();
        for (uint256 i; i < pons.length; ++i) {
            assertTrue(_allowed(pons[i]), "Pons v2 coin allowed by the factory lookup");
            assertFalse(guard.trustedCodeHash(pons[i].codehash));
        }
        address[4] memory others = _others();
        for (uint256 i; i < others.length; ++i) {
            assertFalse(_allowed(others[i]), "everything else needs the owner's approval");
        }

        // Owner approval is the third route (USDG as a chip), and a refusal beats the template routes.
        vm.startPrank(owner);
        guard.approve(USDG, true);
        guard.refuse(AI, true);
        guard.refuse(ORBIO, true);
        vm.stopPrank();
        assertTrue(_allowed(USDG));
        assertFalse(_allowed(AI));
        assertFalse(_allowed(ORBIO));
        assertTrue(_allowed(BONER));
    }

    /// @dev A Doppler coin whose launch balance limit is still active is not allowed. No live coin in the
    ///      sample has one, so the flag is forced on a real clone through its storage-free mock call.
    function testFork_dopplerCoin_withActiveBalanceLimit_isNotAllowed() public onlyFork {
        assertTrue(_allowed(BONER));
        vm.mockCall(BONER, abi.encodeWithSignature("isBalanceLimitActive()"), abi.encode(true));
        assertFalse(_allowed(BONER));
        vm.clearMockedCalls();
        assertTrue(_allowed(BONER));
    }

    function _launchedToken(address coin) internal view returns (address token) {
        (bool ok, bytes memory ret) =
            PONS_V2_FACTORY.staticcall(abi.encodeWithSelector(GET_LAUNCHED_TOKEN, coin));
        assertTrue(ok);
        assertGe(ret.length, 32);
        token = address(uint160(uint256(bytes32(ret))));
    }
}
