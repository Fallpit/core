// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ChipGuard} from "../../../src/ChipGuard.sol";
import {AnchorRegistry} from "../../../src/listing/AnchorRegistry.sol";
import {LaunchRecordSource} from "../../../src/listing/LaunchRecordSource.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Read-only fork test against Robinhood Chain mainnet (4663): the anchor sources configured for
///         Doppler, Pons v2 and the three Pons v1 factories find the real coins' launch pairs, and
///         ChipGuard trusts Pons v1 coins through their factories.
/// @dev Skipped unless FORK_RPC_4663 is set, for example
///      `FORK_RPC_4663=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/listing/fork/*"`.
///      Findings: 248 coins checked.
contract AnchorForkTest is Test {
    bytes4 internal constant GET_ASSET_DATA = bytes4(keccak256("getAssetData(address)"));
    bytes4 internal constant GET_LAUNCHED_TOKEN = 0x3cf28b5a; // getLaunchedToken(address)
    bytes32 internal constant DOPPLER_CLONE_HASH =
        0xf10f86b05965a827a332e6c73086f18026fbe3917f4bffbec3f938b3b5397b56;

    // Launchpads.
    address internal constant AIRLOCK = 0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862;
    address internal constant PONS_V2 = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant PONS_V1_A = 0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB;
    address internal constant PONS_V1_D = 0xD9eC2db5f3D1b236843925949fe5bd8a3836FCcB;
    address internal constant PONS_V1_0 = 0x0c37a24F5D23A486FA692d1500881d698B1F77a4;

    // Anchors.
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant DELL = 0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd;
    address internal constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address internal constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address internal constant USO = 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant SNDK = 0xB90A19fF0Af67f7779afF50A882A9CfF42446400;
    address internal constant TSM = 0x58FfE4a942d3885bAa22D7520691F611EF09e7AA;

    // Doppler coins: long.xyz, Bankr, other integrators.
    address internal constant AI = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18; // long / NVDA
    address internal constant A_DELL = 0x05D73A652529f0b1a6Dd2B89dE26b449eC9F1e18; // long / DELL
    address internal constant JERRY = 0x693Ee058bbF53A21c8f94E971Aa16751d8DD1E18; // long / ETH (address 0)
    address internal constant QUOTIENT = 0x2531F3ca1b31086b7FC130eCDa6D3253DAF83ba3; // Bankr / WETH
    address internal constant EARN = 0xA3b6AEe90017b72c0812dC1e013De70eB2917ba3; // Bankr / SPY
    address internal constant MUSEBOOK = 0x91A2DAe9699f0B82540B5886b0d8759C22820bA3; // Bankr / META
    address internal constant STATICS = 0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd; // other / WETH
    address internal constant UNICORN = 0x9Defa9eA4bC271029c25FE1cBf721c324BaD3B63; // other / QQQ
    address internal constant GAS = 0x28dA843C0223990Fb57701319B30804b89eFF111; // other / USO
    address internal constant AP = 0x69c68e4C00C6F6e4Ac027300293a879Be1E11E18; // other / AAPL

    // Pons v2 coins.
    address internal constant ORBIO = 0xAa07A0e9209e16aC99708C3EC70159c6eF3128A3; // NVDA
    address internal constant RKST = 0x8d1612b4B78eBf08CFBf01A04Fa270CCbB0509A2; // SPCX
    address internal constant BOW = 0x451b42A15100C340CA12F7c66DE06fac5EA2D751; // SPY
    address internal constant NOVAAI = 0x51250B135174Ca09450EC01c4afF73CF69DBb590; // ETH (address 0)
    address internal constant BUN = 0x07EBB29a38Fbcb41563817e5E19f2ceC619C90D2; // ETH (address 0)
    address internal constant CANAL = 0xb796a2cc2f85eCc4772a96B7A58A0d626cC6AEc8; // SNDK (deepest pool: TSM)

    // Pons v1 coins, one or more per factory.
    address internal constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4; // factory D
    address internal constant WALLET = 0x0339f5459FC690aC85F1782e15782A151b4A9E1b; // factory D
    address internal constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571; // factory 0
    address internal constant DELTA = 0xe8ffd7e24187F72afB08d75B1bb13088A989a791; // factory A
    address internal constant PONGO = 0xedAee44320107CAa714BaAEc486261A87F27022d; // factory A

    // Coins no source knows.
    address internal constant STANDARD = 0x88ad8DdF1E3898412146a534538d418c6F8A9062; // plain pool
    address internal constant PIPEDOG = 0x5Cb6F181081301b44905F3ae15419112ecaBd8A6; // plain v3 pool
    address internal constant ZAPS = 0xDd90bFa4adC7F4401E611AbaC692D939F9F4CB07; // Clanker

    address internal owner = makeAddr("owner");
    AnchorRegistry internal reg;
    LaunchRecordSource internal doppler;
    LaunchRecordSource internal ponsV2;
    LaunchRecordSource[3] internal ponsV1;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_4663", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        forked = true;

        doppler = new LaunchRecordSource(AIRLOCK, GET_ASSET_DATA, 4, LaunchRecordSource.KnownBy.NonZero, 0);
        ponsV2 = new LaunchRecordSource(PONS_V2, GET_LAUNCHED_TOKEN, 0, LaunchRecordSource.KnownBy.Self, 4);
        address[3] memory v1 = [PONS_V1_A, PONS_V1_D, PONS_V1_0];
        reg = new AnchorRegistry(owner);
        vm.startPrank(owner);
        reg.addSource(doppler);
        reg.addSource(ponsV2);
        for (uint256 i; i < 3; ++i) {
            ponsV1[i] =
                new LaunchRecordSource(v1[i], GET_LAUNCHED_TOKEN, 0, LaunchRecordSource.KnownBy.Self, 2);
            reg.addSource(ponsV1[i]);
        }
        reg.nameTicker(address(0), "ETH");
        reg.nameTicker(WETH, "ETH");
        reg.nameTicker(NVDA, "NVDA");
        reg.nameTicker(DELL, "DELL");
        reg.nameTicker(SPCX, "SPCX");
        reg.nameTicker(SPY, "SPY");
        reg.nameTicker(QQQ, "QQQ");
        reg.nameTicker(META, "META");
        reg.nameTicker(USO, "USO");
        reg.nameTicker(AAPL, "AAPL");
        reg.nameTicker(SNDK, "SNDK");
        reg.nameTicker(TSM, "TSM");
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _expect(address coin, bytes32 ticker, address anchor, address source) internal view {
        (bytes32 t, address a, address s) = reg.resolve(coin);
        assertEq(t, ticker, "ticker");
        assertEq(a, anchor, "anchor");
        assertEq(s, source, "source");
    }

    function testFork_doppler_findsTheNumeraire() public onlyFork {
        _expect(AI, "NVDA", NVDA, address(doppler));
        _expect(A_DELL, "DELL", DELL, address(doppler));
        _expect(JERRY, "ETH", address(0), address(doppler));
        _expect(QUOTIENT, "ETH", WETH, address(doppler));
        _expect(EARN, "SPY", SPY, address(doppler));
        _expect(MUSEBOOK, "META", META, address(doppler));
        _expect(STATICS, "ETH", WETH, address(doppler));
        _expect(UNICORN, "QQQ", QQQ, address(doppler));
        _expect(GAS, "USO", USO, address(doppler));
        _expect(AP, "AAPL", AAPL, address(doppler));
    }

    function testFork_ponsV2_findsThePairToken() public onlyFork {
        _expect(ORBIO, "NVDA", NVDA, address(ponsV2));
        _expect(RKST, "SPCX", SPCX, address(ponsV2));
        _expect(BOW, "SPY", SPY, address(ponsV2));
        _expect(NOVAAI, "ETH", address(0), address(ponsV2));
        _expect(BUN, "ETH", address(0), address(ponsV2));
    }

    /// @dev CANAL's deepest pool is against TSM, but it launched against SNDK: the launch record decides.
    function testFork_canal_isSndk_notTsm() public onlyFork {
        _expect(CANAL, "SNDK", SNDK, address(ponsV2));
    }

    function testFork_ponsV1_eachFactoryKnowsOnlyItsCoins() public onlyFork {
        _expect(CASHCAT, "ETH", WETH, address(ponsV1[1]));
        _expect(WALLET, "ETH", WETH, address(ponsV1[1]));
        _expect(PONS, "ETH", WETH, address(ponsV1[2]));
        _expect(DELTA, "ETH", WETH, address(ponsV1[0]));
        _expect(PONGO, "ETH", WETH, address(ponsV1[0]));
        (bool known,) = ponsV1[0].anchorOf(CASHCAT);
        assertFalse(known, "factory A does not know a factory D coin");
        (known,) = ponsV1[1].anchorOf(PONS);
        assertFalse(known, "factory D does not know the PONS factory's coin");
    }

    /// @dev No source knows two launchpads' coins: each coin is known by one source only.
    function testFork_noCoinIsKnownTwice() public onlyFork {
        address[21] memory coins = [
            AI,
            A_DELL,
            JERRY,
            QUOTIENT,
            EARN,
            MUSEBOOK,
            STATICS,
            UNICORN,
            GAS,
            AP,
            ORBIO,
            RKST,
            BOW,
            NOVAAI,
            BUN,
            CANAL,
            CASHCAT,
            WALLET,
            PONS,
            DELTA,
            PONGO
        ];
        address[5] memory srcs =
            [address(doppler), address(ponsV2), address(ponsV1[0]), address(ponsV1[1]), address(ponsV1[2])];
        for (uint256 i; i < coins.length; ++i) {
            uint256 n;
            for (uint256 j; j < srcs.length; ++j) {
                (bool known,) = LaunchRecordSource(srcs[j]).anchorOf(coins[i]);
                if (known) ++n;
            }
            assertEq(n, 1, "known by exactly one source");
        }
    }

    function testFork_unknownCoins_andStockTokens_areUnknown() public onlyFork {
        address[6] memory coins = [STANDARD, PIPEDOG, ZAPS, NVDA, WETH, SPY];
        for (uint256 i; i < coins.length; ++i) {
            (AnchorRegistry.Status st,,,) = reg.inspect(coins[i]);
            assertEq(uint8(st), uint8(AnchorRegistry.Status.UnknownLaunch));
        }
    }

    /// @dev A coin whose anchor has no ticker yet: TSM is named here, so un-name it and see the status.
    function testFork_anchorWithoutTicker() public onlyFork {
        vm.prank(owner);
        reg.nameTicker(SNDK, bytes32(0));
        (AnchorRegistry.Status st,, address a,) = reg.inspect(CANAL);
        assertEq(uint8(st), uint8(AnchorRegistry.Status.AnchorNotListed));
        assertEq(a, SNDK);
    }

    /// @dev Pons v1 coins become chips through their factories (`ReturnsChip`), and the v1 template moves
    ///      exact amounts (no transfer tax).
    function testFork_ponsV1_inChipGuard_andNoTax() public onlyFork {
        ChipGuard guard = new ChipGuard(owner);
        vm.startPrank(owner);
        guard.setTrustedCodeHash(DOPPLER_CLONE_HASH, true);
        guard.setTrustedRegistry(PONS_V2, GET_LAUNCHED_TOKEN, ChipGuard.RegistryMatch.ReturnsChip);
        guard.setTrustedRegistry(PONS_V1_A, GET_LAUNCHED_TOKEN, ChipGuard.RegistryMatch.ReturnsChip);
        guard.setTrustedRegistry(PONS_V1_D, GET_LAUNCHED_TOKEN, ChipGuard.RegistryMatch.ReturnsChip);
        guard.setTrustedRegistry(PONS_V1_0, GET_LAUNCHED_TOKEN, ChipGuard.RegistryMatch.ReturnsChip);
        vm.stopPrank();

        address[5] memory v1 = [CASHCAT, WALLET, PONS, DELTA, PONGO];
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        for (uint256 i; i < v1.length; ++i) {
            (bool allowed, bool fot) = guard.check(v1[i]);
            assertTrue(allowed, "v1 coin allowed through its factory");
            assertFalse(fot);
            deal(v1[i], alice, 1_000e18);
            uint256 before = IERC20Min(v1[i]).balanceOf(bob);
            vm.prank(alice);
            assertTrue(IERC20Min(v1[i]).transfer(bob, 1_000e18));
            assertEq(IERC20Min(v1[i]).balanceOf(bob) - before, 1_000e18, "exact amount arrives");
            assertEq(IERC20Min(v1[i]).balanceOf(alice), 0);
        }
        (bool ok,) = guard.check(STANDARD);
        assertFalse(ok, "a plain-pool coin still needs the owner");
    }
}
