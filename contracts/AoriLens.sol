// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Order } from "./types/AoriTypes.sol";

/**
 * @title IAoriLensTarget
 * @notice Minimal interface for Aori storage reading
 */
interface IAoriLensTarget {
    function readStorage(
        bytes32 slot
    ) external view returns (bytes32);
    function readStorageArray(
        bytes32 slot
    ) external view returns (uint256);
}

/**
 * @title AoriLens
 * @notice External view contract for reading Aori state without adding bytecode to Aori
 * @dev Uses storage slot calculations based on ERC-7201 namespaced storage
 */
contract AoriLens {
    // ERC-7201 storage slot for AoriStorage
    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant AORI_STORAGE_SLOT = 0x476c06ce9bda338755e203b7f327971f808163bb891bef1bf37f35e88d0aae00;

    // Storage layout offsets within AoriStorageData struct
    uint256 constant BALANCES_OFFSET = 0;
    uint256 constant ORDERS_OFFSET = 1;
    uint256 constant IS_SUPPORTED_CHAIN_OFFSET = 2;
    uint256 constant MAX_FILLS_PER_SETTLE_OFFSET = 3;
    uint256 constant ORDER_STATUS_OFFSET = 4;
    uint256 constant IS_ALLOWED_HOOK_OFFSET = 5;
    uint256 constant IS_ALLOWED_SOLVER_OFFSET = 6;
    uint256 constant SRC_EID_TO_FILLER_FILLS_OFFSET = 7;

    IAoriLensTarget public immutable aori;

    constructor(
        address _aori
    ) {
        aori = IAoriLensTarget(_aori);
    }

    /**
     * @notice Get order details by order ID
     */
    function orders(
        bytes32 orderId
    ) external view returns (Order memory order) {
        bytes32 baseSlot = keccak256(abi.encode(orderId, uint256(AORI_STORAGE_SLOT) + ORDERS_OFFSET));

        bytes32 slot0 = aori.readStorage(baseSlot);
        bytes32 slot1 = aori.readStorage(bytes32(uint256(baseSlot) + 1));
        bytes32 slot2 = aori.readStorage(bytes32(uint256(baseSlot) + 2));
        bytes32 slot3 = aori.readStorage(bytes32(uint256(baseSlot) + 3));
        bytes32 slot4 = aori.readStorage(bytes32(uint256(baseSlot) + 4));
        bytes32 slot5 = aori.readStorage(bytes32(uint256(baseSlot) + 5));
        bytes32 slot6 = aori.readStorage(bytes32(uint256(baseSlot) + 6));

        // Slot 0: inputAmount (lower 128) | outputAmount (upper 128)
        order.inputAmount = uint128(uint256(slot0));
        order.outputAmount = uint128(uint256(slot0) >> 128);

        // Slot 1: inputToken (lower 160)
        order.inputToken = address(uint160(uint256(slot1)));

        // Slot 2: outputToken (lower 160) | startTime | endTime | srcEid (packed)
        order.outputToken = address(uint160(uint256(slot2)));
        order.startTime = uint32(uint256(slot2) >> 160);
        order.endTime = uint32(uint256(slot2) >> 192);
        order.srcEid = uint32(uint256(slot2) >> 224);

        // Slot 3: dstEid (lower 32) | offerer (bits 32-191)
        order.dstEid = uint32(uint256(slot3));
        order.offerer = address(uint160(uint256(slot3) >> 32));

        // Slot 4: recipient (lower 160)
        order.recipient = address(uint160(uint256(slot4)));

        // Slot 5: Options.feeMbps (lower 16) | Options.feeRecipient (bits 16-175)
        order.options.feeMbps = uint16(uint256(slot5));
        order.options.feeRecipient = address(uint160(uint256(slot5) >> 16));

        // Slot 6: Options.solver (lower 160) | Options.slippageMbps (bits 160-175)
        order.options.solver = address(uint160(uint256(slot6)));
        order.options.slippageMbps = uint16(uint256(slot6) >> 160);
    }

    /**
     * @notice Get locked balance for a user and token
     */
    function getLockedBalances(
        address user,
        address token
    ) external view returns (uint256) {
        bytes32 firstLevel = keccak256(abi.encode(user, uint256(AORI_STORAGE_SLOT) + BALANCES_OFFSET));
        bytes32 balanceSlot = keccak256(abi.encode(token, firstLevel));
        bytes32 value = aori.readStorage(balanceSlot);
        return uint128(uint256(value)); // locked is lower 128 bits
    }

    /**
     * @notice Get unlocked balance for a user and token
     */
    function getUnlockedBalances(
        address user,
        address token
    ) external view returns (uint256) {
        bytes32 firstLevel = keccak256(abi.encode(user, uint256(AORI_STORAGE_SLOT) + BALANCES_OFFSET));
        bytes32 balanceSlot = keccak256(abi.encode(token, firstLevel));
        bytes32 value = aori.readStorage(balanceSlot);
        return uint128(uint256(value) >> 128); // unlocked is upper 128 bits
    }

    /**
     * @notice Get max fills per settle
     */
    function MAX_FILLS_PER_SETTLE() public view returns (uint16) {
        bytes32 slot = bytes32(uint256(AORI_STORAGE_SLOT) + MAX_FILLS_PER_SETTLE_OFFSET);
        return uint16(uint256(aori.readStorage(slot)));
    }

    /**
     * @notice Get filler fills array element
     */
    function srcEidToFillerFills(
        uint32 srcEid,
        address filler,
        uint256 index
    ) external view returns (bytes32) {
        bytes32 firstLevel = keccak256(abi.encode(srcEid, uint256(AORI_STORAGE_SLOT) + SRC_EID_TO_FILLER_FILLS_OFFSET));
        bytes32 arraySlot = keccak256(abi.encode(filler, firstLevel));
        bytes32 elementSlot = bytes32(uint256(keccak256(abi.encode(arraySlot))) + index);
        return aori.readStorage(elementSlot);
    }

    /**
     * @notice Get filler fills array length
     */
    function srcEidToFillerFillsLength(
        uint32 srcEid,
        address filler
    ) external view returns (uint256) {
        bytes32 firstLevel = keccak256(abi.encode(srcEid, uint256(AORI_STORAGE_SLOT) + SRC_EID_TO_FILLER_FILLS_OFFSET));
        bytes32 arraySlot = keccak256(abi.encode(filler, firstLevel));
        return aori.readStorageArray(arraySlot);
    }

    /**
     * @notice Get all order hashes for a filler across multiple source endpoints
     * @param srcEids Array of source endpoint IDs to query
     * @param filler The filler address
     * @return orderHashesPerEid Array of order hash arrays, one per source endpoint
     */
    function getPendingSettle(
        uint32[] calldata srcEids,
        address filler
    ) external view returns (bytes32[][] memory orderHashesPerEid) {
        orderHashesPerEid = new bytes32[][](srcEids.length);

        for (uint256 j = 0; j < srcEids.length; j++) {
            // Get the actual length first
            bytes32 firstLevel = keccak256(abi.encode(srcEids[j], uint256(AORI_STORAGE_SLOT) + SRC_EID_TO_FILLER_FILLS_OFFSET));
            bytes32 arraySlot = keccak256(abi.encode(filler, firstLevel));
            uint256 length = aori.readStorageArray(arraySlot);

            // Cap at reasonable limit to prevent gas issues
            if (length > 100) length = 100;

            orderHashesPerEid[j] = new bytes32[](length);
            
            // Read each order hash
            for (uint256 i = 0; i < length; i++) {
                bytes32 elementSlot = bytes32(uint256(keccak256(abi.encode(arraySlot))) + i);
                orderHashesPerEid[j][i] = aori.readStorage(elementSlot);
            }
        }
    }

    /**
     * @notice Get total input amounts grouped by input token for a list of order hashes
     * @param orderHashes Array of order hashes to query
     * @return inputTokens Array of unique input token addresses
     * @return totalAmounts Array of total input amounts corresponding to each token
     */
    function getOrdersInputTotals(
        bytes32[] calldata orderHashes
    )
        external
        view
        returns (address[] memory inputTokens, uint256[] memory totalAmounts)
    {
        // Use small fixed buffer - realistically won't have more than 20 unique tokens
        address[] memory tempTokens = new address[](20);
        uint256[] memory tempAmounts = new uint256[](20);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < orderHashes.length; i++) {
            Order memory order = this.orders(orderHashes[i]);
            
            // Check if token already exists
            bool found = false;
            for (uint256 k = 0; k < uniqueCount; k++) {
                if (tempTokens[k] == order.inputToken) {
                    tempAmounts[k] += order.inputAmount;
                    found = true;
                    break;
                }
            }

            if (!found && uniqueCount < 20) {
                tempTokens[uniqueCount] = order.inputToken;
                tempAmounts[uniqueCount] = order.inputAmount;
                uniqueCount++;
            }
        }

        // Resize arrays using assembly (no copy needed)
        assembly {
            mstore(tempTokens, uniqueCount)
            mstore(tempAmounts, uniqueCount)
        }

        return (tempTokens, tempAmounts);
    }

    // Note: quote() is kept in Aori.sol because it needs OApp's internal _quote() function
}
