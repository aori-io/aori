// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { SignatureCheckerLib } from "solady/src/utils/SignatureCheckerLib.sol";
import { Order, OrderStatus } from "../../types/AoriTypes.sol";
import "../../types/AoriErrors.sol";

/**
 * @notice Library for order validation functions
 * @dev Provides reusable validation logic for orders across different contract functions
 */
library ValidationUtils {
    /**
     * @notice Validates basic order parameters that are common to all validation flows
     * @dev Checks offerer, recipient, time bounds, amounts, and token addresses
     * @param order The order to validate
     */
    /* forgefmt: disable-next-item */
    function validateCommonOrderParams(Order calldata order) internal view {
        if (order.offerer == address(0)) revert InvalidOfferer();
        if (order.recipient == address(0)) revert InvalidRecipient();
        if (order.startTime >= order.endTime) revert InvalidEndTime(order.startTime, order.endTime);
        if (order.startTime > block.timestamp) revert OrderNotStarted(order.startTime, block.timestamp);
        if (order.endTime <= block.timestamp) revert OrderExpired(order.endTime, block.timestamp);
        if (order.inputAmount == 0) revert InvalidInputAmount();
        if (order.outputAmount == 0) revert InvalidOutputAmount();
        if (order.inputToken == address(0) || order.outputToken == address(0)) revert InvalidToken();
    }

    /**
     * @notice Validates deposit parameters including signature verification
     * @dev Performs comprehensive validation for deposit operations
     * @param order The order to validate
     * @param signature The EIP712 signature to verify
     * @param digest The EIP712 type hash digest of the order
     * @param endpointId The current chain's endpoint ID
     * @param orderStatus The status mapping function to check order status
     * @param isSupportedChain A function to check if the destination chain is supported
     * @return orderId The calculated order hash
     */
    function validateDeposit(
        Order calldata order,
        bytes calldata signature,
        bytes32 digest,
        uint32 endpointId,
        function(bytes32) external view returns (OrderStatus) orderStatus,
        function(uint32) external view returns (bool) isSupportedChain
    ) internal view returns (bytes32 orderId) {
        orderId = keccak256(abi.encode(order));
        if (orderStatus(orderId) != OrderStatus.Unknown) revert OrderAlreadyExists();
        if (!isSupportedChain(order.dstEid)) revert DestinationChainNotSupported(order.dstEid);

        // Signature validation - supports both EOAs and smart contract wallets (ERC-1271)
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(order.offerer, digest, signature)) {
            revert InvalidSignature();
        }

        // Order parameter validation
        validateCommonOrderParams(order);
        if (order.srcEid != endpointId) revert ChainMismatch(endpointId, order.srcEid);
    }

    /**
     * @notice Validates deposit parameters without signature verification
     * @dev Used for depositNative and depositWithPermit2 which have their own auth mechanisms
     * @param order The order to validate
     * @param endpointId The current chain's endpoint ID
     * @param orderStatus The status mapping function to check order status
     * @param isSupportedChain A function to check if the destination chain is supported
     * @return orderId The calculated order hash
     */
    function validateDepositNoSig(
        Order calldata order,
        uint32 endpointId,
        function(bytes32) external view returns (OrderStatus) orderStatus,
        function(uint32) external view returns (bool) isSupportedChain
    ) internal view returns (bytes32 orderId) {
        orderId = keccak256(abi.encode(order));
        if (orderStatus(orderId) != OrderStatus.Unknown) revert OrderAlreadyExists();
        if (!isSupportedChain(order.dstEid)) revert DestinationChainNotSupported(order.dstEid);
        if (order.srcEid != endpointId) revert ChainMismatch(endpointId, order.srcEid);
        validateCommonOrderParams(order);
    }

    /**
     * @notice Validates fill parameters for both single-chain and cross-chain swaps
     * @dev Performs comprehensive validation for fill operations
     * @param order The order to validate
     * @param solver The address attempting to fill the order
     * @param endpointId The current chain's endpoint ID
     * @param orderStatus The status mapping function to check order status
     * @return orderId The calculated order hash
     */
    function validateFill(
        Order calldata order,
        address solver,
        uint32 endpointId,
        function(bytes32) external view returns (OrderStatus) orderStatus
    ) internal view returns (bytes32 orderId) {
        // Order parameter validation
        validateCommonOrderParams(order);
        if (order.dstEid != endpointId) revert ChainMismatch(endpointId, order.dstEid);

        // Solver authorization: if order specifies a solver, only that solver can fill
        if (order.options.solver != address(0) && solver != order.options.solver) {
            revert UnauthorizedSolver();
        }

        orderId = keccak256(abi.encode(order));

        // Different validation based on whether it's a single-chain or cross-chain swap
        OrderStatus status = orderStatus(orderId);
        if (order.srcEid == order.dstEid) {
            // For single-chain swaps, the order should already be Active
            if (status != OrderStatus.Active) revert OrderNotInActiveState(status);
        } else {
            // For cross-chain swaps, the order should be Unknown on the destination chain
            if (status != OrderStatus.Unknown) revert OrderAlreadyProcessed(status);
        }
    }

    /**
     * @notice Validates the cancellation of a cross-chain order from the destination chain
     * @dev Allows whitelisted solvers (anytime), offerers (after expiry), and recipients (after expiry) to cancel
     * @param order The order details to cancel
     * @param orderId The hash of the order to cancel
     * @param endpointId The current chain's endpoint ID
     * @param orderStatus The status mapping function to check order status
     * @param sender The address of the transaction sender
     * @param isAllowedSolver A function to check if an address is a whitelisted solver
     */
    function validateCancel(
        Order calldata order,
        bytes32 orderId,
        uint32 endpointId,
        function(bytes32) external view returns (OrderStatus) orderStatus,
        address sender,
        function(address) external view returns (bool) isAllowedSolver
    ) internal view {
        if (order.dstEid != endpointId) revert NotOnDestinationChain();
        OrderStatus status = orderStatus(orderId);
        if (status != OrderStatus.Unknown) revert OrderAlreadyProcessed(status);
        if (
            !isAllowedSolver(sender) && !(sender == order.offerer && block.timestamp > order.endTime)
                && !(sender == order.recipient && block.timestamp > order.endTime)
        ) {
            revert UnauthorizedCancel();
        }
    }

    /**
     * @notice Validates cancellation of an order on the source chain
     * @dev Only allows cancellation of single-chain orders or by solver (with expiry restriction for cross-chain)
     * @param order The order details to cancel
     * @param orderId The hash of the order to cancel
     * @param endpointId The current chain's endpoint ID
     * @param orderStatus The function to check order status
     * @param sender The transaction sender address
     * @param isAllowedSolver The function to check if an address is a whitelisted solver
     */
    function validateSourceChainCancel(
        Order memory order,
        bytes32 orderId,
        uint32 endpointId,
        function(bytes32) external view returns (OrderStatus) orderStatus,
        address sender,
        function(address) external view returns (bool) isAllowedSolver
    ) internal view {
        // Verify we're on the source chain
        if (order.srcEid != endpointId) revert NotOnSourceChain();

        // Verify order exists and is active
        OrderStatus status = orderStatus(orderId);
        if (status != OrderStatus.Active) revert OrderNotInActiveState(status);

        // Cross-chain orders cannot be cancelled from the source chain to prevent race conditions
        // with settlement messages. Use emergencyCancel for emergency situations.
        if (order.srcEid != order.dstEid) revert CrossChainOrdersMustBeCancelledFromDestinationChain();

        // For single-chain orders: solver can always cancel, offerer can cancel after expiry
        if (!isAllowedSolver(sender) && !(sender == order.offerer && block.timestamp > order.endTime)) {
            revert UnauthorizedCancel();
        }
    }

    /**
     * @notice Checks if an order is a single-chain swap
     * @param order The order to check
     * @return True if the order is a single-chain swap
     */
    /* forgefmt: disable-next-item */
    function isSingleChainSwap(Order calldata order) internal pure returns (bool) { return order.srcEid == order.dstEid; }
}
