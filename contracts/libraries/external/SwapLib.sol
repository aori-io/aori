// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Order, OrderStatus, Balance, SrcHook } from "../../types/AoriTypes.sol";
import { AoriStorageData } from "../../storage/AoriStorage.sol";
import { ExecutionUtils } from "../internal/ExecutionUtils.sol";
import { ValidationUtils } from "../internal/ValidationUtils.sol";
import { TokenUtils } from "../internal/TokenUtils.sol";
import "../../types/AoriErrors.sol";

/**
 * @title SwapLib
 * @notice External library containing atomic swap logic for single-chain orders
 * @dev Functions are called via DELEGATECALL, running in Aori's storage context.
 */
library SwapLib {
    using SafeERC20 for IERC20;
    using TokenUtils for address;

    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AORI_STORAGE_LOCATION = 0x476c06ce9bda338755e203b7f327971f808163bb891bef1bf37f35e88d0aae00;

    event Swap(bytes32 indexed orderId, Order order, uint256 amountReceived);

    function _getAoriStorage() private pure returns (AoriStorageData storage $) {
        assembly {
            $.slot := AORI_STORAGE_LOCATION
        }
    }

    /**
     * @notice Core swap execution logic shared by all swap variants
     * @dev Executes hook, validates output, distributes tokens, updates state
     * @param orderId The computed order hash
     * @param order The order details
     * @param hook The source hook for token conversion
     * @param solver The solver address (for surplus distribution)
     * @return amountReceived The amount of output tokens received from hook
     */
    function executeSwap(
        bytes32 orderId,
        Order calldata order,
        SrcHook calldata hook,
        address solver
    ) external returns (uint256 amountReceived) {
        AoriStorageData storage $ = _getAoriStorage();

        // Execute hook - converts input to output
        amountReceived = ExecutionUtils.observeBalChg(hook.hookAddress, hook.instructions, order.outputToken);

        if (amountReceived < order.outputAmount) {
            revert InsufficientSrcHookOutput(order.outputAmount, amountReceived);
        }

        // Calculate both fees
        // Fee calculations use uint128 - safe because fee validations ensure totalFee <= outputAmount
        uint128 protocolFee = uint128((uint256(order.outputAmount) * $.protocolFeeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 additionalFee = uint128((uint256(order.outputAmount) * order.options.feeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 totalFee = protocolFee + additionalFee;
        uint128 recipientAmount = order.outputAmount - totalFee;
        uint256 surplus = amountReceived - order.outputAmount;

        // Recipient gets output minus fees (immediate transfer)
        order.outputToken.safeTransfer(order.recipient, recipientAmount);

        // Protocol fee - lazy accrual with overflow protection
        if (protocolFee > 0) {
            uint256 current = $.pendingProtocolFees[order.outputToken];
            unchecked {
                uint256 newAmount = current + protocolFee;
                if (newAmount >= current) {
                    $.pendingProtocolFees[order.outputToken] = newAmount;
                }
            }
        }

        // Additional fee accrues to feeRecipient (or solver if address(0))
        if (additionalFee > 0) {
            address actualFeeRecipient = order.options.feeRecipient == address(0) ? solver : order.options.feeRecipient;
            $.balances[actualFeeRecipient][order.outputToken].unlocked += additionalFee;
        }

        // Surplus accrues to solver
        if (surplus > 0) {
            $.balances[solver][order.outputToken].unlocked += SafeCast.toUint128(surplus);
        }

        // Update state
        $.orders[orderId] = order;
        $.orderStatus[orderId] = OrderStatus.Settled;

        // Emit event
        emit Swap(orderId, order, amountReceived);
    }
}
