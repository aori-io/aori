// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Order, OrderStatus, Balance } from "../../types/AoriTypes.sol";
import "../../types/AoriErrors.sol";
import { AoriStorageData } from "../../storage/AoriStorage.sol";
import { NativeTokenUtils } from "../internal/NativeTokenUtils.sol";

/**
 * @title AoriAdminLib
 * @notice External library containing admin logic for the Aori protocol
 * @dev Functions are called via DELEGATECALL, running in Aori's storage context.
 *      This saves bytecode in the main Aori contract.
 */
library AoriAdminLib {
    using SafeERC20 for IERC20;
    using NativeTokenUtils for address;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    address constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AORI_STORAGE_LOCATION = 0x476c06ce9bda338755e203b7f327971f808163bb891bef1bf37f35e88d0aae00;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Cancel(bytes32 indexed orderId);
    event Withdraw(address indexed holder, address indexed token, uint256 amount);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    STORAGE ACCESSOR                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getAoriStorage() private pure returns (AoriStorageData storage $) {
        assembly {
            $.slot := AORI_STORAGE_LOCATION
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   EMERGENCY FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emergency function to cancel an order, bypassing normal restrictions
     * @param orderId The hash of the order to cancel
     * @param recipient The address to send tokens to
     * @param endpointId The endpoint ID of this chain (passed from Aori)
     */
    function emergencyCancel(
        bytes32 orderId,
        address recipient,
        uint32 endpointId
    ) external {
        AoriStorageData storage $ = _getAoriStorage();

        if ($.orderStatus[orderId] != OrderStatus.Active) revert CanOnlyCancelActiveOrders();
        if (recipient == address(0)) revert InvalidRecipient();

        Order memory order = $.orders[orderId];
        if (order.srcEid != endpointId) revert EmergencyCancelOnlyAllowedOnSourceChain();

        address tokenAddress = order.inputToken;
        uint128 amountToReturn = order.inputAmount;

        // Validate sufficient balance
        tokenAddress.validateSufficientBalance(amountToReturn);

        // Update state
        $.orderStatus[orderId] = OrderStatus.Cancelled;
        $.balances[order.offerer][tokenAddress].locked -= amountToReturn;

        // Transfer tokens to recipient
        _transfer(tokenAddress, recipient, amountToReturn);

        emit Cancel(orderId);
        emit Withdraw(recipient, tokenAddress, amountToReturn);
    }

    /**
     * @notice Emergency function to extract tokens or ether from the contract
     * @param token The token address to withdraw (use NATIVE_TOKEN for ETH)
     * @param amount The amount to withdraw
     * @param recipient The address to send tokens to
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external {
        if (recipient == address(0)) revert InvalidRecipient();
        _transfer(token, recipient, amount);
        emit Withdraw(recipient, token, amount);
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
    ) external {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (user == address(0)) revert InvalidUserAddress();
        if (recipient == address(0)) revert InvalidRecipient();

        AoriStorageData storage $ = _getAoriStorage();

        // Update balances
        if (isLocked) {
            uint128 currentLocked = $.balances[user][token].locked;
            if (currentLocked < amount) revert LockedBalanceDecreaseFailed(uint128(amount), currentLocked);
            $.balances[user][token].locked = currentLocked - uint128(amount);
        } else {
            uint256 unlockedBalance = $.balances[user][token].unlocked;
            if (unlockedBalance < amount) revert InsufficientUnlockedBalance();
            $.balances[user][token].unlocked = uint128(unlockedBalance - amount);
        }

        // Transfer tokens
        _transfer(token, recipient, amount);
        emit Withdraw(user, token, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTERNAL HELPERS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _transfer(
        address token,
        address to,
        uint256 amount
    ) private {
        if (token == NATIVE_TOKEN) {
            (bool success,) = payable(to).call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
