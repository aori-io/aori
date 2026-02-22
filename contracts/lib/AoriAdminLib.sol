// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Order, OrderStatus, Balance } from "../types/AoriTypes.sol";
import "../types/AoriErrors.sol";
import { AoriStorageData } from "../AoriStorage.sol";
import { TokenUtils } from "../utils/TokenUtils.sol";
import { IAori } from "../interfaces/IAori.sol";

/**
 * @title AoriAdminLib
 * @notice External library containing admin logic for the Aori protocol
 * @dev Functions are called via DELEGATECALL, running in Aori's storage context.
 *      This saves bytecode in the main Aori contract.
 */
library AoriAdminLib {
    using SafeERC20 for IERC20;
    using TokenUtils for address;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    address constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AORI_STORAGE_LOCATION = 0x476c06ce9bda338755e203b7f327971f808163bb891bef1bf37f35e88d0aae00;

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
    function emergencyCancel(bytes32 orderId, address recipient, uint32 endpointId) external {
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

        emit IAori.Cancel(orderId);
        emit IAori.Withdraw(recipient, tokenAddress, amountToReturn);
    }

    /**
     * @notice Emergency function to extract tokens or ether from the contract
     * @param token The token address to withdraw (use NATIVE_TOKEN for ETH)
     * @param amount The amount to withdraw
     * @param recipient The address to send tokens to
     */
    function emergencyWithdraw(address token, uint256 amount, address recipient) external {
        if (recipient == address(0)) revert InvalidRecipient();
        _transfer(token, recipient, amount);
        emit IAori.Withdraw(recipient, token, amount);
    }

    // TODO: Rename this function
    /**
     * @notice Emergency function to extract tokens from a user's balance
     * @param token The token address to withdraw
     * @param amount The amount to withdraw
     * @param user The user address whose balance to withdraw from
     * @param isLocked Whether to withdraw from locked or unlocked balance
     * @param recipient The address to send tokens to
     */
    function emergencyWithdrawFromUser(address token, uint256 amount, address user, bool isLocked, address recipient) external {
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
        emit IAori.Withdraw(user, token, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   PROTOCOL FEE FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Sets the protocol fee (governance controlled, no cap)
    /// @param feeMbps Fee in millibasis points
    function setProtocolFee(
        uint16 feeMbps
    ) external {
        AoriStorageData storage $ = _getAoriStorage();
        // Ensure protocol + max additional fee never exceeds 100%
        if (uint256(feeMbps) + uint256($.maxFeeMbps) > 100_000) revert CombinedFeesTooHigh();
        $.protocolFeeMbps = feeMbps;
        emit IAori.ProtocolFeeUpdated(feeMbps);
    }

    /// @notice Sets the protocol treasury address
    /// @param treasury Address to receive protocol fees (can be EOA, multisig, DAO, or revenue-sharing contract)
    function setProtocolTreasury(
        address treasury
    ) external {
        if (treasury == address(0)) revert InvalidProtocolTreasury();
        AoriStorageData storage $ = _getAoriStorage();
        $.protocolTreasury = treasury;
        emit IAori.ProtocolTreasuryUpdated(treasury);
    }

    /// @notice Returns current protocol fee configuration
    function getProtocolConfig() external view returns (uint16 feeMbps, address treasury) {
        AoriStorageData storage $ = _getAoriStorage();
        return ($.protocolFeeMbps, $.protocolTreasury);
    }

    /// @notice Returns pending protocol fees for a token
    function getPendingProtocolFees(
        address token
    ) external view returns (uint256) {
        return _getAoriStorage().pendingProtocolFees[token];
    }

    /// @notice Sets the maximum allowed additional fee
    /// @param maxFeeMbps Maximum fee in millibasis points
    function setMaxFee(
        uint16 maxFeeMbps
    ) external {
        AoriStorageData storage $ = _getAoriStorage();
        // Ensure protocol + max additional fee never exceeds 100%
        if (uint256($.protocolFeeMbps) + uint256(maxFeeMbps) > 100_000) revert CombinedFeesTooHigh();
        $.maxFeeMbps = maxFeeMbps;
        emit IAori.MaxFeeUpdated(maxFeeMbps);
    }

    /// @notice Returns the current maximum allowed additional fee
    function getMaxFee() external view returns (uint16) {
        return _getAoriStorage().maxFeeMbps;
    }

    /// @notice Sets the maximum fills per settle batch
    /// @param maxFills New maximum fills per settle
    function setMaxFillsPerSettle(
        uint16 maxFills
    ) external {
        if (maxFills == 0) revert AmountMustBeGreaterThanZero();
        _getAoriStorage().maxFillsPerSettle = maxFills;
        emit IAori.MaxFillsPerSettleSet(maxFills);
    }

    /// @notice Returns the current maximum fills per settle
    function getMaxFillsPerSettle() external view returns (uint16) {
        return _getAoriStorage().maxFillsPerSettle;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   CLAIM PROTOCOL FEES                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Claims accumulated protocol fees for a token
    /// @dev Permissionless - anyone can trigger, but funds always go to treasury
    function claimProtocolFees(
        address token
    ) external {
        AoriStorageData storage $ = _getAoriStorage();

        uint256 amount = $.pendingProtocolFees[token];
        if (amount == 0) revert NoPendingFees();

        address treasury = $.protocolTreasury;
        if (treasury == address(0)) revert InvalidProtocolTreasury();

        // Clear pending before transfer
        $.pendingProtocolFees[token] = 0;

        // Direct transfer to treasury
        _transfer(token, treasury, amount);

        emit IAori.ProtocolFeesClaimed(token, amount, treasury);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         WITHDRAW                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Allows users to withdraw their unlocked token balances
     * @param token The token address to withdraw
     * @param amount The amount to withdraw (use 0 to withdraw full balance)
     * @param holder The address of the user withdrawing
     */
    function withdraw(address token, uint256 amount, address holder) external {
        AoriStorageData storage $ = _getAoriStorage();
        uint256 unlockedBalance = $.balances[holder][token].unlocked;
        if (unlockedBalance == 0) revert NonZeroBalanceRequired();

        // Default to full balance if amount is 0
        if (amount == 0) {
            amount = unlockedBalance;
        } else {
            if (unlockedBalance < amount) revert InsufficientUnlockedBalance();
        }

        token.validateSufficientBalance(amount);

        // Update balance
        $.balances[holder][token].unlocked = SafeCast.toUint128(unlockedBalance - amount);

        // Transfer tokens to user
        token.safeTransfer(holder, amount);
        emit IAori.Withdraw(holder, token, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTERNAL HELPERS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _transfer(address token, address to, uint256 amount) private {
        if (token == NATIVE_TOKEN) {
            (bool success,) = payable(to).call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
