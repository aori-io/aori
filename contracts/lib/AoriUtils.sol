// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAori} from "../interfaces/IAori.sol";

// Balance struct for tracking locked and unlocked token amounts
struct Balance {
    uint128 locked;
    uint128 unlocked;
}

using BalanceUtils for Balance global;

// Utility functions for managing token balances
library BalanceUtils {
    function lock(Balance storage balance, uint128 amount) internal {
        balance.locked += amount;
    }

    function unlock(Balance storage balance, uint128 amount) internal {
        (uint128 locked, uint128 unlocked) = balance.loadBalance();
        require(locked >= amount, "Insufficient locked balance");
        unchecked {
            locked -= amount;
        }
        unlocked += amount;

        balance.storeBalance(locked, unlocked);
    }

    // Will not revert on underflow
    // Use with caution, as it may lead to incorrect state
    function decreaseLockedNoRevert(Balance storage balance, uint128 amount) internal returns (bool success) {
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

    // Will not revert on overflow
    // Use with caution, as it may lead to incorrect state
    function increaseUnlockedNoRevert(Balance storage balance, uint128 amount) internal returns (bool success) {
        uint128 unlocked = balance.unlocked;
        unchecked {
            uint128 newUnlocked = unlocked + amount;
            if (newUnlocked < unlocked) {
                return false; // Underflow
            }
            balance.unlocked = newUnlocked;
        }
        return true;
    }

    function unlockAll(Balance storage balance) internal returns (uint128 amount) {
        (uint128 locked, uint128 unlocked) = balance.loadBalance();
        amount = locked;
        unlocked += amount;
        locked = 0;

        balance.storeBalance(locked, unlocked);
    }

    function getUnlocked(Balance storage balance) internal view returns (uint128) {
        return balance.unlocked;
    }

    function getLocked(Balance storage balance) internal view returns (uint128) {
        return balance.locked;
    }

    function loadBalance(Balance storage balance) internal view returns (uint128 locked, uint128 unlocked) {
        assembly {
            let fullSlot := sload(balance.slot)
            unlocked := shr(128, fullSlot)
            locked := fullSlot
        }
    }

    function storeBalance(Balance storage balance, uint128 locked, uint128 unlocked) internal {
        assembly {
            sstore(balance.slot, or(shl(128, unlocked), locked))
        }
    }
}

// Execute external calls and observe token balance changes
library ExecutionUtils {
    function observeBalChg(address target, bytes calldata data, address observedToken) internal returns (uint256) {
        uint256 balBefore = IERC20(observedToken).balanceOf(address(this));
        (bool success,) = target.call(data);
        require(success, "Call failed");
        uint256 balAfter = IERC20(observedToken).balanceOf(address(this));
        return balAfter - balBefore;
    }
}

// Utility functions for hook operations
library HookUtils {
    function isSome(IAori.SrcHook calldata hook) internal pure returns (bool) {
        return hook.hookAddress != address(0);
    }

    function isSome(IAori.DstHook calldata hook) internal pure returns (bool) {
        return hook.hookAddress != address(0);
    }
}

enum PayloadType {
    Settlement,
    Cancellation
}

library PayloadUnpackUtils {
    function validateCancellationLen(bytes calldata payload) internal pure {
        require(payload.length == 33, "Invalid cancellation payload length");
    }

    function unpackCancellation(bytes calldata payload) internal pure returns (bytes32 orderHash) {
        assembly {
            orderHash := calldataload(add(payload.offset, 1))
        }
    }

    function validateSettlementLen(bytes calldata payload) internal pure {
        require(payload.length >= 23, "Payload too short for settlement");
    }

    function validateSettlementLen(bytes calldata payload, uint16 fillCount) internal pure {
        require(payload.length == 23 + uint256(fillCount) * 32, "Invalid payload length for settlement");
    }

    function getType(bytes calldata payload) internal pure returns (PayloadType) {
        return PayloadType(uint8(payload[0]));
    }

    function unpackSettlementHeader(bytes calldata payload) internal pure returns (address filler, uint16 fillCount) {
        require(payload.length >= 23, "Invalid payload length");
        assembly {
            let word := calldataload(add(payload.offset, 1))
            filler := shr(96, word)
        }
        fillCount = (uint16(uint8(payload[21])) << 8) | uint16(uint8(payload[22]));
    }

    function unpackSettlementBodyAt(bytes calldata payload, uint256 index) internal pure returns (bytes32 orderHash) {
        require(payload.length >= 23, "Invalid payload length");
        require(index < (payload.length - 23) / 32, "Index out of bounds");
        assembly {
            orderHash := calldataload(add(add(payload.offset, 23), mul(index, 32)))
        }
    }
}

library PayloadPackUtils {
    /**
     * @dev Packs the settlement payload for LayerZero messaging
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
     * @notice The function expects takeSize <= arr.length
     */
    function packSettlement(bytes32[] storage arr, address filler, uint16 takeSize) internal returns (bytes memory) {
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
            for { let i := arrLength } gt(i, min_i) {} {
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

    function packCancellation(bytes32 orderHash) internal pure returns (bytes memory payload) {
        uint8 msgType = uint8(PayloadType.Cancellation);
        assembly {
            mstore(payload, CANCELLATION_PAYLOAD_SIZE)
            mstore(add(payload, 32), msgType)
            mstore(add(payload, 33), orderHash)
        }
    }
}

function settlementPayloadSize(uint256 fillCount) pure returns (uint256) {
    return 1 + 20 + 2 + (fillCount * 32);
}

// Cancellation message: 1 byte (msgType) + 32 bytes (orderId) = 33 bytes
uint256 constant CANCELLATION_PAYLOAD_SIZE = 33;
