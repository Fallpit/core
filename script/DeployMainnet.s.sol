// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {LibString} from "solady/utils/LibString.sol";

import {FallpitDeployer} from "./FallpitDeployer.sol";
import {PitOracle} from "../src/PitOracle.sol";
import {ChipGuard} from "../src/ChipGuard.sol";
import {IPitBook} from "../src/hook/IPitBook.sol";
import {PitBook} from "../src/hook/PitBook.sol";
import {CommunityTreasury} from "../src/CommunityTreasury.sol";
import {AnchorRegistry} from "../src/listing/AnchorRegistry.sol";
import {PitLister} from "../src/listing/PitLister.sol";
import {LaunchRecordSource} from "../src/listing/LaunchRecordSource.sol";

/// @title DeployMainnet
/// @notice Deploys and wires all of Fallpit on Robinhood Chain mainnet (4663) in one run, for open listing:
///         the core contracts, every listable ticker on its real Chainlink feed and stock token, the
///         launchpad sources of the anchor registry, the chip guard's trust in the same launchpads, the
///         roles, and then the hand-over of every owner role to `OWNER`.
/// @dev No coins and no houses: on mainnet anyone lists a coin through `PitLister.listCoin`. A ticker can
///      take a house only `OWNER_DELAY` (24 hours) after this run, so run it on a trading day before 4 PM
///      ET: the keeper then records the first close the same day and the first rounds open the day after.
///
///      Environment (nothing secret is printed or written):
///      DEPLOYER_PRIVATE_KEY  optional. Pays for the deployment and runs the setup. Unset: the wallet given
///                            on the command line (`--interactive --sender <address>`).
///      OWNER                 required; may be the deployer (then nothing is handed over). Owner of the
///                            oracle, chip guard, book, treasury, anchor registry and lister. The book's ownership is only offered: OWNER must
///                            call `PitBook.acceptOwnership()` (the run prints the reminder).
///      GUARDIAN              required. May dispute a keeper close in its challenge window.
///      FEE_RECIPIENT         required. Receives the protocol's fee share.
///      VOL_KEEPER            optional. The keeper's sender address (house vol learning). Unset: no vol
///                            updates, every round keeps its opening sigma.
///      HANDOVER              optional, default true. False: the deployer keeps every owner role after
///                            `run()`, so it can create the first houses (`createHouses()`, 24 hours
///                            later) with no transaction from OWNER; `handOver()` then gives them to OWNER.
///      KEEPER_SIGNERS        required. Comma-separated keeper signer addresses.
///      KEEPER_THRESHOLD      signatures a keeper print needs (default: a strict majority).
///      TICKERS               comma-separated subset of the built-in table (default: all of it).
///
///      The delays are fixed at 24 hours (the book and the oracle refuse less on 4663).
///      A dry run (no `--broadcast`) writes `deployments/4663.dry-run.json`; a broadcast writes
///      `deployments/4663.json`. The record has the testnet schema: `mirrorFeed` of a ticker is its
///      Chainlink feed (the app reads `latestRoundData` from it), and `listing.sources` names the launchpad
///      of each anchor source.
contract DeployMainnet is Script, FallpitDeployer {
    uint256 internal constant CHAIN_ID = 4663;
    uint64 internal constant DELAY = 24 hours;

    /// @dev The fee recipient of the testnet deployments: its key leaked. Never a mainnet role.
    address internal constant LEAKED = 0xEfdB15EE6e7C7C7906cb230AfF1EDb75CcBaA74F;

    /// @dev Robinhood Chain's WETH: Bankr and some Doppler integrators launch against it; it names ETH.
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @dev ETH / USD Chainlink feed on 4663.
    address internal constant ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    bytes4 internal constant GET_ASSET_DATA = bytes4(keccak256("getAssetData(address)"));
    bytes4 internal constant GET_LAUNCHED_TOKEN = 0x3cf28b5a; // getLaunchedToken(address)

    /// @notice One listable ticker.
    /// @param stockToken the stock token on 4663 (the anchor coins launch against; zero for ETH)
    /// @param aggregator its Chainlink feed (the bound of every keeper print)
    /// @param volBps a first estimate of the daily volatility, basis points; the keeper's vol learning
    ///        moves each round's sigma within 0.5x to 2.5x of it
    struct TickerRow {
        string symbol;
        address stockToken;
        address aggregator;
        bytes32 pythFeedId;
        uint16 volBps;
        IPitBook.Clock clock;
        IPitBook.FillSource fillSource;
    }

    /// @notice One launchpad contract: an anchor source over it, and optionally the chip guard's trust.
    /// @param key the app's launchpad key (`LAUNCHPADS` in the app's config)
    /// @param guardMatch how the chip guard asks `target` (None: the guard trusts these coins otherwise)
    struct Launchpad {
        string key;
        address target;
        bytes4 selector;
        uint8 knownWord;
        LaunchRecordSource.KnownBy knownBy;
        uint8 anchorWord;
        ChipGuard.RegistryMatch guardMatch;
    }

    struct Roles {
        address owner;
        address guardian;
        address feeRecipient;
        address volKeeper;
        address[] signers;
        uint256 threshold;
    }

    error WrongChain(uint256 chainId);
    error BadRole(string name, address account);
    error UnknownTicker(string symbol);

    function run() external returns (Core memory c, LaunchRecordSource[] memory sources) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        address deployer = _startBroadcast();
        Roles memory r = rolesFromEnv(deployer);
        TickerRow[] memory rows = selectedTickers();
        uint256 head = chainHead();

        (c, sources) = deployAll(r, rows, deployer);
        if (r.owner != deployer && vm.envOr("HANDOVER", true)) _handOver(c, r.owner);
        vm.stopBroadcast();

        string memory file = deploymentsFile();
        vm.writeFile(file, deploymentJson(r, rows, c, sources, deployer, head, block.timestamp));
        console.log("deployment record written to", file);
        _log(r, c, sources, rows);
    }

    /// @notice The whole setup with `creator` as the account of the CREATEs (the broadcaster in `run`, the
    ///         test contract in a fork test).
    function deployAll(Roles memory r, TickerRow[] memory rows, address creator)
        public
        returns (Core memory c, LaunchRecordSource[] memory sources)
    {
        c = _deployCore(
            CoreConfig({
                poolManager: POOL_MANAGER,
                pyth: PYTH,
                owner: creator,
                signers: r.signers,
                threshold: r.threshold,
                ownerDelay: DELAY,
                signerDelay: DELAY
            }),
            creator
        );

        // tickers: the oracle's sources, then the book; the registry names each stock token's ticker
        for (uint256 i; i < rows.length; ++i) {
            TickerRow memory t = rows[i];
            bytes32 id = LibString.toSmallString(t.symbol);
            PitOracle.TickerConfig memory oc;
            oc.pythFeedId = t.pythFeedId;
            oc.aggregator = t.aggregator;
            oc.stockToken = t.stockToken;
            c.oracle.setTicker(id, oc);
            IPitBook.Weights memory w;
            c.book.registerTicker(id, varOf(t.volBps), t.clock, w, 0, t.fillSource);
            if (t.stockToken != address(0)) c.registry.nameTicker(t.stockToken, id);
        }
        // ETH launches are marked address(0) (long.xyz, Pons v2) or WETH (Bankr, Pons v1)
        c.registry.nameTicker(address(0), "ETH");
        c.registry.nameTicker(WETH, "ETH");

        // launchpads: an anchor source each, and the chip guard's trust in their coins
        Launchpad[] memory pads = launchpads();
        sources = new LaunchRecordSource[](pads.length);
        for (uint256 i; i < pads.length; ++i) {
            Launchpad memory p = pads[i];
            sources[i] = new LaunchRecordSource(p.target, p.selector, p.knownWord, p.knownBy, p.anchorWord);
            c.registry.addSource(sources[i]);
            if (p.guardMatch != ChipGuard.RegistryMatch.None) {
                c.guard.setTrustedRegistry(p.target, p.selector, p.guardMatch);
            }
        }
        bytes32[] memory hashes = trustedCodeHashes();
        for (uint256 i; i < hashes.length; ++i) {
            c.guard.setTrustedCodeHash(hashes[i], true);
        }

        c.book.setGuardian(r.guardian);
        if (r.volKeeper != address(0)) c.book.setVolKeeper(r.volKeeper);
        c.book.setFeeRecipient(r.feeRecipient);
    }

    /// @notice Second run, `OWNER_DELAY` after `run()` with HANDOVER=false: the houses the operator makes by
    ///         hand, with no seed (`PitLister.createHouse`, the owner route). HOUSES is `TICKER:COIN,...`,
    ///         for example `NVDA:0x2E8c...1e18,ETH:0x...`. Each coin must pass the chip guard. The vault's
    ///         LPs then fund each house; a round opens once it holds the round's least capital.
    function createHouses() external returns (bytes32[] memory houses) {
        PitLister lister = PitLister(vm.envAddress("LISTER"));
        string[] memory items = LibString.split(vm.envString("HOUSES"), ",");
        houses = new bytes32[](items.length);
        _startBroadcast();
        for (uint256 i; i < items.length; ++i) {
            string[] memory kv = LibString.split(items[i], ":");
            require(kv.length == 2, "HOUSES entry is not TICKER:COIN");
            houses[i] = lister.createHouse(LibString.toSmallString(kv[0]), vm.parseAddress(kv[1]));
            console.log(string.concat("house ", kv[0], " in ", kv[1]));
            console.logBytes32(houses[i]);
        }
        vm.stopBroadcast();
    }

    /// @notice Last run with HANDOVER=false: every owner role goes to OWNER (`PitBook` is offered: OWNER
    ///         calls `acceptOwnership()`). Reads DEPLOYMENTS_FILE or `deployments/4663.json` for the addresses.
    function handOver() external {
        address owner = vm.envAddress("OWNER");
        _role("OWNER", owner);
        string memory json = vm.readFile(vm.envOr("DEPLOYMENTS_FILE", string("deployments/4663.json")));
        Core memory c;
        c.oracle = PitOracle(vm.parseJsonAddress(json, ".contracts.PitOracle.address"));
        c.guard = ChipGuard(vm.parseJsonAddress(json, ".contracts.ChipGuard.address"));
        c.treasury = CommunityTreasury(vm.parseJsonAddress(json, ".contracts.CommunityTreasury.address"));
        c.registry = AnchorRegistry(vm.parseJsonAddress(json, ".contracts.AnchorRegistry.address"));
        c.lister = PitLister(vm.parseJsonAddress(json, ".contracts.PitLister.address"));
        c.book = PitBook(payable(vm.parseJsonAddress(json, ".contracts.PitBook.address")));
        _startBroadcast();
        _handOver(c, owner);
        vm.stopBroadcast();
        console.log("NEXT: OWNER calls PitBook.acceptOwnership() at", address(c.book));
    }

    /// @notice The hand-over with this contract as the owner (fork tests).
    function handOverForTest(Core memory c, address owner) external {
        _handOver(c, owner);
    }

    /// @dev The deployer keeps nothing: it renounced the router's deployer rights in the deploy
    ///      (`FallpitDeployer._deployCore`), and here it hands every owner role to OWNER.
    function _handOver(Core memory c, address owner) internal {
        c.oracle.transferOwnership(owner);
        c.guard.transferOwnership(owner);
        c.treasury.transferOwnership(owner);
        c.registry.transferOwnership(owner);
        c.lister.transferOwnership(owner);
        c.book.transferOwnership(owner); // two-step: OWNER calls acceptOwnership()
    }

    // ---------------------------------------------------------------------------------- configuration

    /// @notice The roles, all required and checked: none may be zero, the deployer or the leaked key.
    function rolesFromEnv(address deployer) public view returns (Roles memory r) {
        r.owner = vm.envAddress("OWNER");
        r.guardian = vm.envAddress("GUARDIAN");
        r.feeRecipient = vm.envAddress("FEE_RECIPIENT");
        r.volKeeper = vm.envOr("VOL_KEEPER", address(0));
        r.signers = _sorted(vm.envAddress("KEEPER_SIGNERS", ","));
        r.threshold = vm.envOr("KEEPER_THRESHOLD", r.signers.length / 2 + 1);
        checkRoles(r, deployer);
    }

    /// @dev The deployer may hold the owner roles (then nothing is handed over). The keeper's keys may not:
    ///      the signers and the vol keeper are hot keys on the keeper's machine.
    function checkRoles(Roles memory r, address deployer) public pure {
        _role("OWNER", r.owner);
        _role("GUARDIAN", r.guardian);
        _role("FEE_RECIPIENT", r.feeRecipient);
        if (r.volKeeper != address(0)) {
            _role("VOL_KEEPER", r.volKeeper);
            if (r.volKeeper == deployer || r.volKeeper == r.owner) revert BadRole("VOL_KEEPER", r.volKeeper);
        }
        if (r.signers.length == 0 || r.threshold == 0 || r.threshold > r.signers.length) {
            revert BadRole("KEEPER_THRESHOLD", address(0));
        }
        for (uint256 i; i < r.signers.length; ++i) {
            _role("KEEPER_SIGNERS", r.signers[i]);
            if (r.signers[i] == deployer) revert BadRole("KEEPER_SIGNERS is the deployer", r.signers[i]);
            if (r.signers[i] == r.owner) revert BadRole("KEEPER_SIGNERS is OWNER", r.signers[i]);
            if (i != 0 && r.signers[i] == r.signers[i - 1]) {
                revert BadRole("KEEPER_SIGNERS twice", r.signers[i]);
            }
        }
    }

    function _role(string memory name, address a) internal pure {
        if (a == address(0) || a == LEAKED) revert BadRole(name, a);
    }

    /// @dev DEPLOYER_PRIVATE_KEY when it is set; else the wallet given on the command line (`--interactive`,
    ///      `--account` or `--ledger`, with `--sender`), so a key never has to be in a file.
    function _startBroadcast() internal returns (address deployer) {
        uint256 key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (key != 0) {
            deployer = vm.addr(key);
            vm.startBroadcast(key);
        } else {
            deployer = msg.sender;
            vm.startBroadcast();
        }
    }

    /// @notice `TICKERS` out of the table, or the whole table.
    function selectedTickers() public view returns (TickerRow[] memory rows) {
        TickerRow[] memory all = tickerTable();
        string[] memory want = vm.envOr("TICKERS", ",", new string[](0));
        if (want.length == 0) return all;
        rows = new TickerRow[](want.length);
        for (uint256 i; i < want.length; ++i) {
            bool found;
            for (uint256 j; j < all.length && !found; ++j) {
                if (keccak256(bytes(all[j].symbol)) == keccak256(bytes(want[i]))) {
                    rows[i] = all[j];
                    found = true;
                }
            }
            if (!found) revert UnknownTicker(want[i]);
        }
    }

    /// @notice The listable tickers (the keeper-signed stocks with a Chainlink bound and the two
    ///         trustless ones), and ETH.
    /// @dev Left out: GLD (its Chainlink feed is a DEX-state price, not a market price) and SGOV (a T-bill
    ///      fund: its daily move is far under the book's least variance, 0.5% a day). TSLA and QQQ are
    ///      `TrustlessOnly` (on a Pyth feed the filler can read); every other ticker is `KeeperOnly`, bounded by
    ///      its Chainlink feed. Volatilities are first estimates; vol learning corrects them per house.
    function tickerTable() public pure returns (TickerRow[] memory t) {
        t = new TickerRow[](35);
        uint256 i;
        t[i++] = _eth();
        t[i++] = _stock(
            "TSLA",
            0x322F0929c4625eD5bAd873c95208D54E1c003b2d,
            0x4A1166a659A55625345e9515b32adECea5547C38,
            0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1,
            350,
            true
        );
        t[i++] = _stock(
            "QQQ",
            0xD5f3879160bc7c32ebb4dC785F8a4F505888de68,
            0x80901d846d5D7B030F26B480776EE3b29374C2ae,
            0x9695e2b96ea7b3859da9ed25b7a46a920a776e2fdae19a7bcfdf2b219230452d,
            120,
            true
        );
        t[i++] = _stock(
            "SPY",
            0x117cc2133c37B721F49dE2A7a74833232B3B4C0C,
            0x319724394D3A0e3669269846abE664Cd621f9f6A,
            0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5,
            100,
            false
        );
        t[i++] = _stock(
            "NVDA",
            0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,
            0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15,
            0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593,
            300,
            false
        );
        t[i++] = _stock(
            "AAPL",
            0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9,
            0x6B22A786bAa607d76728168703a39Ea9C99f2cD0,
            0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688,
            180,
            false
        );
        t[i++] = _stock(
            "MSFT",
            0xe93237C50D904957Cf27E7B1133b510C669c2e74,
            0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E,
            0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1,
            150,
            false
        );
        t[i++] = _stock(
            "AMZN",
            0x12f190a9F9d7D37a250758b26824B97CE941bF54,
            0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C,
            0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a,
            200,
            false
        );
        t[i++] = _stock(
            "GOOGL",
            0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3,
            0xF6f373a037c30F0e5010d854385cA89185AE638b,
            0x5a48c03e9b9cb337801073ed9d166817473697efff0d138874e0f6a33d6d5aa6,
            200,
            false
        );
        t[i++] = _stock(
            "META",
            0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35,
            0x7C38C00C30BEe9378381E7B6135d7283356D71b1,
            0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe,
            250,
            false
        );
        t[i++] = _stock(
            "AMD",
            0x86923f96303D656E4aa86D9d42D1e57ad2023fdC,
            0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72,
            0x3622e381dbca2efd1859253763b1adc63f7f9abb8e76da1aa8e638a57ccde93e,
            350,
            false
        );
        t[i++] = _stock(
            "INTC",
            0xc72b96e0E48ecd4DC75E1e45396e26300BC39681,
            0x3f390C5C24628Ac7C489515402235FeAD71D1913,
            0xc1751e085ee292b8b3b9dd122a135614485a201c35dfc653553f0e28c1baf3ff,
            300,
            false
        );
        t[i++] = _stock(
            "MU",
            0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD,
            0x425EEFdCf05ed6526C3cE61Af99429A228a6d596,
            0x152244dc24665ca7dd3f257b8f442dc449b6346f48235b7b229268cb770dda2d,
            350,
            false
        );
        t[i++] = _stock(
            "ORCL",
            0xb0992820E760d836549ba69BC7598b4af75dEE03,
            0x0e6a64a2B58A6693a531E6c555f3A5d042eEA844,
            0xe47ff732eaeb6b4163902bdee61572659ddf326511917b1423bae93fcdf3153c,
            300,
            false
        );
        t[i++] = _stock(
            "ASML",
            0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA,
            0xB4106147E8cce40b7d46124090d373A71b70f87D,
            0x1a6e324589a0e355919fb1c0389edc3fdf4c46034626bd82aad4e47714cfa94f,
            250,
            false
        );
        t[i++] = _stock(
            "TSM",
            0x58FfE4a942d3885bAa22D7520691F611EF09e7AA,
            0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F,
            0xe722560a66e4ab00522ef20a38fa2ba5d1b41f1c5404723ed895d202a7af7cc4,
            250,
            false
        );
        t[i++] = _stock(
            "DELL",
            0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd,
            0x1C6c8cADBe02E19129c39dDB92281cE4c0bf206b,
            0xa2950270a22ce39a22cb3488ba91e60474cd93c6d01da2ecc5a97c1dd40f4995,
            300,
            false
        );
        t[i++] = _stock(
            "SNDK",
            0xB90A19fF0Af67f7779afF50A882A9CfF42446400,
            0xfb133Fa4B7b385802B693a293606682Df47109A3,
            0xc86a1f20cd7d5d07932baea30bcd8e479b775c4f51f82526bf1de6dc79fa3f76,
            450,
            false
        );
        t[i++] = _stock(
            "BABA",
            0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4,
            0x62Cc8F9b5f56a33c9C8A60c8B92779f523c4E984,
            0x72bc23b1d0afb1f8edef20b7fb60982298993161bc0fd749587d6f60cd1ee9a3,
            300,
            false
        );
        t[i++] = _stock(
            "PLTR",
            0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A,
            0x820ABedFF239034956B7A9d2F0a331f9F075eB4c,
            0x11a70634863ddffb71f2b11f2cff29f73f3db8f6d0b78c49f2b5f4ad36e885f0,
            400,
            false
        );
        t[i++] = _stock(
            "COIN",
            0x6330D8C3178a418788dF01a47479c0ce7CCF450b,
            0xA3a468A452940B7D6b69991207B508c609a98Ef2,
            0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245,
            450,
            false
        );
        t[i++] = _stock(
            "MSTR",
            0xec262a75e413fAfD0dF80480274532C79D42da09,
            0x396118bdFB181e6240E74D243F266B061c0edc3D,
            0xe1e80251e5f5184f2195008382538e847fafc36f751896889dd3d1b1f6111f09,
            500,
            false
        );
        t[i++] = _stock(
            "GME",
            0x1b0E319c6A659F002271B69dB8A7df2F911c153E,
            0x27C71df6A64fB476468EdF256CF72c038baB5B67,
            0x6f9cd89ef1b7fd39f667101a91ad578b6c6ace4579d5f7f285a4b06aa4504be6,
            400,
            false
        );
        t[i++] = _stock(
            "CRCL",
            0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5,
            0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a,
            0x92b8527aabe59ea2b12230f7b532769b133ffb118dfbd48ff676f14b273f1365,
            600,
            false
        );
        t[i++] = _stock(
            "CRWV",
            0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3,
            0xe1b3aABCAFAd1c94708dc1367dcfF8Aa4407487C,
            0x2a78b78189d6d6eff30a825e4698fd14a0b1ca659bb0079bb7e80521c0e8c75d,
            600,
            false
        );
        t[i++] = _stock(
            "NBIS",
            0x9D9c6684F596F66a64C030B93A886D51Fd4D7931,
            0xE1D87B116Ba0fe898998f1D140339D1fA1E09705,
            0x691630d65fbbc8d987717df10453c01907bee8caa60a4aaba4dafca64ea16dc4,
            550,
            false
        );
        t[i++] = _stock(
            "IONQ",
            0x558378E000D634A36593E338eBacdd6207640EfE,
            0x22EfeC4919baf55F360E0EDee4AbEB26DE4971eb,
            0x6af68a227de372e5d19183679911e468e06d85c013f56c376a78a4d942f8f269,
            600,
            false
        );
        t[i++] = _stock(
            "RGTI",
            0x284358abc07F9359f19f4b5b4aC91901Be2597Ba,
            0x2A045cF1C49c61c166C036d2f06FA2D2d984f765,
            0x20aead6dcd4da8321806ce377107952863632fb25f43ec03c36ffd575ac7e708,
            700,
            false
        );
        t[i++] = _stock(
            "RKLB",
            0x3b14C39E89D60D627b42a1A4CA45b5bb45Fc12e2,
            0x045477BF65Aef6f4F2386ad0164579e48381CC74,
            0x40589e289317e4fbd997b1a267606e20a1cc7c3e4689f9e5a5992957917816c8,
            500,
            false
        );
        t[i++] = _stock(
            "CLSK",
            0xcBB95BBF36099d34dA091dc6Fa6F49EfA257Cee3,
            0x810c12D3a554Bc47fd39597Fe3b3AAC4941F50eF,
            0x79e935bc10c55f2c36a08df1564afc5b33425c8dc80829dd954c67e63ed3374a,
            600,
            false
        );
        t[i++] = _stock(
            "USAR",
            0xd917B029C761D264c6A312BBbcDA868658eF86a6,
            0xA994d3684e8400A6c8078226925779FdeE682DD9,
            0x1bf5216f1a4ec4beb87e22110dbca2a62825bb1216d24a17e913164e4f8ec602,
            700,
            false
        );
        t[i++] = _stock(
            "SPCX",
            0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa,
            0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb,
            0x8a593d6edde7a3095213c88116d8840d01e93c2ddeb800bc891772eb8b93bb94,
            400,
            false
        );
        t[i++] = _stock(
            "SLV",
            0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f,
            0x209b73908e92Ae021826eD79609845451Ecba2ce,
            0x6fc08c9963d266069cbd9780d98383dabf2668322a5bef0b9491e11d67e5d7e7,
            200,
            false
        );
        t[i++] = _stock(
            "USO",
            0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344,
            0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c,
            0xd00bd77d97dc5769de77f96d0e1a79cbf1364e14d0dbf046e221bce2e89710dd,
            200,
            false
        );
        t[i++] = _stock(
            "EWY",
            0x7f0aBeF0C07280F82c6a08ead09dEd6BAE2C13Fc,
            0xEFdf54610B62A7753Ec30bDc380847c12D32e1D1,
            0x7be2b3f9f9d02b1ffcf61fc26ad5cc6aff4dd02044f9abc22ee57f37b3b5d2e5,
            160,
            false
        );
        assert(i == t.length);
    }

    /// @notice The launchpad contracts on 4663 (fork test `test/listing/fork`).
    /// @dev Doppler's Airlock serves long.xyz, Bankr and other integrators: one source, keyed `long`. Its
    ///      coins are trusted by code hash (`trustedCodeHashes`), not by the Airlock, so its guard match is
    ///      None. Pons v1 has three factories, one source each; `0xd9eC` is most likely the CashCat beta
    ///      factory (an early letscash.fun factory). Pons v2 has two factories: the live one and an earlier one
    ///      (1,044 launches) whose coins the live one does not know. Left out: the imd.fun
    ///      pads (75 of 81 coins pair with IMD, which has no feed; the coin template needs a fork test
    ///      first), two unnamed WETH launchers (the same), and every launchpad with no pair record
    ///      (letscash.fun's live factory, Clanker, PAIR): those coins list by the owner route.
    function launchpads() public pure returns (Launchpad[] memory p) {
        p = new Launchpad[](6);
        p[0] = Launchpad(
            "long",
            0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862,
            GET_ASSET_DATA,
            4,
            LaunchRecordSource.KnownBy.NonZero,
            0,
            ChipGuard.RegistryMatch.None
        );
        p[1] = Launchpad(
            "pons",
            0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e,
            GET_LAUNCHED_TOKEN,
            0,
            LaunchRecordSource.KnownBy.Self,
            4,
            ChipGuard.RegistryMatch.ReturnsChip
        );
        p[2] = Launchpad(
            "pons",
            0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB,
            GET_LAUNCHED_TOKEN,
            0,
            LaunchRecordSource.KnownBy.Self,
            2,
            ChipGuard.RegistryMatch.ReturnsChip
        );
        p[3] = Launchpad(
            "letscash",
            0xD9eC2db5f3D1b236843925949fe5bd8a3836FCcB,
            GET_LAUNCHED_TOKEN,
            0,
            LaunchRecordSource.KnownBy.Self,
            2,
            ChipGuard.RegistryMatch.ReturnsChip
        );
        p[4] = Launchpad(
            "pons",
            0x0c37a24F5D23A486FA692d1500881d698B1F77a4,
            GET_LAUNCHED_TOKEN,
            0,
            LaunchRecordSource.KnownBy.Self,
            2,
            ChipGuard.RegistryMatch.ReturnsChip
        );
        p[5] = Launchpad(
            "pons",
            0x7E1EAbd52Ae29598e6483F72dCf1a70b14284dB8,
            GET_LAUNCHED_TOKEN,
            0,
            LaunchRecordSource.KnownBy.Self,
            4,
            ChipGuard.RegistryMatch.ReturnsChip
        );
    }

    /// @notice Coin templates the chip guard trusts by `extcodehash`: the Doppler clone (long.xyz, Bankr).
    function trustedCodeHashes() public pure returns (bytes32[] memory h) {
        h = new bytes32[](1);
        h[0] = 0xf10f86b05965a827a332e6c73086f18026fbe3917f4bffbec3f938b3b5397b56;
    }

    /// @notice A daily volatility in basis points as the book's daily variance, WAD.
    function varOf(uint16 volBps) public pure returns (uint256) {
        uint256 v = uint256(volBps) * 1e14;
        return v * v / 1e18;
    }

    function _eth() internal pure returns (TickerRow memory) {
        return TickerRow(
            "ETH",
            address(0),
            ETH_USD,
            0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
            350,
            IPitBook.Clock.EveryDay,
            IPitBook.FillSource.KeeperOnly
        );
    }

    function _stock(string memory s, address token, address feed, bytes32 pyth, uint16 vol, bool trustless)
        internal
        pure
        returns (TickerRow memory)
    {
        return TickerRow(
            s,
            token,
            feed,
            pyth,
            vol,
            IPitBook.Clock.NYWeekdays,
            trustless ? IPitBook.FillSource.TrustlessOnly : IPitBook.FillSource.KeeperOnly
        );
    }

    // ------------------------------------------------------------------------------ deployment record

    function deploymentsFile() public view returns (string memory) {
        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        return string.concat("deployments/", vm.toString(block.chainid), live ? ".json" : ".dry-run.json");
    }

    /// @notice The chain's newest block by its RPC (on an Arbitrum chain `block.number` is the parent's).
    function chainHead() public returns (uint256 head) {
        head = vm.getBlockNumber();
        try vm.rpc("eth_blockNumber", "[]") returns (bytes memory r) {
            if (r.length != 0 && r.length <= 32) head = uint256(bytes32(r)) >> (8 * (32 - r.length));
        } catch {}
    }

    function deploymentJson(
        Roles memory r,
        TickerRow[] memory rows,
        Core memory c,
        LaunchRecordSource[] memory sources,
        address deployer,
        uint256 head,
        uint256 at
    ) public view returns (string memory) {
        uint256 inForce = at + DELAY;
        string memory top = string.concat(
            '{"schema":1,"chainId":',
            vm.toString(block.chainid),
            ',"deployedAt":',
            vm.toString(at),
            ',"deployer":',
            _q(vm.toString(deployer)),
            ',"roles":',
            _rolesJson(r),
            ',"external":{"poolManager":',
            _q(vm.toString(POOL_MANAGER)),
            ',"pyth":',
            _q(vm.toString(PYTH)),
            "}"
        );
        return string.concat(
            top,
            ',"contracts":{',
            _contractsJson(c, head),
            '},"chips":[],"tickers":[',
            _tickersJson(rows, head, inForce),
            '],"housesFrom":',
            vm.toString(inForce),
            ',"housesBlock":0,"houses":[],"listing":{"sources":{',
            _sourcesJson(sources),
            "}}}"
        );
    }

    function _contractsJson(Core memory c, uint256 head) internal pure returns (string memory) {
        string memory a = string.concat(
            _entry("LadderMath", address(c.math), head, false),
            _entry("PitOracle", address(c.oracle), head, false),
            _entry("ChipGuard", address(c.guard), head, false),
            _entry("PitVault", address(c.vault), head, false),
            _entry("PitBook", address(c.book), head, false),
            _entry("FallpitRouter", address(c.router), head, false),
            _entry("FallpitHook", address(c.hook), head, false)
        );
        return string.concat(
            a,
            _entry("FallpitLens", address(c.lens), head, false),
            _entry("FallpitDirectory", address(c.directory), head, false),
            _entry("CommunityTreasury", address(c.treasury), head, false),
            _entry("AnchorRegistry", address(c.registry), head, false),
            _entry("PitLister", address(c.lister), head, false),
            _entry("VaultFeeForwarderFactory", address(c.forwarders), head, true)
        );
    }

    function _rolesJson(Roles memory r) internal pure returns (string memory) {
        string memory signers;
        for (uint256 i; i < r.signers.length; ++i) {
            signers = string.concat(signers, i == 0 ? "" : ",", _q(vm.toString(r.signers[i])));
        }
        return string.concat(
            '{"owner":',
            _q(vm.toString(r.owner)),
            ',"guardian":',
            _q(vm.toString(r.guardian)),
            ',"volKeeper":',
            _q(vm.toString(r.volKeeper)),
            ',"feeRecipient":',
            _q(vm.toString(r.feeRecipient)),
            ',"keeperSigners":[',
            signers,
            '],"keeperThreshold":',
            vm.toString(r.threshold),
            "}"
        );
    }

    function _tickersJson(TickerRow[] memory rows, uint256 head, uint256 inForce)
        internal
        pure
        returns (string memory json)
    {
        for (uint256 i; i < rows.length; ++i) {
            TickerRow memory t = rows[i];
            json = string.concat(
                json,
                i == 0 ? "{" : ",{",
                '"symbol":',
                _q(t.symbol),
                ',"id":',
                _q(vm.toString(LibString.toSmallString(t.symbol))),
                ',"clock":',
                _q(t.clock == IPitBook.Clock.EveryDay ? "EveryDay" : "NYWeekdays"),
                ',"fillSource":',
                _q(t.fillSource == IPitBook.FillSource.TrustlessOnly ? "TrustlessOnly" : "KeeperOnly"),
                string.concat(
                    ',"windows":',
                    vm.toString(t.clock == IPitBook.Clock.EveryDay ? uint256(15) : uint256(13)),
                    ',"pythFeedId":',
                    _q(vm.toString(t.pythFeedId)),
                    ',"mirrorFeed":',
                    _q(vm.toString(t.aggregator)),
                    ',"aggregator":',
                    _q(vm.toString(t.aggregator)),
                    ',"stockToken":',
                    _q(vm.toString(t.stockToken)),
                    ',"registeredBlock":',
                    vm.toString(head),
                    ',"inForceAt":',
                    vm.toString(inForce),
                    "}"
                )
            );
        }
    }

    function _sourcesJson(LaunchRecordSource[] memory sources) internal pure returns (string memory json) {
        Launchpad[] memory pads = launchpads();
        for (uint256 i; i < sources.length; ++i) {
            json = string.concat(
                json, i == 0 ? "" : ",", _q(LibString.toHexString(address(sources[i]))), ":", _q(pads[i].key)
            );
        }
    }

    function _entry(string memory name, address at, uint256 head, bool last)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            _q(name),
            ':{"address":',
            _q(vm.toString(at)),
            ',"deployBlock":',
            vm.toString(head),
            last ? "}" : "},"
        );
    }

    function _q(string memory s) internal pure returns (string memory) {
        return string.concat('"', s, '"');
    }

    function _sorted(address[] memory a) internal pure returns (address[] memory) {
        for (uint256 i = 1; i < a.length; ++i) {
            for (uint256 j = i; j > 0 && a[j - 1] > a[j]; --j) {
                (a[j - 1], a[j]) = (a[j], a[j - 1]);
            }
        }
        return a;
    }

    function _log(Roles memory r, Core memory c, LaunchRecordSource[] memory sources, TickerRow[] memory rows)
        internal
        pure
    {
        console.log("owner", r.owner);
        console.log("PitVault", address(c.vault));
        console.log("PitBook", address(c.book));
        console.log("FallpitRouter", address(c.router));
        console.log("FallpitHook", address(c.hook));
        console.log("FallpitLens", address(c.lens));
        console.log("FallpitDirectory", address(c.directory));
        console.log("AnchorRegistry", address(c.registry));
        console.log("PitLister", address(c.lister));
        console.log("VaultFeeForwarderFactory", address(c.forwarders));
        console.log("tickers", rows.length, "anchor sources", sources.length);
        console.log("NEXT: tickers take houses 24 hours from now (OWNER_DELAY)");
        console.log("NEXT: OWNER calls PitBook.acceptOwnership() at", address(c.book), "after the hand-over");
    }
}
