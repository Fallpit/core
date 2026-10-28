// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IChipGuard} from "./interfaces/IChipGuard.sol";
import {IPitVault, ITickerGate} from "./interfaces/IPitVault.sol";

/// @dev The one view of the hook the vault reads to find the router.
interface IRouterOf {
    function router() external view returns (address);
}

/// @title PitVault
/// @notice The houses: one pool of chips per (ticker, chip). LPs own shares of a house; the endowment owns
///         none, can never be withdrawn, and shares every result pro rata. See contracts/SPEC.md section 5 and src/vault/DESIGN.md.
/// @dev No owner, no proxy, no emergency exit. The only privileged caller is the immutable hook, and it can
///      only move a house's capital out to a round and book what comes back. The `...For` LP functions
///      also accept the router the hook pins (`router()`, for session-signed vault actions) and an
///      ERC-6909 operator of the owner; they act exactly as the owner would, and every payout and every
///      share goes to the owner, never to the caller. So an operator here has more power than in plain
///      ERC-6909 (which only lets it move shares): it can also cancel the owner's queued deposits, request
///      withdrawals of the owner's shares and claim for the owner, in every house. No value moves to it,
///      but it can change the owner's position (see src/vault/DESIGN.md 1.6).
///
///      Accounting of one house, all in chips:
///      - `lpAssets`: capital owned by the shares. Share price = (lpAssets + 1) / (totalShares + 1e6).
///      - `endowment`: capital that owns no shares (donations). Never withdrawable; it takes its pro rata
///        part of every profit and every loss.
///      - `pendingDeposits`, `pendingDonations`: chips that arrived while the house was locked.
///      - `claimableTotal`: chips set aside for processed withdrawals.
///      While a house is locked `lpAssets + endowment` is out in the round and everything else stays here.
///      `accounted[chip]` is the sum of what the vault holds for all houses of a chip and never exceeds the
///      vault's balance of that chip.
contract PitVault is IPitVault, ReentrancyGuardTransient {
    using FixedPointMathLib for uint256;

    /// @dev Virtual shares and assets (ERC-4626 style offset) that make the first-depositor inflation attack
    ///      unprofitable. A fresh house mints 1e6 shares per chip unit.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @dev When a losing round leaves more than this many shares per chip unit (a price drop of 1e12 from
    ///      the opening price) the leftover is dust: it moves to the endowment and the shares price at 0.
    ///      This bounds the share supply so no later mint can overflow.
    uint256 internal constant MAX_SHARES_PER_ASSET = 1e18;

    /// @dev `sent`: the nominal chips sent to the running round, valid only while `locked`.
    ///      `pullRoundCapital` writes it before it locks, and only `returnRoundCapital` (locked only) reads
    ///      it. After the round it keeps its last value, so the next round writes a slot that is not zero;
    ///      `getHouse` shows 0 while the house is not locked.
    struct House {
        bytes32 ticker;
        address chip;
        bool locked;
        uint64 epoch; // id of the queue that is filling now
        uint64 generation; // bumped when shares priced at 0 are voided by a new deposit
        uint256 lpAssets;
        uint256 endowment;
        uint256 totalShares;
        uint256 pendingDeposits;
        uint256 pendingShares;
        uint256 pendingDonations;
        uint256 claimableTotal;
        uint256 sent; // nominal chips sent to the running round, valid only while locked
    }

    /// @dev Conversion rates fixed when a queue is processed. A queued deposit of `a` mints
    ///      `a * mintShares / mintAssets` in `generation`; a queued withdrawal of `s` shares pays
    ///      `s * burnAssets / burnShares`.
    struct EpochRate {
        uint256 mintShares;
        uint256 mintAssets;
        uint256 burnAssets;
        uint256 burnShares;
        uint64 generation;
    }

    struct Request {
        uint256 amount;
        uint64 epoch;
    }

    /// @dev A lister's seed: these shares of `generation` stay with the owner until `until`.
    struct Lock {
        uint128 shares;
        uint64 until;
        uint64 generation;
    }

    /// @notice The only address that may pull and return round capital.
    address public immutable hook;
    /// @notice Decides which coins may be a chip.
    IChipGuard public immutable chipGuard;
    /// @notice Decides which tickers may have houses: the PitBook (a ticker whose registration is in force
    ///         and that the oracle supports).
    ITickerGate public immutable gate;

    /// @notice The only address that may create houses (PitLister: every house passes its anchor check).
    ///         Set once by the deployer with `setLister`; until then no house can be created.
    address public lister;
    /// @dev The account that deployed the vault: it may call `setLister` once.
    address internal immutable _deployer;

    /// @notice Chips the vault holds for all houses of `chip` by its own books.
    mapping(address chip => uint256) public accounted;

    mapping(bytes32 house => House) internal _houses;
    mapping(bytes32 house => mapping(uint64 epoch => EpochRate)) internal _rates;
    mapping(bytes32 house => mapping(address owner => Request)) internal _depositRequests;
    mapping(bytes32 house => mapping(address owner => Request)) internal _withdrawRequests;
    mapping(bytes32 house => mapping(address owner => uint256)) internal _claimable;
    mapping(bytes32 house => mapping(uint64 generation => mapping(address owner => uint256))) internal
        _balances;

    /// @dev Every house, in the order it was created. Anyone may create a house for a chip the guard
    ///      allows, so the list is read in pages (`houseIds`).
    bytes32[] internal _houseList;

    mapping(bytes32 house => mapping(address owner => Lock)) internal _locks;

    /// @notice ERC-6909 allowance of `spender` over `owner`'s shares of house `id`.
    mapping(address owner => mapping(address spender => mapping(uint256 id => uint256))) public allowance;
    /// @notice ERC-6909 operator approval.
    mapping(address owner => mapping(address spender => bool)) public isOperator;

    event HouseCreated(bytes32 indexed house, bytes32 indexed ticker, address indexed chip);
    event ListerSet(address lister);
    event SharesLocked(bytes32 indexed house, address indexed owner, uint256 shares, uint64 until);
    event Deposited(bytes32 indexed house, address indexed owner, uint256 assets, uint256 shares);
    event DepositQueued(bytes32 indexed house, address indexed owner, uint64 epoch, uint256 assets);
    event DepositCancelled(bytes32 indexed house, address indexed owner, uint64 epoch, uint256 assets);
    event Withdrawn(bytes32 indexed house, address indexed owner, uint256 shares, uint256 assets);
    event WithdrawQueued(bytes32 indexed house, address indexed owner, uint64 epoch, uint256 shares);
    event WithdrawProcessed(bytes32 indexed house, address indexed owner, uint64 epoch, uint256 assets);
    event Claimed(bytes32 indexed house, address indexed owner, uint256 assets);
    event Donated(bytes32 indexed house, address indexed from, uint256 assets, bool queued);
    event QueuesProcessed(
        bytes32 indexed house,
        uint64 epoch,
        uint256 depositAssets,
        uint256 sharesMinted,
        uint256 sharesBurned,
        uint256 assetsOut
    );
    event SharesVoided(bytes32 indexed house, uint64 generation, uint256 shares);
    event RoundCapitalPulled(bytes32 indexed house, address indexed to, uint256 sent);
    event RoundCapitalReturned(
        bytes32 indexed house, uint256 received, uint256 sent, uint256 lpAssets, uint256 endowment
    );
    event Transfer(
        address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount
    );
    event OperatorSet(address indexed owner, address indexed spender, bool approved);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

    error ZeroAddress();
    error OnlyHook();
    error OnlyLister();
    error OnlyDeployer();
    error ListerAlreadySet();
    /// @dev The owner's seed is locked: the move would leave fewer than the locked shares before the lock ends.
    error Locked(uint256 locked, uint64 until);
    error UnknownHouse();
    error HouseExists();
    error ChipNotAllowed();
    error TickerNotSupported();
    error HouseLocked();
    error HouseNotLocked();
    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares();
    error InsufficientPermission();
    error InvalidReceiver();
    error NothingToClaim();
    error NothingToCancel();
    error BalanceQueryFailed();
    /// @dev The chip delivered another amount than was sent (a transfer tax, a rebase): such a coin is not a chip.
    error InexactTransfer(uint256 sent, uint256 received);

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    /// @dev The caller may act for `owner`: `owner` itself, an ERC-6909 operator of `owner`, or the router
    ///      (`router()`, which checks the owner's session itself). Payouts still go only to `owner`.
    modifier onlyAgentOf(address owner) {
        if (owner == address(0) || owner == address(this)) revert InvalidReceiver();
        if (msg.sender != owner && !isOperator[owner][msg.sender] && msg.sender != router()) {
            revert InsufficientPermission();
        }
        _;
    }

    /// @param hook_ the Fallpit hook (its address is known before deployment, it is a CREATE2 address from a fixed salt)
    /// @param chipGuard_ the chip check used by `createHouse`
    /// @param gate_ the contract whose `supported` gates `createHouse` (the PitBook)
    constructor(address hook_, IChipGuard chipGuard_, ITickerGate gate_) {
        if (hook_ == address(0) || address(chipGuard_) == address(0) || address(gate_) == address(0)) {
            revert ZeroAddress();
        }
        hook = hook_;
        _deployer = msg.sender;
        chipGuard = chipGuard_;
        gate = gate_;
    }

    // ---------------------------------------------------------------------------------------------
    // Houses
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IPitVault
    function houseId(bytes32 ticker, address chip) public pure returns (bytes32) {
        return keccak256(abi.encode(ticker, chip));
    }

    /// @inheritdoc IPitVault
    function createHouse(bytes32 ticker, address chip) external returns (bytes32 house) {
        if (msg.sender != lister) revert OnlyLister();
        house = houseId(ticker, chip);
        if (_houses[house].chip != address(0)) revert HouseExists();
        (bool allowed,) = chipGuard.check(chip);
        if (!allowed) revert ChipNotAllowed();
        if (!gate.supported(ticker)) revert TickerNotSupported();
        House storage h = _houses[house];
        h.ticker = ticker;
        h.chip = chip;
        _houseList.push(house);
        emit HouseCreated(house, ticker, chip);
    }

    /// @inheritdoc IPitVault
    function setLister(address lister_) external {
        if (msg.sender != _deployer) revert OnlyDeployer();
        if (lister != address(0)) revert ListerAlreadySet();
        if (lister_ == address(0)) revert ZeroAddress();
        lister = lister_;
        emit ListerSet(lister_);
    }

    /// @inheritdoc IPitVault
    function depositLocked(bytes32 house, uint256 amount, address owner, uint64 until)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (msg.sender != lister) revert OnlyLister();
        if (owner == address(0) || owner == address(this)) revert InvalidReceiver();
        House storage h = _house(house);
        // A seed must become shares now: a queued deposit has none to lock.
        if (h.locked) revert HouseLocked();
        shares = _deposit(house, amount, owner);
        Lock storage l = _locks[house][owner];
        uint256 total = shares + (l.until > block.timestamp && l.generation == h.generation ? l.shares : 0);
        uint64 end = until > l.until ? until : l.until;
        _locks[house][owner] = Lock(uint128(total), end, h.generation);
        emit SharesLocked(house, owner, total, end);
    }

    /// @inheritdoc IPitVault
    function lockOf(bytes32 house, address owner) public view returns (uint256 shares, uint64 until) {
        Lock memory l = _locks[house][owner];
        if (l.until <= block.timestamp || l.generation != _houses[house].generation) return (0, 0);
        return (l.shares, l.until);
    }

    // ---------------------------------------------------------------------------------------------
    // LP functions
    // ---------------------------------------------------------------------------------------------

    /// @notice Adds chips to a house for shares. Executes now when the house is unlocked; while a round is
    ///         running the chips wait in the queue and mint at the share price after that round's result.
    /// @dev Reverts with `InexactTransfer` when the vault receives another amount than `amount`: a chip
    ///      that taxes its transfers cannot fund a house.
    /// @param amount chips to pull from the caller
    /// @return shares shares minted now (0 when the deposit was queued)
    function deposit(bytes32 house, uint256 amount) external nonReentrant returns (uint256 shares) {
        return _deposit(house, amount, msg.sender);
    }

    /// @notice Takes a deposit that is still waiting in the queue of a locked house back out.
    /// @dev A safety valve: a queued deposit has no exposure to the running round, so leaving is free.
    /// @return assets chips sent back
    function cancelDeposit(bytes32 house) external nonReentrant returns (uint256 assets) {
        return _cancelDeposit(house, msg.sender);
    }

    /// @notice Redeems shares for chips. Executes and pays now when the house is unlocked; while a round is
    ///         running the shares wait in the queue, still bear that round's result, burn at the share
    ///         price after it, and the chips are paid by `claim`.
    /// @param shares shares to redeem
    /// @return assets chips paid now (0 when the withdrawal was queued)
    function requestWithdraw(bytes32 house, uint256 shares) external nonReentrant returns (uint256 assets) {
        return _requestWithdraw(house, shares, msg.sender);
    }

    /// @notice Pays the caller's processed withdrawals.
    /// @return assets chips paid
    function claim(bytes32 house) external nonReentrant returns (uint256 assets) {
        return _claim(house, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // LP functions on behalf of an owner (router sessions, operators)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IPitVault
    function depositFor(bytes32 house, uint256 amount, address owner)
        external
        nonReentrant
        onlyAgentOf(owner)
        returns (uint256 shares)
    {
        return _deposit(house, amount, owner);
    }

    /// @inheritdoc IPitVault
    function cancelDepositFor(bytes32 house, address owner)
        external
        nonReentrant
        onlyAgentOf(owner)
        returns (uint256 assets)
    {
        return _cancelDeposit(house, owner);
    }

    /// @inheritdoc IPitVault
    function requestWithdrawFor(bytes32 house, uint256 shares, address owner)
        external
        nonReentrant
        onlyAgentOf(owner)
        returns (uint256 assets)
    {
        return _requestWithdraw(house, shares, owner);
    }

    /// @inheritdoc IPitVault
    function claimFor(bytes32 house, address owner)
        external
        nonReentrant
        onlyAgentOf(owner)
        returns (uint256 assets)
    {
        return _claim(house, owner);
    }

    /// @notice The router whose sessions may act for any owner: the router the hook pins (zero when the
    ///         hook does not name one).
    function router() public view returns (address r) {
        try IRouterOf(hook).router() returns (address r_) {
            r = r_;
        } catch {}
    }

    /// @inheritdoc IPitVault
    /// @dev While a round is running the donation joins the endowment when the round returns, so it has
    ///      no part in that round's result.
    function donate(bytes32 house, uint256 amount) external nonReentrant returns (uint256 credited) {
        House storage h = _house(house);
        credited = _pullIn(h.chip, amount);
        if (credited == 0) revert ZeroAmount();
        if (h.locked) h.pendingDonations += credited;
        else h.endowment += credited;
        emit Donated(house, msg.sender, credited, h.locked);
    }

    /// @notice Processes the queues of an unlocked house. Anyone may call it; `pullRoundCapital` and every
    ///         LP function do the same, so this only matters when no next round opens.
    function processQueues(bytes32 house) external nonReentrant {
        House storage h = _house(house);
        if (h.locked) revert HouseLocked();
        _processQueues(house, h);
    }

    /// @notice Books `owner`'s processed queue entries: minted shares to the ledger, burned shares to
    ///         claimable chips. Anyone may call it; it moves no chips.
    function settle(bytes32 house, address owner) external nonReentrant {
        House storage h = _house(house);
        if (!h.locked) _processQueues(house, h);
        _settle(house, h, owner);
    }

    // ---------------------------------------------------------------------------------------------
    // Round functions (hook only)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IPitVault
    function pullRoundCapital(bytes32 house, address to)
        external
        nonReentrant
        onlyHook
        returns (uint256 sent)
    {
        House storage h = _house(house);
        if (h.locked) revert HouseLocked();
        _processQueues(house, h);
        sent = h.lpAssets + h.endowment;
        h.locked = true;
        h.sent = sent;
        emit RoundCapitalPulled(house, to, sent);
        _payOut(h.chip, to, sent);
    }

    /// @inheritdoc IPitVault
    /// @dev The hook must transfer the chips and call this in the same transaction. What comes back,
    ///      profit or loss, is split between the shares and the endowment pro rata to their capital at
    ///      lock time (the shares' part rounded down). The endowment is ordinary capital that happens to
    ///      own no shares: it is never a first-loss cushion, because a cushion can be farmed by an LP who
    ///      bets against its own house. Never reverts on a zero or short return; it reverts only when the
    ///      chip's `balanceOf` itself fails, so a broken read is never booked as a loss.
    function returnRoundCapital(bytes32 house) external nonReentrant onlyHook returns (uint256 received) {
        House storage h = _house(house);
        if (!h.locked) revert HouseNotLocked();
        received = _sync(h.chip);
        uint256 sent = h.sent;
        // The shares keep their fraction of the capital, whatever the result; the endowment has the rest.
        uint256 lp = sent == 0 ? 0 : received.fullMulDiv(h.lpAssets, sent);
        uint256 endowment = received - lp;
        // Capital no share can claim joins the endowment: what is left when no shares exist, and the dust
        // left under a wiped out share supply (those shares then price at 0).
        if (lp != 0 && (h.totalShares == 0 || h.totalShares / MAX_SHARES_PER_ASSET > lp)) {
            endowment += lp;
            lp = 0;
        }
        endowment += h.pendingDonations;
        h.pendingDonations = 0;
        h.lpAssets = lp;
        h.endowment = endowment;
        h.locked = false;
        emit RoundCapitalReturned(house, received, sent, lp, endowment);
    }

    // ---------------------------------------------------------------------------------------------
    // Share ledger (ERC-6909 style, id = uint256(house))
    // ---------------------------------------------------------------------------------------------

    /// @notice Shares of house `id` held by `owner`. Shares waiting in the withdrawal queue and shares
    ///         minted for queued deposits that are not settled yet are held by the vault itself.
    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return _balances[bytes32(id)][_houses[bytes32(id)].generation][owner];
    }

    /// @notice All shares of house `id`.
    function totalSupply(uint256 id) external view returns (uint256) {
        return _houses[bytes32(id)].totalShares;
    }

    /// @notice Moves `amount` shares of house `id` from the caller to `receiver`.
    function transfer(address receiver, uint256 id, uint256 amount) external nonReentrant returns (bool) {
        _transfer(msg.sender, receiver, id, amount);
        return true;
    }

    /// @notice Moves `amount` shares of house `id` from `sender` to `receiver`, as operator or by allowance.
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        nonReentrant
        returns (bool)
    {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed < amount) revert InsufficientPermission();
            if (allowed != type(uint256).max) allowance[sender][msg.sender][id] = allowed - amount;
        }
        _transfer(sender, receiver, id, amount);
        return true;
    }

    /// @notice Lets `spender` move up to `amount` of the caller's shares of house `id`.
    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    /// @notice Lets `spender` move all of the caller's shares of every house, or revokes that. An operator
    ///         may also call `depositFor`, `cancelDepositFor`, `requestWithdrawFor` and `claimFor` for the
    ///         caller in every house (payouts always go to the caller).
    function setOperator(address spender, bool approved) external returns (bool) {
        isOperator[msg.sender][spender] = approved;
        emit OperatorSet(msg.sender, spender, approved);
        return true;
    }

    /// @notice ERC-165: ERC-6909 and ERC-165.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x0f632fb3 || interfaceId == 0x01ffc9a7;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IPitVault
    function roundCapital(bytes32 house) external view returns (uint256) {
        House storage h = _houses[house];
        if (h.chip == address(0) || h.locked) return 0;
        uint256 assetsOut =
            h.pendingShares.fullMulDiv(h.lpAssets + VIRTUAL_ASSETS, h.totalShares + VIRTUAL_SHARES);
        return h.lpAssets - assetsOut + h.pendingDeposits + h.endowment;
    }

    /// @inheritdoc IPitVault
    function isLocked(bytes32 house) external view returns (bool) {
        return _houses[house].locked;
    }

    /// @notice The full state of a house (all zero when it does not exist). `sent` is 0 while no round runs.
    function getHouse(bytes32 house) external view returns (House memory) {
        House memory h = _houses[house];
        if (!h.locked) h.sent = 0;
        return h;
    }

    /// @inheritdoc IPitVault
    function chipOf(bytes32 house) external view returns (address) {
        return _houses[house].chip;
    }

    /// @notice Number of houses created.
    function houseCount() external view returns (uint256) {
        return _houseList.length;
    }

    /// @notice Up to `count` house ids from position `start` of the creation order (fewer at the end).
    function houseIds(uint256 start, uint256 count) external view returns (bytes32[] memory ids) {
        uint256 n = _houseList.length;
        if (start > n) start = n;
        if (count > n - start) count = n - start;
        ids = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = _houseList[start + i];
        }
    }

    /// @notice Chips the vault holds for a house right now: everything except capital out in a round.
    function heldFor(bytes32 house) external view returns (uint256 held) {
        House storage h = _houses[house];
        held = h.pendingDeposits + h.pendingDonations + h.claimableTotal;
        if (!h.locked) held += h.lpAssets + h.endowment;
    }

    /// @notice Chips `shares` are worth at the current share price, rounded down.
    function convertToAssets(bytes32 house, uint256 shares) external view returns (uint256) {
        House storage h = _houses[house];
        return shares.fullMulDiv(h.lpAssets + VIRTUAL_ASSETS, h.totalShares + VIRTUAL_SHARES);
    }

    /// @notice Shares a deposit of `assets` would mint at the current share price, rounded down.
    function convertToShares(bytes32 house, uint256 assets) external view returns (uint256) {
        House storage h = _houses[house];
        if (h.lpAssets == 0) return assets * VIRTUAL_SHARES;
        return assets.fullMulDiv(h.totalShares + VIRTUAL_SHARES, h.lpAssets + VIRTUAL_ASSETS);
    }

    /// @notice Everything `owner` has in a house, with processed queue entries counted as settled.
    /// @return shares shares on the ledger plus shares minted for a processed deposit
    /// @return queuedAssets chips still waiting in the deposit queue
    /// @return queuedShares shares still waiting in the withdrawal queue
    /// @return claimable chips `claim` would pay
    function positionOf(bytes32 house, address owner)
        external
        view
        returns (uint256 shares, uint256 queuedAssets, uint256 queuedShares, uint256 claimable)
    {
        House storage h = _houses[house];
        shares = _balances[house][h.generation][owner];
        claimable = _claimable[house][owner];
        Request storage d = _depositRequests[house][owner];
        if (d.amount != 0) {
            if (d.epoch < h.epoch) {
                EpochRate storage r = _rates[house][d.epoch];
                if (r.generation == h.generation) shares += d.amount.fullMulDiv(r.mintShares, r.mintAssets);
            } else {
                queuedAssets = d.amount;
            }
        }
        Request storage w = _withdrawRequests[house][owner];
        if (w.amount != 0) {
            if (w.epoch < h.epoch) {
                EpochRate storage r = _rates[house][w.epoch];
                claimable += w.amount.fullMulDiv(r.burnAssets, r.burnShares);
            } else {
                queuedShares = w.amount;
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _house(bytes32 house) internal view returns (House storage h) {
        h = _houses[house];
        if (h.chip == address(0)) revert UnknownHouse();
    }

    /// @dev Chips pulled from the caller, shares (or the queued deposit) booked to `owner`.
    function _deposit(bytes32 house, uint256 amount, address owner) internal returns (uint256 shares) {
        House storage h = _house(house);
        uint256 credited = _pullIn(h.chip, amount);
        if (credited == 0) revert ZeroAmount();
        if (h.locked) {
            _settle(house, h, owner);
            Request storage r = _depositRequests[house][owner];
            r.amount += credited;
            r.epoch = h.epoch;
            h.pendingDeposits += credited;
            emit DepositQueued(house, owner, h.epoch, credited);
        } else {
            _processQueues(house, h);
            _settle(house, h, owner);
            if (h.lpAssets == 0 && h.totalShares != 0) _voidShares(house, h);
            shares = credited.fullMulDiv(h.totalShares + VIRTUAL_SHARES, h.lpAssets + VIRTUAL_ASSETS);
            if (shares == 0) revert ZeroShares();
            h.totalShares += shares;
            h.lpAssets += credited;
            _balances[house][h.generation][owner] += shares;
            emit Transfer(msg.sender, address(0), owner, uint256(house), shares);
            emit Deposited(house, owner, credited, shares);
        }
    }

    /// @dev `owner`'s queued deposit back to `owner`.
    function _cancelDeposit(bytes32 house, address owner) internal returns (uint256 assets) {
        House storage h = _house(house);
        Request storage r = _depositRequests[house][owner];
        assets = r.amount;
        if (!h.locked || assets == 0 || r.epoch != h.epoch) revert NothingToCancel();
        delete _depositRequests[house][owner];
        h.pendingDeposits -= assets;
        emit DepositCancelled(house, owner, h.epoch, assets);
        _payOut(h.chip, owner, assets);
    }

    /// @dev Redeems `owner`'s shares; chips paid now go to `owner`.
    function _requestWithdraw(bytes32 house, uint256 shares, address owner)
        internal
        returns (uint256 assets)
    {
        House storage h = _house(house);
        if (shares == 0) revert ZeroAmount();
        if (!h.locked) _processQueues(house, h);
        _settle(house, h, owner);
        mapping(address => uint256) storage bal = _balances[house][h.generation];
        if (bal[owner] < shares) revert InsufficientShares();
        _checkLock(house, owner, bal[owner] - shares);
        bal[owner] -= shares;
        if (h.locked) {
            bal[address(this)] += shares;
            Request storage r = _withdrawRequests[house][owner];
            r.amount += shares;
            r.epoch = h.epoch;
            h.pendingShares += shares;
            emit Transfer(msg.sender, owner, address(this), uint256(house), shares);
            emit WithdrawQueued(house, owner, h.epoch, shares);
        } else {
            assets = shares.fullMulDiv(h.lpAssets + VIRTUAL_ASSETS, h.totalShares + VIRTUAL_SHARES);
            h.totalShares -= shares;
            h.lpAssets -= assets;
            emit Transfer(msg.sender, owner, address(0), uint256(house), shares);
            emit Withdrawn(house, owner, shares, assets);
            _payOut(h.chip, owner, assets);
        }
    }

    /// @dev Pays `owner`'s processed withdrawals to `owner`.
    function _claim(bytes32 house, address owner) internal returns (uint256 assets) {
        House storage h = _house(house);
        if (!h.locked) _processQueues(house, h);
        _settle(house, h, owner);
        assets = _claimable[house][owner];
        if (assets == 0) revert NothingToClaim();
        _claimable[house][owner] = 0;
        h.claimableTotal -= assets;
        emit Claimed(house, owner, assets);
        _payOut(h.chip, owner, assets);
    }

    /// @dev Always the transient guard: every chain Fallpit runs on has Uniswap v4, which needs it too.
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    /// @dev Pulls `amount` from the caller and returns what arrived, which must be exactly `amount`: the
    ///      vault takes no chip that keeps a part of its transfers (or adds to them). The books are still
    ///      credited with the measured difference, never with the argument. Chips sent to the vault outside
    ///      a vault call are not credited here; they are booked by the next `returnRoundCapital` of that
    ///      chip.
    function _pullIn(address chip, uint256 amount) internal returns (uint256 credited) {
        uint256 before = _balanceOf(chip);
        SafeTransferLib.safeTransferFrom(chip, msg.sender, address(this), amount);
        uint256 afterBalance = _balanceOf(chip);
        credited = afterBalance > before ? afterBalance - before : 0;
        if (credited != amount) revert InexactTransfer(amount, credited);
        accounted[chip] += credited;
    }

    /// @dev Credits everything the vault holds of `chip` above its books.
    function _sync(address chip) internal returns (uint256 credited) {
        uint256 balance = _balanceOf(chip);
        uint256 booked = accounted[chip];
        if (balance > booked) {
            credited = balance - booked;
            accounted[chip] = balance;
        }
    }

    /// @dev The vault's balance of `chip`. A failed read reverts: booking it as zero would turn a chip's
    ///      hiccup into a permanent loss for the house.
    function _balanceOf(address chip) internal view returns (uint256 balance) {
        bool ok;
        (ok, balance) = SafeTransferLib.checkBalanceOf(chip, address(this));
        if (!ok) revert BalanceQueryFailed();
    }

    /// @dev Sends the nominal amount. Should a chip start to tax its transfers after it was let in, the
    ///      receiver gets less; the books are unaffected.
    function _payOut(address chip, address to, uint256 amount) internal {
        if (amount == 0) return;
        accounted[chip] -= amount;
        SafeTransferLib.safeTransfer(chip, to, amount);
    }

    /// @dev Reverts when `owner` would keep `left` shares, fewer than its seed lock holds.
    function _checkLock(bytes32 house, address owner, uint256 left) internal view {
        (uint256 locked, uint64 until) = lockOf(house, owner);
        if (left < locked) revert Locked(locked, until);
    }

    /// @dev Shares priced at 0 (their capital was lost) end here, when new capital arrives.
    function _voidShares(bytes32 house, House storage h) internal {
        emit SharesVoided(house, h.generation, h.totalShares);
        h.generation += 1;
        h.totalShares = 0;
    }

    /// @dev Executes the queue of an unlocked house at one share price: withdrawals burn and become
    ///      claimable, deposits mint. Both use the price before either, so neither moves it.
    function _processQueues(bytes32 house, House storage h) internal {
        uint256 depositAssets = h.pendingDeposits;
        uint256 burnShares = h.pendingShares;
        if (depositAssets == 0 && burnShares == 0) return;

        uint64 epoch = h.epoch;
        EpochRate storage rate = _rates[house][epoch];
        uint256 assets1 = h.lpAssets + VIRTUAL_ASSETS;
        uint256 shares1 = h.totalShares + VIRTUAL_SHARES;
        uint256 assetsOut;
        uint256 minted;

        if (burnShares != 0) {
            assetsOut = burnShares.fullMulDiv(assets1, shares1);
            rate.burnAssets = assets1;
            rate.burnShares = shares1;
            _balances[house][h.generation][address(this)] -= burnShares;
            h.totalShares -= burnShares;
            h.lpAssets -= assetsOut;
            h.claimableTotal += assetsOut;
            h.pendingShares = 0;
            emit Transfer(address(this), address(this), address(0), uint256(house), burnShares);
        }
        if (depositAssets != 0) {
            if (assets1 == VIRTUAL_ASSETS) {
                // No capital behind the shares: whatever is left of them is void and the deposits
                // start a fresh supply at the opening price.
                if (h.totalShares != 0) _voidShares(house, h);
                shares1 = VIRTUAL_SHARES;
            }
            minted = depositAssets.fullMulDiv(shares1, assets1);
            rate.mintShares = shares1;
            rate.mintAssets = assets1;
            rate.generation = h.generation;
            _balances[house][h.generation][address(this)] += minted;
            h.totalShares += minted;
            h.lpAssets += depositAssets;
            h.pendingDeposits = 0;
            emit Transfer(address(this), address(0), address(this), uint256(house), minted);
        }
        h.epoch = epoch + 1;
        emit QueuesProcessed(house, epoch, depositAssets, minted, burnShares, assetsOut);
    }

    /// @dev Books `owner`'s entries of queues that were already processed.
    function _settle(bytes32 house, House storage h, address owner) internal {
        Request storage d = _depositRequests[house][owner];
        if (d.amount != 0 && d.epoch < h.epoch) {
            EpochRate storage r = _rates[house][d.epoch];
            uint256 shares = d.amount.fullMulDiv(r.mintShares, r.mintAssets);
            emit Deposited(house, owner, d.amount, shares);
            delete _depositRequests[house][owner];
            if (shares != 0) {
                mapping(address => uint256) storage bal = _balances[house][r.generation];
                bal[address(this)] -= shares;
                bal[owner] += shares;
                emit Transfer(msg.sender, address(this), owner, uint256(house), shares);
            }
        }
        Request storage w = _withdrawRequests[house][owner];
        if (w.amount != 0 && w.epoch < h.epoch) {
            EpochRate storage r = _rates[house][w.epoch];
            uint256 assets = w.amount.fullMulDiv(r.burnAssets, r.burnShares);
            delete _withdrawRequests[house][owner];
            _claimable[house][owner] += assets;
            emit WithdrawProcessed(house, owner, w.epoch, assets);
        }
    }

    function _transfer(address sender, address receiver, uint256 id, uint256 amount) internal {
        if (receiver == address(0) || receiver == address(this)) revert InvalidReceiver();
        bytes32 house = bytes32(id);
        House storage h = _houses[house];
        _settle(house, h, sender);
        mapping(address => uint256) storage bal = _balances[house][h.generation];
        if (bal[sender] < amount) revert InsufficientShares();
        _checkLock(house, sender, bal[sender] - amount);
        bal[sender] -= amount;
        bal[receiver] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
    }
}
