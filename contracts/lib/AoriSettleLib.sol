// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Order, OrderStatus, Balance } from "../types/AoriTypes.sol";
import "../types/AoriErrors.sol";
import { AoriStorageData } from "../AoriStorage.sol";
import { ValidationUtils } from "../utils/ValidationUtils.sol";
import { BalanceUtils } from "../utils/BalanceUtils.sol";
import { PayloadUtils } from "../utils/PayloadUtils.sol";
import { IAori } from "../interfaces/IAori.sol";

/**
 * @title AoriSettleLib
 * @notice External library containing settlement logic for the Aori protocol
 * @dev Functions are called via DELEGATECALL, running in Aori's storage context.
 *      This saves bytecode in the main Aori contract while only adding DELEGATECALL
 *      overhead for settlement operations.
 */
library AoriSettleLib {
    using BalanceUtils for Balance;
    using PayloadUtils for bytes;

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
    /*                  SINGLE-CHAIN SETTLEMENT                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Handles settlement of same-chain swaps with fee distribution
     * @dev Performs atomic settlement within the same transaction for same-chain orders.
     *      Moves tokens from offerer's locked balance to solver's unlocked balance minus fee.
     *      Fee accrues to feeRecipient's unlocked balance.
     * @param orderId The unique identifier for the order
     * @param order The order details
     * @param solver The address of the solver who filled the order
     * @param dstHookTokenIn The token used in dstHook (address(0) if no hook)
     * @param dstHookAmountIn The amount sent to dstHook (0 if no hook)
     * @param dstHookAmountOut The amount received from dstHook (0 if no hook)
     */
    function settleSingleChainSwap(
        bytes32 orderId,
        Order memory order,
        address solver,
        address dstHookTokenIn,
        uint256 dstHookAmountIn,
        uint256 dstHookAmountOut
    ) external {
        AoriStorageData storage $ = _getAoriStorage();

        (uint128 protocolFee, uint128 additionalFee, uint128 solverAmount) =
            ValidationUtils.calculateFees(order.inputAmount, $.protocolFeeMbps, order.options.feeMbps);

        // Decrease offerer's locked balance
        $.balances[order.offerer][order.inputToken].locked -= order.inputAmount;

        // Credit solver (minus fees)
        $.balances[solver][order.inputToken].unlocked += solverAmount;

        // Protocol fee - lazy accrual (direct += ok here, single operation can revert)
        if (protocolFee > 0) {
            $.pendingProtocolFees[order.inputToken] += protocolFee;
        }

        // Additional fee accrues to feeRecipient
        address feeRecipient = order.options.feeRecipient == address(0) ? solver : order.options.feeRecipient;
        if (additionalFee > 0) {
            $.balances[feeRecipient][order.inputToken].unlocked += additionalFee;
        }

        $.orderStatus[orderId] = OrderStatus.Settled;
        emit IAori.Fill(orderId, dstHookTokenIn, dstHookAmountIn, dstHookAmountOut);
        emit IAori.Settle(orderId, solver, solverAmount, protocolFee, feeRecipient, additionalFee);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CROSS-CHAIN SETTLEMENT                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Handles settlement of filled orders from cross-chain messages
     * @param payload The settlement payload containing order hashes and filler information
     * @param senderEid The source endpoint ID
     * @dev Skips orders that were filled on the wrong chain and emits SettlementFailed event
     */
    function handleSettlement(bytes calldata payload, uint32 senderEid) external {
        (address filler, uint16 fillCount) = payload.validateAndUnpackSettlement();

        AoriStorageData storage $ = _getAoriStorage();
        for (uint256 i = 0; i < fillCount; ++i) {
            bytes32 orderId = payload.unpackSettlementBodyAt(i);
            Order memory order = $.orders[orderId];

            if (order.dstEid != senderEid) {
                emit IAori.SettlementFailed(orderId, order.dstEid, senderEid);
                continue;
            }

            _settleOrder($, orderId, order, filler);
        }
    }

    /**
     * @notice Internal function to settle a single cross-chain order
     * @param $ Storage pointer
     * @param orderId The order hash
     * @param order The order details
     * @param filler The address of the filler
     */
    function _settleOrder(AoriStorageData storage $, bytes32 orderId, Order memory order, address filler) internal {
        if ($.orderStatus[orderId] != OrderStatus.Active) {
            return; // Skip non-active orders
        }

        (uint128 protocolFee, uint128 additionalFee, uint128 fillerAmount) =
            ValidationUtils.calculateFees(order.inputAmount, $.protocolFeeMbps, order.options.feeMbps);

        address feeRecipient = order.options.feeRecipient == address(0) ? filler : order.options.feeRecipient;

        // Cache original balances for potential rollback
        Balance memory offererBalanceCache = $.balances[order.offerer][order.inputToken];
        Balance memory fillerBalanceCache = $.balances[filler][order.inputToken];
        Balance memory feeRecipientBalanceCache;
        if (feeRecipient != filler) {
            feeRecipientBalanceCache = $.balances[feeRecipient][order.inputToken];
        }

        // Attempt atomic balance transfer with soft-fail for batch safety
        bool successLock = $.balances[order.offerer][order.inputToken].decreaseLockedNoRevert(order.inputAmount);

        if (feeRecipient == filler) {
            // Optimized path: single write for filler + additionalFee combined
            uint128 totalToFiller = fillerAmount + additionalFee;
            bool successFiller = $.balances[filler][order.inputToken].increaseUnlockedNoRevert(totalToFiller);

            if (!successLock || !successFiller) {
                $.balances[order.offerer][order.inputToken] = offererBalanceCache;
                $.balances[filler][order.inputToken] = fillerBalanceCache;
                emit IAori.SettleFailed(orderId);
                return;
            }
        } else {
            bool successFiller = $.balances[filler][order.inputToken].increaseUnlockedNoRevert(fillerAmount);
            bool successAdditionalFee =
                additionalFee > 0 
                ? $.balances[feeRecipient][order.inputToken].increaseUnlockedNoRevert(additionalFee) 
                : true;

            if (!successLock || !successFiller || !successAdditionalFee) {
                $.balances[order.offerer][order.inputToken] = offererBalanceCache;
                $.balances[filler][order.inputToken] = fillerBalanceCache;
                $.balances[feeRecipient][order.inputToken] = feeRecipientBalanceCache;
                emit IAori.SettleFailed(orderId);
                return;
            }
        }

        // Protocol fee - lazy accrual inside soft-fail window
        if (protocolFee > 0) {
            if (!BalanceUtils.addNoRevert($.pendingProtocolFees, order.inputToken, protocolFee)) {
                $.balances[order.offerer][order.inputToken] = offererBalanceCache;
                $.balances[filler][order.inputToken] = fillerBalanceCache;
                if (feeRecipient != filler) {
                    $.balances[feeRecipient][order.inputToken] = feeRecipientBalanceCache;
                }
                emit IAori.SettleFailed(orderId);
                return;
            }
        }

        $.orderStatus[orderId] = OrderStatus.Settled;
        emit IAori.Settle(orderId, filler, fillerAmount, protocolFee, feeRecipient, additionalFee);
    }
}
