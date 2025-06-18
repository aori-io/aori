// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "solady/src/utils/ECDSA.sol";
import { IAori } from "./IAori.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                          VALIDATION                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
    function validateCommonOrderParams(IAori.Order calldata order) internal view {
        require(order.offerer != address(0), "Invalid offerer");
        require(order.recipient != address(0), "Invalid recipient");
        require(order.startTime < order.endTime, "Invalid end time");
        require(order.startTime <= block.timestamp, "Order not started");
        require(order.endTime > block.timestamp, "Order has expired");
        require(order.inputAmount > 0, "Invalid input amount");
        require(order.outputAmount > 0, "Invalid output amount");
        require(order.inputToken != address(0) && order.outputToken != address(0), "Invalid token");
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
        IAori.Order calldata order,
        bytes calldata signature,
        bytes32 digest,
        uint32 endpointId,
        function(bytes32) external view returns (IAori.OrderStatus) orderStatus,
        function(uint32) external view returns (bool) isSupportedChain
    ) internal view returns (bytes32 orderId) {
        orderId = keccak256(abi.encode(order));
        require(orderStatus(orderId) == IAori.OrderStatus.Unknown, "Order already exists");
        require(isSupportedChain(order.dstEid), "Destination chain not supported");


        // Signature validation
        address recovered = ECDSA.recover(digest, signature);
        require(recovered == order.offerer, "InvalidSignature");

        // Order parameter validation
        validateCommonOrderParams(order);
        require(order.srcEid == endpointId, "Chain mismatch");
    }

    /**
     * @notice Validates fill parameters for both single-chain and cross-chain swaps
     * @dev Performs comprehensive validation for fill operations
     * @param order The order to validate
     * @param endpointId The current chain's endpoint ID
     * @param orderStatus The status mapping function to check order status
     * @return orderId The calculated order hash
     */
    function validateFill(
        IAori.Order calldata order,
        uint32 endpointId,
        function(bytes32) external view returns (IAori.OrderStatus) orderStatus
    ) internal view returns (bytes32 orderId) {
        // Order parameter validation
        validateCommonOrderParams(order);
        require(order.dstEid == endpointId, "Chain mismatch");

        orderId = keccak256(abi.encode(order));

        // Different validation based on whether it's a single-chain or cross-chain swap
        if (order.srcEid == order.dstEid) {
            // For single-chain swaps, the order should already be Active
            require(orderStatus(orderId) == IAori.OrderStatus.Active, "Order not active");
        } else {
            // For cross-chain swaps, the order should be Unknown on the destination chain
            require(orderStatus(orderId) == IAori.OrderStatus.Unknown, "Order not active");
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
        IAori.Order calldata order,
        bytes32 orderId,
        uint32 endpointId,
        function(bytes32) external view returns (IAori.OrderStatus) orderStatus,
        address sender,
        function(address) external view returns (bool) isAllowedSolver
    ) internal view {
        require(order.dstEid == endpointId, "Not on destination chain");
        require(orderStatus(orderId) == IAori.OrderStatus.Unknown, "Order not active");
        require(
            (isAllowedSolver(sender)) ||
                (sender == order.offerer && block.timestamp > order.endTime) ||
                (sender == order.recipient && block.timestamp > order.endTime),
            "Only whitelisted solver, offerer, or recipient (after expiry) can cancel"
        );
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
        IAori.Order memory order,
        bytes32 orderId,
        uint32 endpointId,
        function(bytes32) external view returns (IAori.OrderStatus) orderStatus,
        address sender,
        function(address) external view returns (bool) isAllowedSolver
    ) internal view {
        // Verify we're on the source chain
        require(order.srcEid == endpointId, "Not on source chain");
        
        // Verify order exists and is active
        require(orderStatus(orderId) == IAori.OrderStatus.Active, "Order not active");
        
        // Cross-chain orders cannot be cancelled from the source chain to prevent race conditions
        // with settlement messages. Use emergencyCancel for emergency situations.
        require(order.srcEid == order.dstEid, "Cross-chain orders must be cancelled from destination chain");
        
        // For single-chain orders: solver can always cancel, offerer can cancel after expiry
        require(
            isAllowedSolver(sender) || 
            (sender == order.offerer && block.timestamp > order.endTime),
            "Only solver or offerer (after expiry) can cancel"
        );
    }

    /**
     * @notice Checks if an order is a single-chain swap
     * @param order The order to check
     * @return True if the order is a single-chain swap
     */
    function isSingleChainSwap(IAori.Order calldata order) internal pure returns (bool) {
        return order.srcEid == order.dstEid;
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                         BALANCE                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @notice Balance struct for tracking locked and unlocked token amounts
 * @dev Uses uint128 for both values to pack them into a single storage slot
 */
struct Balance {
    uint128 locked; // Tokens locked in active orders
    uint128 unlocked; // Tokens available for withdrawal
}

using BalanceUtils for Balance global;

/**
 * @notice Utility library for managing token balances
 * @dev Provides functions for locking, unlocking, and managing token balances
 * with optimized storage operations
 */
library BalanceUtils {
    /**
     * @notice Locks a specified amount of tokens
     * @dev Increases the locked balance by the specified amount
     * @param balance The Balance struct reference
     * @param amount The amount to lock
     */
    function lock(Balance storage balance, uint128 amount) internal {
        balance.locked += amount;
    }

    /**
     * @notice Unlocks a specified amount of tokens from locked to unlocked state
     * @dev Decreases locked balance and increases unlocked balance
     * @param balance The Balance struct reference
     * @param amount The amount to unlock
     */
    function unlock(Balance storage balance, uint128 amount) internal {
        (uint128 locked, uint128 unlocked) = balance.loadBalance();
        require(locked >= amount, "Insufficient locked balance");
        unchecked {
            locked -= amount;
        }
        unlocked += amount;

        balance.storeBalance(locked, unlocked);
    }

    /**
     * @notice Decreases locked balance without reverting on underflow
     * @dev Safe version that returns false instead of reverting on underflow
     * @param balance The Balance struct reference
     * @param amount The amount to decrease
     * @return success Whether the operation was successful
     */
    function decreaseLockedNoRevert(
        Balance storage balance,
        uint128 amount
    ) internal returns (bool success) {
        uint128 locked = balance.locked;
        unchecked {
            uint128 newLocked = locked - amount;
            if (newLocked > locked) {
                return false; // Underflow
            }
            balance.locked = newLocked;
        }
        return true;
    }

    /**
     * @notice Increases unlocked balance without reverting on overflow
     * @dev Safe version that returns false instead of reverting on overflow
     * @param balance The Balance struct reference
     * @param amount The amount to increase
     * @return success Whether the operation was successful
     */
    function increaseUnlockedNoRevert(
        Balance storage balance,
        uint128 amount
    ) internal returns (bool success) {
        uint128 unlocked = balance.unlocked;
        unchecked {
            uint128 newUnlocked = unlocked + amount;
            if (newUnlocked < unlocked) {
                return false; // Overflow
            }
            balance.unlocked = newUnlocked;
        }
        return true;
    }

    /**
     * @notice Unlocks all locked tokens into the unlocked balance
     * @dev Moves the entire locked balance to unlocked
     * @param balance The Balance struct reference
     * @return amount The amount that was unlocked
     */
    function unlockAll(Balance storage balance) internal returns (uint128 amount) {
        (uint128 locked, uint128 unlocked) = balance.loadBalance();
        amount = locked;
        unlocked += amount;
        locked = 0;

        balance.storeBalance(locked, unlocked);
    }

    /**
     * @notice Gets the unlocked balance amount
     * @param balance The Balance struct reference
     * @return The unlocked balance amount
     */
    function getUnlocked(Balance storage balance) internal view returns (uint128) {
        return balance.unlocked;
    }

    /**
     * @notice Gets the locked balance amount
     * @param balance The Balance struct reference
     * @return The locked balance amount
     */
    function getLocked(Balance storage balance) internal view returns (uint128) {
        return balance.locked;
    }

    /**
     * @notice Load balance values using optimized storage operations
     * @dev Uses assembly to read both values in a single storage read
     * @param balance The Balance struct reference
     * @return locked The locked balance
     * @return unlocked The unlocked balance
     */
    function loadBalance(
        Balance storage balance
    ) internal view returns (uint128 locked, uint128 unlocked) {
        assembly {
            let fullSlot := sload(balance.slot)
            unlocked := shr(128, fullSlot)
            locked := fullSlot
        }
    }

    /**
     * @notice Store balance values using optimized storage operations
     * @dev Uses assembly to write both values in a single storage write
     * @param balance The Balance struct reference
     * @param locked The locked balance to store
     * @param unlocked The unlocked balance to store
     */
    function storeBalance(Balance storage balance, uint128 locked, uint128 unlocked) internal {
        assembly {
            sstore(balance.slot, or(shl(128, unlocked), locked))
        }
    }

    /**
     * @notice Validates a decrease in locked balance with a corresponding increase in unlocked balance
     * @dev Verifies that the token accounting was performed correctly during transfer operations
     * @param _balance The Balance struct reference (not used, but needed for extension method pattern)
     * @param initialOffererLocked The offerer's initial locked balance
     * @param finalOffererLocked The offerer's final locked balance
     * @param initialSolverUnlocked The solver's initial unlocked balance
     * @param finalSolverUnlocked The solver's final unlocked balance
     * @param transferAmount The amount that should have been transferred
     * @return success Whether the validation was successful
     */
    function validateBalanceTransfer(
        Balance storage _balance,
        uint128 initialOffererLocked,
        uint128 finalOffererLocked,
        uint128 initialSolverUnlocked,
        uint128 finalSolverUnlocked,
        uint128 transferAmount
    ) internal pure returns (bool success) {
        // Verify offerer's locked balance decreased by exactly the transfer amount
        if (initialOffererLocked != finalOffererLocked + transferAmount) {
            return false;
        }

        // Verify solver's unlocked balance increased by exactly the transfer amount
        if (finalSolverUnlocked != initialSolverUnlocked + transferAmount) {
            return false;
        }

        return true;
    }

    /**
     * @notice Validates a decrease in locked balance with a corresponding increase in unlocked balance with revert
     * @dev Same as validateBalanceTransfer but reverts with custom error messages if validation fails
     * @param _balance The Balance struct reference (not used, but needed for extension method pattern)
     * @param initialOffererLocked The offerer's initial locked balance
     * @param finalOffererLocked The offerer's final locked balance
     * @param initialSolverUnlocked The solver's initial unlocked balance
     * @param finalSolverUnlocked The solver's final unlocked balance
     * @param transferAmount The amount that should have been transferred
     */
    function validateBalanceTransferOrRevert(
        Balance storage _balance,
        uint128 initialOffererLocked,
        uint128 finalOffererLocked,
        uint128 initialSolverUnlocked,
        uint128 finalSolverUnlocked,
        uint128 transferAmount
    ) internal pure {
        // Verify offerer's locked balance decreased by exactly the transfer amount
        require(
            initialOffererLocked == finalOffererLocked + transferAmount,
            "Inconsistent offerer balance"
        );

        // Verify solver's unlocked balance increased by exactly the transfer amount
        require(
            finalSolverUnlocked == initialSolverUnlocked + transferAmount,
            "Inconsistent solver balance"
        );
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       EXECUTION                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @notice Library for executing external calls and observing token balance changes
 * @dev Used for hook execution and token conversion operations
 */
library ExecutionUtils {
    /**
     * @notice Executes an external call and measures the resulting token balance change
     * @dev Useful for hook operations that convert tokens
     * @param target The target contract address to call
     * @param data The calldata to send to the target
     * @param observedToken The token address to observe balance changes for
     * @return The balance change (positive if tokens increased, reverts if decreased)
     */
    function observeBalChg(
        address target,
        bytes calldata data,
        address observedToken
    ) internal returns (uint256) {
        uint256 balBefore = NativeTokenUtils.balanceOf(observedToken, address(this));
        (bool success, ) = target.call(data);
        require(success, "Call failed");
        uint256 balAfter = NativeTokenUtils.balanceOf(observedToken, address(this));
        
        // Prevent underflow and provide clear error message
        require(balAfter >= balBefore, "Hook decreased contract balance");
        
        return balAfter - balBefore;
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                          HOOKS                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @notice Library for hook-related utility functions
 * @dev Provides helper functions for working with SrcHook and DstHook structs
 */
library HookUtils {
    /**
     * @notice Checks if a SrcHook is defined (has a non-zero address)
     * @param hook The SrcHook struct to check
     * @return True if the hook has a non-zero address
     */
    function isSome(IAori.SrcHook calldata hook) internal pure returns (bool) {
        return hook.hookAddress != address(0);
    }

    /**
     * @notice Checks if a DstHook is defined (has a non-zero address)
     * @param hook The DstHook struct to check
     * @return True if the hook has a non-zero address
     */
    function isSome(IAori.DstHook calldata hook) internal pure returns (bool) {
        return hook.hookAddress != address(0);
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      PAYLOAD TYPES                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @notice Enum for different LayerZero message payload types
 */
enum PayloadType {
    Settlement, // Settlement message with multiple order fills (0)
    Cancellation // Cancellation message for a single order (1)
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    PAYLOAD PACKING                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @notice Library for packing LayerZero message payloads
 * @dev Provides functions to create properly formatted message payloads for cross-chain messaging
 * that will work with the MessagingReceipt tracking in the contract
 */
library PayloadPackUtils {
    /**
     * @notice Packs a settlement payload with order hashes for LayerZero messaging
     * @dev Creates a settlement payload and clears the filled orders from storage
     * The message will return a MessagingReceipt that is included in the SettleSent event
     * @param arr The array of order hashes to be packed
     * @param filler The address of the filler
     * @param takeSize The number of order hashes to take from the array
     * @return The packed payload
     *
     * @notice The payload structure is as follows:
     * Header
     * - 1 byte: Message type (0)
     * - 20 bytes: Filler address
     * - 2 bytes: Fill count
     * Body
     * - Fill count * 32 bytes: Order hashes
     */
    function packSettlement(
        bytes32[] storage arr,
        address filler,
        uint16 takeSize
    ) internal returns (bytes memory) {
        uint32 offset = 23;
        bytes memory payload = new bytes(offset + takeSize * 32);

        assembly {
            let payloadPtr := add(payload, 32)
            // Store msgType, filler and takeSize
            mstore(payloadPtr, or(shl(88, filler), shl(72, takeSize)))

            // Load array slot
            mstore(0x00, arr.slot)
            let base := keccak256(0x00, 32)

            let arrLength := sload(arr.slot)
            let min_i := sub(arrLength, takeSize)
            let dataPtr := add(payloadPtr, offset)

            // Store storage elements into memory and clear them
            for {
                let i := arrLength
            } gt(i, min_i) {} {
                i := sub(i, 1)
                let elementSlot := add(base, i)

                mstore(dataPtr, sload(elementSlot)) // Storage -> memory
                sstore(elementSlot, 0) // Clear the slot

                dataPtr := add(dataPtr, 32)
            }
            // Update the array length
            sstore(arr.slot, min_i)
        }
        return payload;
    }

    /**
     * @notice Packs a cancellation payload for LayerZero messaging
     * @dev Creates a properly formatted cancellation message payload
     * The message will return a MessagingReceipt that is included in the CancelSent event
     * @param orderHash The hash of the order to cancel
     * @return payload The packed cancellation payload
     */
    function packCancellation(bytes32 orderHash) internal pure returns (bytes memory) {
        uint8 msgType = uint8(PayloadType.Cancellation);
        return abi.encodePacked(msgType, orderHash);
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                   PAYLOAD UNPACKING                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @notice Library for unpacking LayerZero message payloads
 * @dev Provides functions to extract and validate data from received payloads
 */
library PayloadUnpackUtils {
    /**
     * @notice Validates the length of a cancellation payload
     * @dev Ensures the payload is exactly 33 bytes (1 byte type + 32 bytes order hash)
     * @param payload The payload to validate
     */
    function validateCancellationLen(bytes calldata payload) internal pure {
        require(payload.length == 33, "Invalid cancellation payload length");
    }

    /**
     * @notice Unpacks an order hash from a cancellation payload
     * @dev Extracts the 32-byte order hash, skipping the first byte (type)
     * @param payload The cancellation payload to unpack
     * @return orderHash The extracted order hash
     */
    function unpackCancellation(bytes calldata payload) internal pure returns (bytes32 orderHash) {
        assembly {
            orderHash := calldataload(add(payload.offset, 1))
        }
    }

    /**
     * @notice Validates the minimum length of a settlement payload
     * @dev Ensures the payload is at least 23 bytes (header size)
     * @param payload The payload to validate
     */
    function validateSettlementLen(bytes calldata payload) internal pure {
        require(payload.length >= 23, "Payload too short for settlement");
    }

    /**
     * @notice Validates the length of a settlement payload for a specific fill count
     * @dev Ensures the payload matches the expected size based on fill count
     * @param payload The payload to validate
     * @param fillCount The number of fills in the payload
     */
    function validateSettlementLen(bytes calldata payload, uint16 fillCount) internal pure {
        require(
            payload.length == 23 + uint256(fillCount) * 32,
            "Invalid payload length for settlement"
        );
    }

    /**
     * @notice Gets the payload type from a message payload
     * @dev Reads the first byte to determine the payload type
     * @param payload The payload to check
     * @return The payload type (Settlement or Cancellation)
     */
    function getType(bytes calldata payload) internal pure returns (PayloadType) {
        return PayloadType(uint8(payload[0]));
    }

    /**
     * @notice Unpacks the header from a settlement payload
     * @dev Extracts the filler address (20 bytes) and fill count (2 bytes)
     * @param payload The settlement payload to unpack
     * @return filler The filler address
     * @return fillCount The number of fills in the payload
     */
    function unpackSettlementHeader(
        bytes calldata payload
    ) internal pure returns (address filler, uint16 fillCount) {
        require(payload.length >= 23, "Invalid payload length");
        assembly {
            let word := calldataload(add(payload.offset, 1))
            filler := shr(96, word)
        }
        fillCount = (uint16(uint8(payload[21])) << 8) | uint16(uint8(payload[22]));
    }

    /**
     * @notice Unpacks an order hash from a specific position in the settlement payload body
     * @dev Extracts the order hash at the specified index
     * @param payload The settlement payload to unpack
     * @param index The index of the order hash to extract
     * @return orderHash The extracted order hash
     */
    function unpackSettlementBodyAt(
        bytes calldata payload,
        uint256 index
    ) internal pure returns (bytes32 orderHash) {
        require(payload.length >= 23, "Invalid payload length");
        require(index < (payload.length - 23) / 32, "Index out of bounds");
        assembly {
            orderHash := calldataload(add(add(payload.offset, 23), mul(index, 32)))
        }
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    PAYLOAD SIZES                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @notice Calculates the size of a settlement payload based on fill count
 * @dev 1 byte type + 20 bytes filler + 2 bytes count + (fillCount * 32 bytes order hash)
 * @param fillCount The number of fills in the settlement
 * @return The total payload size in bytes
 */
function settlementPayloadSize(uint256 fillCount) pure returns (uint256) {
    return 1 + 20 + 2 + (fillCount * 32);
}

// Constant size of a cancellation payload: 1 byte type + 32 bytes order hash
uint256 constant CANCELLATION_PAYLOAD_SIZE = 33;

/**
 * @notice Library for payload size calculations
 * @dev Provides functions to calculate payload sizes for different message types
 */
library PayloadSizeUtils {
    /**
     * @notice Calculate payload size based on message type and other parameters
     * @dev Used for fee estimation when sending messages via LayerZero
     * @param msgType Message type (0 for settlement, 1 for cancellation)
     * @param fillsLength Number of fills available for the filler
     * @param maxFillsPerSettle Maximum fills allowed per settlement
     * @return The calculated payload size in bytes
     */
    function calculatePayloadSize(
        uint8 msgType,
        uint256 fillsLength,
        uint16 maxFillsPerSettle
    ) internal pure returns (uint256) {
        if (msgType == uint8(PayloadType.Cancellation)) {
            return CANCELLATION_PAYLOAD_SIZE; // 1 byte type + 32 bytes order hash
        } else if (msgType == uint8(PayloadType.Settlement)) {
            // Get the number of fills (capped by maxFillsPerSettle)
            uint16 fillCount = uint16(
                fillsLength < maxFillsPerSettle ? fillsLength : maxFillsPerSettle
            );

            // Calculate settlement payload size
            return settlementPayloadSize(fillCount);
        } else {
            revert("Invalid message type");
        }
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    NATIVE TOKEN UTILS                     */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

// Native token address constant
address constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

/**
 * @notice Library for native token operations
 * @dev Provides utilities for handling native ETH alongside ERC20 tokens
 */
library NativeTokenUtils {
    using SafeERC20 for IERC20;
    
    /**
     * @notice Checks if a token address represents native ETH
     * @param token The token address to check
     * @return True if the token is the native token address
     */
    function isNativeToken(address token) internal pure returns (bool) {
        return token == NATIVE_TOKEN;
    }

    /**
     * @notice Safely transfers tokens (native or ERC20) to a recipient
     * @param token The token address (use NATIVE_TOKEN for ETH)
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function safeTransfer(address token, address to, uint256 amount) internal {
        if (isNativeToken(token)) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "Native transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Gets the balance of a token for a specific address
     * @param token The token address (use NATIVE_TOKEN for ETH)
     * @param account The account to check balance for
     * @return The token balance
     */
    function balanceOf(address token, address account) internal view returns (uint256) {
        if (isNativeToken(token)) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }

    /**
     * @notice Validates that the contract has sufficient balance for a transfer
     * @param token The token address (use NATIVE_TOKEN for ETH)
     * @param amount The amount to validate
     */
    function validateSufficientBalance(address token, uint256 amount) internal view {
        if (isNativeToken(token)) {
            require(address(this).balance >= amount, "Insufficient contract native balance");
        } else {
            require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient contract balance");
        }
    }
}
