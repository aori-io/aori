// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Order, OrderStatus } from "../types/AoriTypes.sol";
import "../types/AoriErrors.sol";
import { AoriStorageData } from "../AoriStorage.sol";
import { TokenUtils } from "../utils/TokenUtils.sol";
import { PayloadUtils } from "../utils/PayloadUtils.sol";
import { ValidationUtils } from "../utils/ValidationUtils.sol";
import { IAori } from "../interfaces/IAori.sol";

/**
 * @title AoriCancelLib
 * @notice External library containing cancellation logic for the Aori protocol
 * @dev Functions are called via DELEGATECALL, running in Aori's storage context.
 *      This saves bytecode in the main Aori contract by moving internal library
 *      linkage (TokenUtils, PayloadUtils, ValidationUtils) to this library.
 */
library AoriCancelLib {
    using TokenUtils for address;
    using PayloadUtils for bytes;
    using ValidationUtils for Order;

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
    /*                   SINGLE-CHAIN CANCEL                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Validates and executes a single-chain order cancellation
     * @dev Validates permissions then cancels the order, returning tokens to offerer
     * @param orderId The hash of the order to cancel
     * @param endpointId The current chain's endpoint ID
     * @param sender The address initiating the cancellation
     * @param orderStatusFn Function to check order status
     * @param isAllowedSolverFn Function to check if address is whitelisted solver
     */
    function cancelSingleChain(
        bytes32 orderId,
        uint32 endpointId,
        address sender,
        function(bytes32) external view returns (OrderStatus) orderStatusFn,
        function(address) external view returns (bool) isAllowedSolverFn
    ) external {
        AoriStorageData storage $ = _getAoriStorage();
        Order memory order = $.orders[orderId];

        order.validateSourceChainCancel(orderId, endpointId, orderStatusFn, sender, isAllowedSolverFn);

        _cancelOrder(orderId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   CROSS-CHAIN CANCEL                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Validates cross-chain cancel and prepares the LZ payload
     * @dev Validates permissions, marks order as cancelled, and packs the payload
     * @param orderId The hash of the order to cancel
     * @param orderToCancel The order details
     * @param endpointId The current chain's endpoint ID
     * @param sender The address initiating the cancellation
     * @param orderStatusFn Function to check order status
     * @param isAllowedSolverFn Function to check if address is whitelisted solver
     * @return payload The packed cancellation payload for __lzSend
     */
    function validateAndPrepareCrossChainCancel(
        bytes32 orderId,
        Order calldata orderToCancel,
        uint32 endpointId,
        address sender,
        function(bytes32) external view returns (OrderStatus) orderStatusFn,
        function(address) external view returns (bool) isAllowedSolverFn
    ) external returns (bytes memory payload) {
        if (keccak256(abi.encode(orderToCancel)) != orderId) revert OrderDataMismatch();

        orderToCancel.validateCancel(orderId, endpointId, orderStatusFn, sender, isAllowedSolverFn);

        _getAoriStorage().orderStatus[orderId] = OrderStatus.Cancelled;

        return PayloadUtils.packCancellation(orderId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   LZ RECEIVE HANDLER                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Handles cancellation payload received from LayerZero
     * @dev Unpacks the payload and validates the cancellation originated from the order's destination chain
     * @param payload The cancellation payload containing the order hash
     * @param srcEid The source endpoint ID of the incoming LayerZero message
     */
    function handleCancellation(bytes calldata payload, uint32 srcEid) external {
        payload.validateCancellationLen();
        bytes32 orderId = payload.unpackCancellation();
        AoriStorageData storage $ = _getAoriStorage();
        uint32 orderDstEid = $.orders[orderId].dstEid;
        if (orderDstEid != srcEid) revert ChainMismatch(orderDstEid, srcEid);
        _cancelOrder(orderId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTERNAL HELPERS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Internal function to cancel an order and return tokens to offerer
     * @dev Updates order status, decreases locked balance, and transfers tokens back
     * @param orderId The hash of the order to cancel
     */
    function _cancelOrder(bytes32 orderId) private {
        AoriStorageData storage $ = _getAoriStorage();
        if ($.orderStatus[orderId] != OrderStatus.Active) revert CanOnlyCancelActiveOrders();

        Order memory order = $.orders[orderId];
        uint128 amountToReturn = order.inputAmount;
        address tokenAddress = order.inputToken;
        address recipient = order.offerer;

        // Validate contract has sufficient tokens
        tokenAddress.validateSufficientBalance(amountToReturn);

        // Update state first
        $.orderStatus[orderId] = OrderStatus.Cancelled;
        $.balances[recipient][tokenAddress].locked -= amountToReturn;

        // Transfer tokens back to offerer
        tokenAddress.safeTransfer(recipient, amountToReturn);
        emit IAori.Cancel(orderId);
    }
}
