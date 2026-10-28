// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IPitVault} from "./interfaces/IPitVault.sol";

/// @notice The part of Doppler's `FeesManager` the treasury uses (`PoolId` is `bytes32`, `Currency` is
///         `address`, zero for the native coin).
interface IDopplerFeesManager {
    /// @notice Collects the pool's fees and pays the caller's share to the caller, when it is a beneficiary.
    function collectFees(bytes32 poolId) external returns (uint128 fees0, uint128 fees1);

    /// @notice The pool key stored for `poolId`.
    function getPoolKey(bytes32 poolId)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
}

/// @title PitFeeInbox
/// @notice The address a community sets as its launchpad fee beneficiary: one per house, so the choice of
///         inbox is the choice of house. It only obeys the CommunityTreasury that deployed it.
contract PitFeeInbox {
    /// @notice The CommunityTreasury that deployed this inbox.
    address public immutable treasury;

    error OnlyTreasury();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert OnlyTreasury();
        _;
    }

    constructor() {
        treasury = msg.sender;
    }

    /// @dev Pools paired with the native coin pay that leg here.
    receive() external payable {}

    /// @notice Calls `collectFees(poolId)` as the beneficiary.
    function collect(address feesManager, bytes32 poolId) external onlyTreasury {
        IDopplerFeesManager(feesManager).collectFees(poolId);
    }

    /// @notice Donates this inbox's whole balance of `chip` to `house`.
    /// @return credited chips the vault booked
    function donate(address vault, bytes32 house, address chip)
        external
        onlyTreasury
        returns (uint256 credited)
    {
        uint256 balance = SafeTransferLib.balanceOf(chip, address(this));
        if (balance == 0) return 0;
        SafeTransferLib.safeApproveWithRetry(chip, vault, balance);
        credited = IPitVault(vault).donate(house, balance);
    }

    /// @notice Sends `amount` of `token` (zero for the native coin) to `to`.
    function release(address token, address to, uint256 amount) external onlyTreasury {
        if (token == address(0)) SafeTransferLib.safeTransferETH(to, amount);
        else SafeTransferLib.safeTransfer(token, to, amount);
    }
}

/// @title CommunityTreasury
/// @notice Lets a coin's community route its launchpad fees into its house. See contracts/SPEC.md section 6
///         and src/vault/DESIGN.md.
/// @dev Each house has one inbox at a fixed address (`inboxOf`). A Doppler beneficiary points its shares at
///      that inbox with `updateBeneficiary(poolId, inbox)`, or the inbox is listed as a beneficiary at launch.
///      `harvest` is permissionless: the inbox collects, its whole chip balance is donated to the house's
///      endowment, and the other leg (the stock token) stays in the inbox. Chips that reach an inbox by any
///      other path (a release during `updateBeneficiary`, a push from a fee hook, a plain transfer) are
///      donated the same way. Nobody, including the owner, can move the chip leg anywhere but the house.
contract CommunityTreasury is Ownable, ReentrancyGuardTransient {
    /// @notice The vault that receives the donations.
    IPitVault public immutable vault;

    bytes32 internal immutable INBOX_CODE_HASH;

    event InboxCreated(bytes32 indexed house, address inbox);
    event Harvested(
        bytes32 indexed house,
        address indexed feesManager,
        bytes32 indexed poolId,
        address chip,
        uint256 chipDonated,
        address otherToken,
        uint256 otherHeld
    );
    event Swept(bytes32 indexed house, address chip, uint256 chipDonated);
    event OtherLegReleased(bytes32 indexed house, address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error UnknownHouse();
    error ChipNotInPool();
    error ChipLegLocked();

    /// @param vault_ the PitVault
    /// @param owner_ the address that may release the non-chip leg (a later decision)
    constructor(address vault_, address owner_) {
        if (vault_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        vault = IPitVault(vault_);
        INBOX_CODE_HASH = keccak256(type(PitFeeInbox).creationCode);
        _initializeOwner(owner_);
    }

    /// @notice The fee inbox of `house`: the address to set as the fee beneficiary. It is the same before
    ///         and after the inbox is deployed.
    function inboxOf(bytes32 house) public view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), house, INBOX_CODE_HASH))))
        );
    }

    /// @notice Deploys the inbox of an existing house. `harvest` and `sweep` do it on first use.
    function createInbox(bytes32 house) external nonReentrant returns (address inbox) {
        _chipOf(house);
        inbox = _inbox(house);
    }

    /// @notice Collects the Doppler fees of `poolId` for the house's inbox and donates the chip leg to the
    ///         house. Anyone may call it.
    /// @dev The inbox only receives fees when it is a beneficiary of that pool. `feesManager` is not
    ///      trusted: whatever it does, chips can only move from the inbox into the house.
    /// @param feesManager the Doppler contract that manages the pool's fees (an initializer or a locker)
    /// @param poolId the Uniswap v4 pool id
    /// @param house the house whose inbox is the beneficiary
    /// @return chipDonated chips the vault booked for the endowment
    /// @return otherHeld amount of the other pool token that arrived and stays in the inbox
    function harvest(address feesManager, bytes32 poolId, bytes32 house)
        external
        nonReentrant
        returns (uint256 chipDonated, uint256 otherHeld)
    {
        address chip = _chipOf(house);
        (address currency0, address currency1,,,) = IDopplerFeesManager(feesManager).getPoolKey(poolId);
        address other;
        if (currency0 == chip) other = currency1;
        else if (currency1 == chip) other = currency0;
        else revert ChipNotInPool();

        address inbox = _inbox(house);
        uint256 otherBefore = _balance(other, inbox);
        PitFeeInbox(payable(inbox)).collect(feesManager, poolId);
        uint256 otherAfter = _balance(other, inbox);
        otherHeld = otherAfter > otherBefore ? otherAfter - otherBefore : 0;
        chipDonated = PitFeeInbox(payable(inbox)).donate(address(vault), house, chip);
        emit Harvested(house, feesManager, poolId, chip, chipDonated, other, otherHeld);
    }

    /// @notice Donates whatever chips sit in the house's inbox to the house. Anyone may call it.
    /// @return chipDonated chips the vault booked for the endowment
    function sweep(bytes32 house) external nonReentrant returns (uint256 chipDonated) {
        address chip = _chipOf(house);
        chipDonated = PitFeeInbox(payable(_inbox(house))).donate(address(vault), house, chip);
        emit Swept(house, chip, chipDonated);
    }

    /// @notice Owner only. Moves a token that is not the house's chip out of the house's inbox (the stock
    ///         token leg, kept for a later decision). The chip leg cannot be moved this way.
    /// @param token the token to move, zero for the native coin
    function releaseOtherLeg(bytes32 house, address token, address to, uint256 amount)
        external
        nonReentrant
        onlyOwner
    {
        if (to == address(0)) revert ZeroAddress();
        if (token == _chipOf(house)) revert ChipLegLocked();
        PitFeeInbox(payable(_inbox(house))).release(token, to, amount);
        emit OtherLegReleased(house, token, to, amount);
    }

    function _chipOf(bytes32 house) internal view returns (address chip) {
        chip = vault.chipOf(house);
        if (chip == address(0)) revert UnknownHouse();
    }

    function _inbox(bytes32 house) internal returns (address inbox) {
        inbox = inboxOf(house);
        if (inbox.code.length == 0) {
            new PitFeeInbox{salt: house}();
            emit InboxCreated(house, inbox);
        }
    }

    function _balance(address token, address account) internal view returns (uint256) {
        return token == address(0) ? account.balance : SafeTransferLib.balanceOf(token, account);
    }

    /// @dev Always the transient guard: every chain Fallpit runs on has Uniswap v4, which needs it too.
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
