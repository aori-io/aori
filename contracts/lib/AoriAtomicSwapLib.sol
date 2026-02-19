// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Order, OrderStatus, SrcHook } from "../types/AoriTypes.sol";
import "../types/AoriErrors.sol";
import { AoriStorageData } from "../storage/AoriStorage.sol";
import { TokenUtils } from "../utils/TokenUtils.sol";
import { HookUtils } from "../utils/HookUtils.sol";
import { ValidationUtils } from "../utils/ValidationUtils.sol";
import { IAori } from "../interfaces/IAori.sol";

/**
 * @title AoriAtomicSwapLib
 * @notice External library containing atomic swap logic for the Aori protocol
 * @dev Functions are called via DELEGATECALL, running in Aori's storage context.
 *      This saves bytecode in the main Aori contract for the complex atomic swap logic.
 */
library AoriAtomicSwapLib {
    using TokenUtils for address;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
    /*                     ATOMIC SWAP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Core swap execution logic for atomic srcHook swaps
     * @dev Executes hook, validates output, distributes tokens, updates state, emits events
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

        // Calculate minimum acceptable output (returns outputAmount when slippageMbps = 0)
        uint256 minOutput = (uint256(order.outputAmount) * (ValidationUtils.MBPS_DIVISOR - order.options.slippageMbps)) / ValidationUtils.MBPS_DIVISOR;

        // Execute hook - converts input to output, validates minOutput
        amountReceived = HookUtils.executeHook(hook.hookAddress, hook.instructions, order.outputToken, minOutput);

        // Fee basis: if slippageMbps > 0, recipient captures surplus so fee on actual; otherwise fee on signed amount
        uint256 feeBasis = order.options.slippageMbps > 0 ? amountReceived : order.outputAmount;

        (uint128 protocolFee, uint128 additionalFee, uint128 recipientAmount) =
            ValidationUtils.calculateFees(feeBasis, $.protocolFeeMbps, order.options.feeMbps);

        // Surplus: if slippageMbps = 0, solver gets surplus; if > 0, recipient already received it via feeBasis
        uint256 surplus = order.options.slippageMbps > 0 ? 0 : amountReceived - order.outputAmount;

        // Recipient gets output minus fees (immediate transfer)
        order.outputToken.safeTransfer(order.recipient, recipientAmount);

        // Protocol fee - lazy accrual (checked += safe here, single-order path can revert)
        if (protocolFee > 0) {
            $.pendingProtocolFees[order.outputToken] += protocolFee;
        }

        // Additional fee accrues to feeRecipient (or solver if address(0))
        if (additionalFee > 0) {
            address actualFeeRecipient = order.options.feeRecipient == address(0) ? solver : order.options.feeRecipient;
            $.balances[actualFeeRecipient][order.outputToken].unlocked += additionalFee;
        }

        // Surplus accrues to solver (only when slippageMbps = 0)
        if (surplus > 0) {
            $.balances[solver][order.outputToken].unlocked += SafeCast.toUint128(surplus);
        }

        // Update state
        $.orders[orderId] = order;
        $.orderStatus[orderId] = OrderStatus.Settled;

        // Emit events - srcHook converted inputToken to outputToken
        emit IAori.Deposit(orderId, order, hook.preferredToken, amountReceived);
        emit IAori.Fill(orderId, address(0), 0, 0);
        emit IAori.Settle(
            orderId, 
            solver, 
            SafeCast.toUint128(surplus), 
            protocolFee, 
            order.options.feeRecipient == address(0) ? solver : order.options.feeRecipient, 
            additionalFee
        );
    }
}
