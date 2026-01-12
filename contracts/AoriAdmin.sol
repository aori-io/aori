// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IAoriAdmin
 * @notice Minimal interface for Aori admin functions
 */
interface IAoriAdmin {
    function orders(
        bytes32 orderId
    )
        external
        view
        returns (
            uint128 inputAmount,
            uint128 outputAmount,
            address inputToken,
            address outputToken,
            uint32 startTime,
            uint32 endTime,
            uint32 srcEid,
            uint32 dstEid,
            address offerer,
            address recipient
        );
    function orderStatus(
        bytes32 orderId
    ) external view returns (uint8);
    function ENDPOINT_ID() external view returns (uint32);
    function owner() external view returns (address);

    // Low-level admin setters (only callable by owner)
    function adminSetOrderCancelled(
        bytes32 orderId
    ) external;
    function adminDecreaseLockedBalance(
        address user,
        address token,
        uint128 amount
    ) external;
    function adminDecreaseUnlockedBalance(
        address user,
        address token,
        uint128 amount
    ) external;
    function adminSetAllowedHook(
        address hook,
        bool allowed
    ) external;
    function adminSetAllowedSolver(
        address solver,
        bool allowed
    ) external;
    function adminSetSupportedChain(
        uint32 eid,
        bool supported
    ) external;
    function adminSetMaxFillsPerSettle(
        uint16 maxFills
    ) external;
    function pause() external;
    function unpause() external;
}

/**
 * @title AoriAdmin
 * @notice Admin contract for Aori protocol - contains complex admin logic
 * @dev This contract should be set as the owner of the Aori contract.
 *      The actual admin (multisig/EOA) owns this contract.
 */
contract AoriAdmin is Ownable {
    using SafeERC20 for IERC20;

    IAoriAdmin public immutable aori;

    // Order status enum matching Aori
    uint8 constant STATUS_UNKNOWN = 0;
    uint8 constant STATUS_ACTIVE = 1;
    uint8 constant STATUS_FILLED = 2;
    uint8 constant STATUS_CANCELLED = 3;
    uint8 constant STATUS_SETTLED = 4;

    address constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    error CanOnlyCancelActiveOrders();
    error InvalidRecipient();
    error EmergencyCancelOnlyAllowedOnSourceChain();
    error AmountMustBeGreaterThanZero();
    error InvalidUserAddress();
    error NativeTransferFailed();
    error InsufficientContractBalance();

    event EmergencyCancel(bytes32 indexed orderId, address indexed recipient);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed recipient);
    event EmergencyWithdrawFromUser(address indexed user, address indexed token, uint256 amount, address indexed recipient);

    constructor(
        address _aori,
        address _owner
    ) Ownable(_owner) {
        aori = IAoriAdmin(_aori);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    EMERGENCY FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emergency function to cancel an order, bypassing normal restrictions
     * @param orderId The hash of the order to cancel
     * @param recipient The address to send tokens to
     */
    function emergencyCancel(
        bytes32 orderId,
        address recipient
    ) external onlyOwner {
        if (aori.orderStatus(orderId) != STATUS_ACTIVE) revert CanOnlyCancelActiveOrders();
        if (recipient == address(0)) revert InvalidRecipient();

        (uint128 inputAmount,, address inputToken,,,, uint32 srcEid,, address offerer,) = aori.orders(orderId);

        if (srcEid != aori.ENDPOINT_ID()) revert EmergencyCancelOnlyAllowedOnSourceChain();

        // Update state via Aori's low-level setters
        aori.adminSetOrderCancelled(orderId);
        aori.adminDecreaseLockedBalance(offerer, inputToken, inputAmount);

        // Transfer tokens to recipient
        if (inputToken == NATIVE_TOKEN) {
            (bool success,) = payable(recipient).call{ value: inputAmount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(inputToken).safeTransferFrom(address(aori), recipient, inputAmount);
        }

        emit EmergencyCancel(orderId, recipient);
    }

    /**
     * @notice Emergency function to extract tokens or ether from the contract
     * @param token The token address to withdraw (use NATIVE_TOKEN for ETH)
     * @param amount The amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyOwner {
        address recipient = owner();

        if (token == NATIVE_TOKEN) {
            (bool success,) = payable(recipient).call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else if (amount > 0) {
            IERC20(token).safeTransferFrom(address(aori), recipient, amount);
        }

        emit EmergencyWithdraw(token, amount, recipient);
    }

    /**
     * @notice Emergency function to extract tokens from a user's balance
     * @param token The token address to withdraw
     * @param amount The amount to withdraw
     * @param user The user address whose balance to withdraw from
     * @param isLocked Whether to withdraw from locked or unlocked balance
     * @param recipient The address to send tokens to
     */
    function emergencyWithdrawFromUser(
        address token,
        uint256 amount,
        address user,
        bool isLocked,
        address recipient
    ) external onlyOwner {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (user == address(0)) revert InvalidUserAddress();
        if (recipient == address(0)) revert InvalidRecipient();

        // Update balances via Aori's low-level setters
        if (isLocked) {
            aori.adminDecreaseLockedBalance(user, token, uint128(amount));
        } else {
            aori.adminDecreaseUnlockedBalance(user, token, uint128(amount));
        }

        // Transfer tokens
        if (token == NATIVE_TOKEN) {
            (bool success,) = payable(recipient).call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransferFrom(address(aori), recipient, amount);
        }

        emit EmergencyWithdrawFromUser(user, token, amount, recipient);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    PASSTHROUGH FUNCTIONS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function pause() external onlyOwner {
        aori.pause();
    }

    function unpause() external onlyOwner {
        aori.unpause();
    }

    function addAllowedHook(
        address hook
    ) external onlyOwner {
        aori.adminSetAllowedHook(hook, true);
    }

    function removeAllowedHook(
        address hook
    ) external onlyOwner {
        aori.adminSetAllowedHook(hook, false);
    }

    function addAllowedSolver(
        address solver
    ) external onlyOwner {
        aori.adminSetAllowedSolver(solver, true);
    }

    function removeAllowedSolver(
        address solver
    ) external onlyOwner {
        aori.adminSetAllowedSolver(solver, false);
    }

    function addSupportedChain(
        uint32 eid
    ) external onlyOwner {
        aori.adminSetSupportedChain(eid, true);
    }

    function removeSupportedChain(
        uint32 eid
    ) external onlyOwner {
        aori.adminSetSupportedChain(eid, false);
    }

    function setMaxFillsPerSettle(
        uint16 maxFills
    ) external onlyOwner {
        aori.adminSetMaxFillsPerSettle(maxFills);
    }

    /// @notice Receive ETH for emergency withdrawals
    receive() external payable { }
}
