// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../../types/AoriErrors.sol";

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

// Constant size of a cancellation payload: 1 byte type + 32 bytes order hash
uint256 constant CANCELLATION_PAYLOAD_SIZE = 33;

/**
 * @notice Calculates the size of a settlement payload based on fill count
 * @dev 1 byte type + 20 bytes filler + 2 bytes count + (fillCount * 32 bytes order hash)
 * @param fillCount The number of fills in the settlement
 * @return The total payload size in bytes
 */
/* forgefmt: disable-next-item */
function settlementPayloadSize(uint256 fillCount) pure returns (uint256) { return 1 + 20 + 2 + (fillCount * 32); }

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
            } gt(i, min_i) { } {
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
    /* forgefmt: disable-next-item */
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
    /* forgefmt: disable-next-item */
    function validateCancellationLen(bytes calldata payload) internal pure {
        if (payload.length != 33) revert InvalidPayloadLength(33, payload.length);
    }

    /**
     * @notice Unpacks an order hash from a cancellation payload
     * @dev Extracts the 32-byte order hash, skipping the first byte (type)
     * @param payload The cancellation payload to unpack
     * @return orderHash The extracted order hash
     */
    /* forgefmt: disable-next-item */
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
    /* forgefmt: disable-next-item */
    function validateSettlementLen(bytes calldata payload) internal pure {
        if (payload.length < 23) revert InvalidPayloadLength(23, payload.length);
    }

    /**
     * @notice Validates the length of a settlement payload for a specific fill count
     * @dev Ensures the payload matches the expected size based on fill count
     * @param payload The payload to validate
     * @param fillCount The number of fills in the payload
     */
    function validateSettlementLen(
        bytes calldata payload,
        uint16 fillCount
    ) internal pure {
        uint256 expectedLen = 23 + uint256(fillCount) * 32;
        if (payload.length != expectedLen) revert InvalidPayloadLength(expectedLen, payload.length);
    }

    /**
     * @notice Gets the payload type from a message payload
     * @dev Reads the first byte to determine the payload type
     * @param payload The payload to check
     * @return The payload type (Settlement or Cancellation)
     */
    /* forgefmt: disable-next-item */
    function getType(bytes calldata payload) internal pure returns (PayloadType) { return PayloadType(uint8(payload[0])); }

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
        if (payload.length < 23) revert InvalidPayloadLength(23, payload.length);
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
        if (payload.length < 23) revert InvalidPayloadLength(23, payload.length);
        if (index >= (payload.length - 23) / 32) revert PayloadIndexOutOfBounds();
        assembly {
            orderHash := calldataload(add(add(payload.offset, 23), mul(index, 32)))
        }
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    PAYLOAD SIZES                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
            uint16 fillCount = uint16(fillsLength < maxFillsPerSettle ? fillsLength : maxFillsPerSettle);

            // Calculate settlement payload size
            return settlementPayloadSize(fillCount);
        } else {
            revert InvalidMessageType();
        }
    }
}
