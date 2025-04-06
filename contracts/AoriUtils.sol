// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAori } from "./IAori.sol";

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
     * @return The balance change (typically positive if tokens are received)
     */
    function observeBalChg(
        address target,
        bytes calldata data,
        address observedToken
    ) internal returns (uint256) {
        uint256 balBefore = IERC20(observedToken).balanceOf(address(this));
        (bool success, ) = target.call(data);
        require(success, "Call failed");
        uint256 balAfter = IERC20(observedToken).balanceOf(address(this));
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
 * @dev Provides functions to create properly formatted message payloads
 */
library PayloadPackUtils {
    /**
     * @notice Packs a settlement payload with order hashes for LayerZero messaging
     * @dev Creates a settlement payload and clears the filled orders from storage
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
     * @param orderHash The hash of the order to cancel
     * @return payload The packed cancellation payload
     */
    function packCancellation(bytes32 orderHash) internal pure returns (bytes memory payload) {
        uint8 msgType = uint8(PayloadType.Cancellation);
        assembly {
            mstore(payload, 33)
            mstore8(add(payload, 32), msgType)
            mstore(add(payload, 33), orderHash)
            mstore(0x40, add(payload, 65))
        }
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

function settlementPayloadSize(uint256 fillCount) pure returns (uint256) {
    return 1 + 20 + 2 + (fillCount * 32);
}
